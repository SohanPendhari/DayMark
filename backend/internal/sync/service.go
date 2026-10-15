package sync

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// LockKey serializes all writers (push, restore). Revisions are allocated while the lock
// is held, so commit order equals revision order. That is what makes a single numeric
// cursor safe: a reader can never observe rev 6 without rev 5 arriving later.
const LockKey = 7_201_002

const MaxOpsPerBatch = 100

var ErrInvalid = errors.New("invalid request")

type DBTX interface {
	ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
}

type Service struct{ DB *sql.DB }

// Op is one client mutation. Fields are partial for updates (only changed fields).
type Op struct {
	OpID    string                     `json:"op_id"`
	Entity  string                     `json:"entity"`
	ID      string                     `json:"id"`
	Type    string                     `json:"type"` // create | update | delete
	BaseRev int64                      `json:"base_rev"`
	Fields  map[string]json.RawMessage `json:"fields"`
}

type Result struct {
	OpID      string   `json:"op_id"`
	Status    string   `json:"status"` // applied | partial | conflict | rejected
	Rev       int64    `json:"rev,omitempty"`
	Conflicts []string `json:"conflicts,omitempty"`
	Error     string   `json:"error,omitempty"`
	Replayed  bool     `json:"replayed,omitempty"`
}

type fieldMeta struct {
	R int64  `json:"r"`
	D string `json:"d"`
}

func NextRev(ctx context.Context, q DBTX) (int64, error) {
	var n int64
	err := q.QueryRowContext(ctx, `SELECT nextval('change_seq')`).Scan(&n)
	return n, err
}

// Lock takes the writer lock for the rest of the transaction.
func Lock(ctx context.Context, tx DBTX) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1)`, LockKey)
	return err
}

// Push applies a batch atomically: if any database error occurs the whole batch rolls back
// and nothing (including idempotency records) is committed, so the client simply retries.
// Per-operation validation problems are reported as "rejected" without failing the batch.
func (s *Service) Push(ctx context.Context, deviceID string, ops []Op) ([]Result, error) {
	if len(ops) == 0 || len(ops) > MaxOpsPerBatch {
		return nil, fmt.Errorf("%w: ops must contain 1 to %d operations", ErrInvalid, MaxOpsPerBatch)
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := Lock(ctx, tx); err != nil {
		return nil, err
	}
	results := make([]Result, 0, len(ops))
	for _, op := range ops {
		r, err := s.applyOp(ctx, tx, deviceID, op)
		if err != nil {
			return nil, err
		}
		results = append(results, r)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return results, nil
}

func (s *Service) applyOp(ctx context.Context, tx *sql.Tx, deviceID string, op Op) (Result, error) {
	if !ValidUUID(op.OpID) {
		return Result{OpID: op.OpID, Status: "rejected", Error: "op_id must be a UUID"}, nil
	}
	op.OpID = strings.ToLower(op.OpID)

	var stored []byte
	switch err := tx.QueryRowContext(ctx, `SELECT result FROM applied_ops WHERE op_id=$1`, op.OpID).Scan(&stored); {
	case err == nil:
		var r Result
		if err := json.Unmarshal(stored, &r); err != nil {
			return Result{}, err
		}
		r.Replayed = true
		return r, nil
	case !errors.Is(err, sql.ErrNoRows):
		return Result{}, err
	}

	r, err := s.execute(ctx, tx, deviceID, op)
	if err != nil {
		return Result{}, err
	}
	r.OpID = op.OpID
	b, _ := json.Marshal(r)
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO applied_ops (op_id, device_id, result) VALUES ($1,$2,$3::jsonb)`,
		op.OpID, deviceID, string(b)); err != nil {
		return Result{}, err
	}
	return r, nil
}

func reject(msg string) (Result, error) { return Result{Status: "rejected", Error: msg}, nil }

func (s *Service) execute(ctx context.Context, tx *sql.Tx, deviceID string, op Op) (Result, error) {
	e := Lookup(op.Entity)
	if e == nil {
		return reject("unknown entity")
	}
	if !ValidUUID(op.ID) {
		return reject("id must be a UUID")
	}
	op.ID = strings.ToLower(op.ID)
	if op.BaseRev < 0 {
		return reject("base_rev must be >= 0")
	}

	switch op.Type {
	case "create":
		vals, err := ValidateFields(e, op.Fields, true)
		if err != nil {
			return reject(err.Error())
		}
		return s.create(ctx, tx, deviceID, e, op.ID, vals)
	case "update":
		if e.AppendOnly {
			return reject(e.Name + " are append-only")
		}
		if len(op.Fields) == 0 {
			return reject("update requires at least one field")
		}
		vals, err := ValidateFields(e, op.Fields, false)
		if err != nil {
			return reject(err.Error())
		}
		return s.update(ctx, tx, deviceID, e, op, vals)
	case "delete":
		return s.delete(ctx, tx, deviceID, e, op.ID)
	}
	return reject("type must be create, update or delete")
}

func (s *Service) create(ctx context.Context, tx *sql.Tx, deviceID string, e *Entity, id string, vals map[string]any) (Result, error) {
	var exists bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM `+e.Name+` WHERE id=$1)`, id).Scan(&exists); err != nil {
		return Result{}, err
	}
	if exists {
		return Result{Status: "conflict", Error: "already_exists"}, nil
	}
	rev, err := NextRev(ctx, tx)
	if err != nil {
		return Result{}, err
	}
	meta := map[string]fieldMeta{}
	for name := range vals {
		meta[name] = fieldMeta{R: rev, D: deviceID}
	}
	mb, _ := json.Marshal(meta)
	cols := []string{"id", "rev", "field_revs", "updated_by"}
	ph := []string{"$1", "$2", "$3::jsonb", "$4"}
	args := []any{id, rev, string(mb), deviceID}
	for i := range e.Cols {
		c := &e.Cols[i]
		v, ok := vals[c.Name]
		if !ok {
			continue
		}
		args = append(args, Bind(c, v))
		cols = append(cols, c.Name)
		ph = append(ph, Placeholder(c, len(args)))
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO `+e.Name+` (`+strings.Join(cols, ",")+`) VALUES (`+strings.Join(ph, ",")+`)`, args...); err != nil {
		return Result{}, err
	}
	return Result{Status: "applied", Rev: rev}, nil
}

// writeFields updates the named fields and stamps them with a fresh revision.
func writeFields(ctx context.Context, tx DBTX, e *Entity, id, deviceID string, names []string, vals map[string]any) (int64, error) {
	rev, err := NextRev(ctx, tx)
	if err != nil {
		return 0, err
	}
	meta := map[string]fieldMeta{}
	set := []string{"rev=$1", "field_revs = field_revs || $2::jsonb", "updated_by=$3", "server_updated_at=now()"}
	args := []any{rev, "", deviceID}
	for _, name := range names {
		c := e.Col(name)
		meta[name] = fieldMeta{R: rev, D: deviceID}
		args = append(args, Bind(c, vals[name]))
		set = append(set, name+"="+Placeholder(c, len(args)))
	}
	mb, _ := json.Marshal(meta)
	args[1] = string(mb)
	args = append(args, id)
	_, err = tx.ExecContext(ctx,
		fmt.Sprintf(`UPDATE %s SET %s WHERE id=$%d`, e.Name, strings.Join(set, ", "), len(args)), args...)
	return rev, err
}

func (s *Service) update(ctx context.Context, tx *sql.Tx, deviceID string, e *Entity, op Op, vals map[string]any) (Result, error) {
	var rev int64
	var frRaw, curRaw []byte
	var deleted bool
	err := tx.QueryRowContext(ctx,
		`SELECT rev, field_revs, deleted_at IS NOT NULL, to_jsonb(t) FROM `+e.Name+` t WHERE id=$1 FOR UPDATE`, op.ID).
		Scan(&rev, &frRaw, &deleted, &curRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return reject("not_found")
	}
	if err != nil {
		return Result{}, err
	}
	if deleted {
		// Tombstones win: a stale device may never resurrect or edit a deleted record.
		return Result{Status: "conflict", Rev: rev, Error: "record_deleted"}, nil
	}
	if op.BaseRev > rev {
		return reject("base_rev is ahead of the server")
	}
	var fm map[string]fieldMeta
	var cur map[string]json.RawMessage
	if err := json.Unmarshal(frRaw, &fm); err != nil {
		return Result{}, err
	}
	if err := json.Unmarshal(curRaw, &cur); err != nil {
		return Result{}, err
	}

	names := make([]string, 0, len(vals))
	for n := range vals {
		names = append(names, n)
	}
	sort.Strings(names)

	var apply, conflicted []string
	for _, name := range names {
		c := e.Col(name)
		server, _ := Decode(c, cur[name])
		if SameValue(server, vals[name]) {
			continue // already converged; nothing to write, nothing to conflict about
		}
		// A field conflicts only if ANOTHER device changed it after this device's base revision.
		// The device's own earlier (possibly unacknowledged) edits never conflict with itself.
		if m := fm[name]; m.R > op.BaseRev && m.D != deviceID {
			conflicted = append(conflicted, name)
		} else {
			apply = append(apply, name)
		}
	}

	res := Result{Status: "applied", Rev: rev}
	if len(apply) > 0 {
		if res.Rev, err = writeFields(ctx, tx, e, op.ID, deviceID, apply, vals); err != nil {
			return Result{}, err
		}
	}
	if len(conflicted) > 0 {
		detail := map[string]map[string]json.RawMessage{}
		for _, name := range conflicted {
			srv := cur[name]
			if srv == nil {
				srv = json.RawMessage("null")
			}
			detail[name] = map[string]json.RawMessage{"mine": op.Fields[name], "server": srv}
		}
		db, _ := json.Marshal(detail)
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_conflicts (entity, record_id, op_id, device_id, fields) VALUES ($1,$2,$3,$4,$5::jsonb)`,
			e.Name, op.ID, op.OpID, deviceID, string(db)); err != nil {
			return Result{}, err
		}
		res.Conflicts = conflicted
		res.Status = "partial"
		if len(apply) == 0 {
			res.Status = "conflict"
		}
	}
	return res, nil
}

func (s *Service) delete(ctx context.Context, tx *sql.Tx, deviceID string, e *Entity, id string) (Result, error) {
	var rev int64
	var deleted bool
	err := tx.QueryRowContext(ctx,
		`SELECT rev, deleted_at IS NOT NULL FROM `+e.Name+` WHERE id=$1 FOR UPDATE`, id).Scan(&rev, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return Result{Status: "applied"}, nil // nothing to delete; idempotent
	}
	if err != nil {
		return Result{}, err
	}
	if deleted {
		return Result{Status: "applied", Rev: rev}, nil
	}
	rev, err = NextRev(ctx, tx)
	if err != nil {
		return Result{}, err
	}
	_, err = tx.ExecContext(ctx,
		`UPDATE `+e.Name+` SET deleted_at=now(), rev=$1, updated_by=$2, server_updated_at=now() WHERE id=$3`,
		rev, deviceID, id)
	return Result{Status: "applied", Rev: rev}, err
}

// ---- Pull ---------------------------------------------------------------------------

type Change struct {
	Entity  string          `json:"entity"`
	ID      string          `json:"id"`
	Rev     int64           `json:"rev"`
	Deleted bool            `json:"deleted"`
	Data    json.RawMessage `json:"data"`
}

type PullResponse struct {
	Changes    []Change  `json:"changes"`
	NextCursor int64     `json:"next_cursor"`
	HasMore    bool      `json:"has_more"`
	LatestRev  int64     `json:"latest_rev"`
	ServerTime time.Time `json:"server_time"`
}

const MaxPullLimit = 500

// Pull returns changes (including tombstones) with rev > cursor, oldest first.
// Deleted rows are reduced to {id, deleted_at}; the rest of their data never leaves the server.
func (s *Service) Pull(ctx context.Context, cursor int64, limit int) (*PullResponse, error) {
	if cursor < 0 {
		return nil, fmt.Errorf("%w: cursor must be >= 0", ErrInvalid)
	}
	if limit <= 0 {
		limit = 200
	}
	if limit > MaxPullLimit {
		limit = MaxPullLimit
	}
	parts := make([]string, 0, len(Entities))
	for _, e := range Entities { // names come from the static registry only
		parts = append(parts, fmt.Sprintf(
			`SELECT '%[1]s'::text AS entity, id::text AS id, rev, (deleted_at IS NOT NULL) AS deleted,
			 CASE WHEN deleted_at IS NOT NULL THEN jsonb_build_object('id', id, 'deleted_at', deleted_at)
			      ELSE to_jsonb(t) - 'field_revs' - 'updated_by' - 'server_updated_at' END AS data
			 FROM %[1]s t WHERE rev > $1`, e.Name))
	}
	q := `SELECT entity, id, rev, deleted, data FROM (` + strings.Join(parts, " UNION ALL ") + `) u ORDER BY rev LIMIT $2`

	rows, err := s.DB.QueryContext(ctx, q, cursor, limit+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	resp := &PullResponse{Changes: []Change{}, NextCursor: cursor, ServerTime: time.Now().UTC()}
	for rows.Next() {
		var c Change
		var data []byte
		if err := rows.Scan(&c.Entity, &c.ID, &c.Rev, &c.Deleted, &data); err != nil {
			return nil, err
		}
		if len(resp.Changes) == limit {
			resp.HasMore = true
			break
		}
		c.Data = data
		resp.Changes = append(resp.Changes, c)
		resp.NextCursor = c.Rev
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	resp.LatestRev, err = s.LatestRev(ctx)
	return resp, err
}

func (s *Service) LatestRev(ctx context.Context) (int64, error) {
	var n int64
	err := s.DB.QueryRowContext(ctx, `SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM change_seq`).Scan(&n)
	return n, err
}

// ---- Status & conflicts -------------------------------------------------------------

type Status struct {
	LatestRev           int64      `json:"latest_rev"`
	ServerTime          time.Time  `json:"server_time"`
	UnresolvedConflicts int        `json:"unresolved_conflicts"`
	LastBackupAt        *time.Time `json:"last_backup_at"`
}

func (s *Service) Status(ctx context.Context) (*Status, error) {
	st := &Status{ServerTime: time.Now().UTC()}
	var err error
	if st.LatestRev, err = s.LatestRev(ctx); err != nil {
		return nil, err
	}
	var last sql.NullTime
	if err = s.DB.QueryRowContext(ctx,
		`SELECT (SELECT count(*) FROM sync_conflicts WHERE resolved_at IS NULL),
		        (SELECT max(created_at) FROM backups WHERE kind <> 'pre_restore')`).
		Scan(&st.UnresolvedConflicts, &last); err != nil {
		return nil, err
	}
	if last.Valid {
		t := last.Time.UTC()
		st.LastBackupAt = &t
	}
	return st, nil
}

type Conflict struct {
	ID        int64                                 `json:"id"`
	Entity    string                                `json:"entity"`
	RecordID  string                                `json:"record_id"`
	DeviceID  string                                `json:"device_id"`
	CreatedAt time.Time                             `json:"created_at"`
	Fields    map[string]map[string]json.RawMessage `json:"fields"`
}

func (s *Service) Conflicts(ctx context.Context) ([]Conflict, error) {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, entity, record_id::text, device_id::text, created_at, fields
		 FROM sync_conflicts WHERE resolved_at IS NULL ORDER BY id LIMIT 200`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Conflict{}
	for rows.Next() {
		var c Conflict
		var f []byte
		if err := rows.Scan(&c.ID, &c.Entity, &c.RecordID, &c.DeviceID, &c.CreatedAt, &f); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(f, &c.Fields); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

var ErrNotFound = errors.New("not found")

// Resolve settles a stored conflict. "keep_server" simply closes it (the server value already
// won). "apply_mine" re-applies the preserved losing values as a fresh edit by the resolver.
func (s *Service) Resolve(ctx context.Context, id int64, deviceID, resolution string) (int64, error) {
	if resolution != "keep_server" && resolution != "apply_mine" {
		return 0, fmt.Errorf("%w: resolution must be keep_server or apply_mine", ErrInvalid)
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	if err := Lock(ctx, tx); err != nil {
		return 0, err
	}
	var entity, recordID string
	var fieldsRaw []byte
	err = tx.QueryRowContext(ctx,
		`SELECT entity, record_id::text, fields FROM sync_conflicts WHERE id=$1 AND resolved_at IS NULL FOR UPDATE`, id).
		Scan(&entity, &recordID, &fieldsRaw)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	var rev int64
	if resolution == "apply_mine" {
		e := Lookup(entity)
		var fields map[string]map[string]json.RawMessage
		if e == nil || json.Unmarshal(fieldsRaw, &fields) != nil {
			return 0, fmt.Errorf("%w: stored conflict is unreadable", ErrInvalid)
		}
		vals := map[string]any{}
		var names []string
		for name, v := range fields {
			c := e.Col(name)
			if c == nil || c.Immutable {
				continue
			}
			val, err := Decode(c, v["mine"])
			if err != nil {
				return 0, fmt.Errorf("%w: %v", ErrInvalid, err)
			}
			vals[name] = val
			names = append(names, name)
		}
		sort.Strings(names)
		var deleted bool
		if err := tx.QueryRowContext(ctx, `SELECT deleted_at IS NOT NULL FROM `+e.Name+` WHERE id=$1 FOR UPDATE`, recordID).Scan(&deleted); err != nil {
			return 0, ErrNotFound
		}
		if deleted {
			return 0, fmt.Errorf("%w: the record was deleted", ErrInvalid)
		}
		if len(names) > 0 {
			if rev, err = writeFields(ctx, tx, e, recordID, deviceID, names, vals); err != nil {
				return 0, err
			}
		}
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE sync_conflicts SET resolved_at=now(), resolution=$2 WHERE id=$1`, id, resolution); err != nil {
		return 0, err
	}
	return rev, tx.Commit()
}

// Prune drops idempotency records old enough that no client could still be retrying them.
func (s *Service) Prune(ctx context.Context, olderThan time.Duration) error {
	_, err := s.DB.ExecContext(ctx, `DELETE FROM applied_ops WHERE created_at < now() - make_interval(secs => $1)`, olderThan.Seconds())
	return err
}
