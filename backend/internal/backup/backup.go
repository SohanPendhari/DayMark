// Package backup creates and restores historical snapshots. A snapshot is NOT synchronization:
// sync moves current changes between devices; restore rewinds the shared state to a past point.
package backup

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/lib/pq"

	dmsync "github.com/daymark/daymark/backend/internal/sync"
)

const (
	Format  = "daymark-backup"
	Version = 1
)

var (
	ErrInvalid  = errors.New("invalid backup")
	ErrNotFound = errors.New("backup not found")
	// ErrWouldOverwriteNewer is returned when a replace-restore would discard records changed
	// after the backup was taken and the caller did not pass force.
	ErrWouldOverwriteNewer = errors.New("restore would overwrite newer data")
)

type Service struct {
	DB        *sql.DB
	Retention int
}

type Payload struct {
	Format    string                       `json:"format"`
	Version   int                          `json:"version"`
	CreatedAt time.Time                    `json:"created_at"`
	LatestRev int64                        `json:"latest_rev"`
	Tables    map[string][]json.RawMessage `json:"tables"`
}

type Meta struct {
	ID           string         `json:"id"`
	Kind         string         `json:"kind"`
	CreatedAt    time.Time      `json:"created_at"`
	LatestRev    int64          `json:"latest_rev"`
	RecordCounts map[string]int `json:"record_counts"`
	SizeBytes    int            `json:"size_bytes"`
}

// stripped columns: bookkeeping that is re-assigned on restore.
const rowExpr = `to_jsonb(t) - 'field_revs' - 'updated_by' - 'server_updated_at' - 'rev'`

// Create takes a consistent snapshot (one repeatable-read transaction) and stores it gzipped.
func (s *Service) Create(ctx context.Context, kind, deviceID string) (*Meta, error) {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	p := &Payload{Format: Format, Version: Version, CreatedAt: time.Now().UTC(), Tables: map[string][]json.RawMessage{}}
	if err := tx.QueryRowContext(ctx, `SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM change_seq`).Scan(&p.LatestRev); err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, e := range dmsync.Entities {
		rows, err := tx.QueryContext(ctx, `SELECT `+rowExpr+` FROM `+e.Name+` t ORDER BY id`)
		if err != nil {
			return nil, err
		}
		list := []json.RawMessage{}
		for rows.Next() {
			var b []byte
			if err := rows.Scan(&b); err != nil {
				rows.Close()
				return nil, err
			}
			list = append(list, json.RawMessage(b))
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
		p.Tables[e.Name] = list
		counts[e.Name] = len(list)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(raw)
	var zbuf bytes.Buffer
	zw := gzip.NewWriter(&zbuf)
	zw.Write(raw)
	zw.Close()
	cb, _ := json.Marshal(counts)
	var by any
	if deviceID != "" {
		by = deviceID
	}
	m := &Meta{Kind: kind, LatestRev: p.LatestRev, RecordCounts: counts, SizeBytes: zbuf.Len()}
	if err := s.DB.QueryRowContext(ctx,
		`INSERT INTO backups (kind, created_by, latest_rev, record_counts, sha256, size_bytes, payload)
		 VALUES ($1,$2,$3,$4::jsonb,$5,$6,$7) RETURNING id, created_at`,
		kind, by, p.LatestRev, string(cb), sum[:], zbuf.Len(), zbuf.Bytes()).Scan(&m.ID, &m.CreatedAt); err != nil {
		return nil, err
	}
	s.prune(ctx)
	return m, nil
}

// prune keeps the newest Retention manual/scheduled snapshots and the 3 newest pre-restore ones.
func (s *Service) prune(ctx context.Context) {
	s.DB.ExecContext(ctx, `DELETE FROM backups WHERE kind <> 'pre_restore' AND id NOT IN (
		SELECT id FROM backups WHERE kind <> 'pre_restore' ORDER BY created_at DESC LIMIT $1)`, s.Retention)
	s.DB.ExecContext(ctx, `DELETE FROM backups WHERE kind = 'pre_restore' AND id NOT IN (
		SELECT id FROM backups WHERE kind = 'pre_restore' ORDER BY created_at DESC LIMIT 3)`)
}

func (s *Service) List(ctx context.Context) ([]Meta, error) {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, kind, created_at, latest_rev, record_counts, size_bytes FROM backups ORDER BY created_at DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Meta{}
	for rows.Next() {
		var m Meta
		var c []byte
		if err := rows.Scan(&m.ID, &m.Kind, &m.CreatedAt, &m.LatestRev, &c, &m.SizeBytes); err != nil {
			return nil, err
		}
		json.Unmarshal(c, &m.RecordCounts)
		out = append(out, m)
	}
	return out, rows.Err()
}

// Load returns a stored snapshot after verifying its checksum.
func (s *Service) Load(ctx context.Context, id string) (*Payload, []byte, error) {
	if !dmsync.ValidUUID(id) {
		return nil, nil, ErrNotFound
	}
	var z, sum []byte
	err := s.DB.QueryRowContext(ctx, `SELECT payload, sha256 FROM backups WHERE id=$1`, id).Scan(&z, &sum)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	zr, err := gzip.NewReader(bytes.NewReader(z))
	if err != nil {
		return nil, nil, fmt.Errorf("%w: corrupt payload", ErrInvalid)
	}
	raw, err := io.ReadAll(io.LimitReader(zr, 256<<20))
	if err != nil {
		return nil, nil, fmt.Errorf("%w: corrupt payload", ErrInvalid)
	}
	if got := sha256.Sum256(raw); !bytes.Equal(got[:], sum) {
		return nil, nil, fmt.Errorf("%w: checksum mismatch", ErrInvalid)
	}
	var p Payload
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, nil, fmt.Errorf("%w: %v", ErrInvalid, err)
	}
	return &p, raw, nil
}

// ---- Restore ------------------------------------------------------------------------

type RestoreRequest struct {
	BackupID string   `json:"backup_id"`
	Backup   *Payload `json:"backup"`
	Mode     string   `json:"mode"`    // merge (default) | replace
	DryRun   bool     `json:"dry_run"` // validate and report the plan; change nothing
	Confirm  string   `json:"confirm"` // must be "RESTORE" unless dry_run
	Force    bool     `json:"force"`   // allow replace to discard records newer than the backup
}

type EntityPlan struct {
	Insert    int `json:"insert"`
	Update    int `json:"update"`
	Skip      int `json:"skip"`
	Tombstone int `json:"tombstone"`
}

type Plan struct {
	Mode             string                `json:"mode"`
	Entities         map[string]EntityPlan `json:"entities"`
	NewerOverwritten int                   `json:"newer_than_backup"` // server records changed after the backup that replace would overwrite or delete
	Applied          bool                  `json:"applied"`
	SafetyBackup     string                `json:"safety_backup_id,omitempty"`
}

type parsedRow struct {
	id      string
	vals    map[string]any
	deleted *time.Time
}

// validate checks the whole payload against the registry before anything is written.
func validate(p *Payload) (map[string][]parsedRow, error) {
	if p == nil || p.Format != Format {
		return nil, fmt.Errorf("%w: not a DAYMARK backup", ErrInvalid)
	}
	if p.Version != Version {
		return nil, fmt.Errorf("%w: unsupported version %d", ErrInvalid, p.Version)
	}
	for name := range p.Tables {
		if dmsync.Lookup(name) == nil {
			return nil, fmt.Errorf("%w: unknown table %q", ErrInvalid, name)
		}
	}
	out := map[string][]parsedRow{}
	seen := map[string]bool{}
	for _, e := range dmsync.Entities {
		for i, rb := range p.Tables[e.Name] {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(rb, &fields); err != nil {
				return nil, fmt.Errorf("%w: %s[%d]: %v", ErrInvalid, e.Name, i, err)
			}
			var id string
			if err := json.Unmarshal(fields["id"], &id); err != nil || !dmsync.ValidUUID(id) {
				return nil, fmt.Errorf("%w: %s[%d]: invalid id", ErrInvalid, e.Name, i)
			}
			id = strings.ToLower(id)
			if seen[e.Name+id] {
				return nil, fmt.Errorf("%w: duplicate id %s in %s", ErrInvalid, id, e.Name)
			}
			seen[e.Name+id] = true
			pr := parsedRow{id: id}
			if raw, ok := fields["deleted_at"]; ok && string(bytes.TrimSpace(raw)) != "null" {
				t, err := time.Parse(time.RFC3339Nano, strings.Trim(string(raw), `"`))
				if err != nil {
					return nil, fmt.Errorf("%w: %s[%d]: invalid deleted_at", ErrInvalid, e.Name, i)
				}
				t = t.UTC()
				pr.deleted = &t
			}
			delete(fields, "id")
			delete(fields, "deleted_at")
			vals, err := dmsync.ValidateFields(e, fields, true)
			if err != nil {
				return nil, fmt.Errorf("%w: %s[%d]: %v", ErrInvalid, e.Name, i, err)
			}
			pr.vals = vals
			out[e.Name] = append(out[e.Name], pr)
		}
	}
	return out, nil
}

// Restore validates a snapshot and applies it. merge never resurrects or overwrites: it only
// re-creates records missing from the server. replace makes the server match the snapshot
// (extra records become tombstones, so every device converges), but refuses to discard
// records newer than the snapshot unless Force is set. A safety snapshot is taken first.
func (s *Service) Restore(ctx context.Context, deviceID string, req RestoreRequest) (*Plan, error) {
	if (req.BackupID == "") == (req.Backup == nil) {
		return nil, fmt.Errorf("%w: provide exactly one of backup_id or backup", ErrInvalid)
	}
	if req.Mode == "" {
		req.Mode = "merge"
	}
	if req.Mode != "merge" && req.Mode != "replace" {
		return nil, fmt.Errorf("%w: mode must be merge or replace", ErrInvalid)
	}
	if !req.DryRun && req.Confirm != "RESTORE" {
		return nil, fmt.Errorf("%w: confirm must be exactly \"RESTORE\"", ErrInvalid)
	}
	p := req.Backup
	if req.BackupID != "" {
		var err error
		if p, _, err = s.Load(ctx, req.BackupID); err != nil {
			return nil, err
		}
	}
	rows, err := validate(p)
	if err != nil {
		return nil, err
	}

	plan := &Plan{Mode: req.Mode, Entities: map[string]EntityPlan{}}
	if req.DryRun {
		if err := s.run(ctx, s.DB, deviceID, p, rows, req, plan, false); err != nil {
			return nil, err
		}
		return plan, nil
	}
	if req.Mode == "replace" {
		// Preview first (no lock needed) so we refuse before taking any safety snapshot.
		pre := &Plan{Entities: map[string]EntityPlan{}}
		if err := s.run(ctx, s.DB, deviceID, p, rows, req, pre, false); err != nil {
			return nil, err
		}
		if pre.NewerOverwritten > 0 && !req.Force {
			*plan = *pre
			return plan, ErrWouldOverwriteNewer
		}
		m, err := s.Create(ctx, "pre_restore", deviceID)
		if err != nil {
			return nil, err
		}
		plan.SafetyBackup = m.ID
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback() // an interrupted restore leaves no partial state
	if err := dmsync.Lock(ctx, tx); err != nil {
		return nil, err
	}
	if err := s.run(ctx, tx, deviceID, p, rows, req, plan, true); err != nil {
		return nil, err
	}
	if plan.NewerOverwritten > 0 && req.Mode == "replace" && !req.Force {
		return plan, ErrWouldOverwriteNewer // data changed between preview and lock
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	plan.Applied = true
	return plan, nil
}

// run computes the plan and, when write is true, applies it through q.
func (s *Service) run(ctx context.Context, q dmsync.DBTX, deviceID string, p *Payload,
	rows map[string][]parsedRow, req RestoreRequest, plan *Plan, write bool) error {

	for _, e := range dmsync.Entities {
		type srv struct {
			rev     int64
			deleted bool
		}
		existing := map[string]srv{}
		r, err := q.QueryContext(ctx, `SELECT id::text, rev, deleted_at IS NOT NULL FROM `+e.Name)
		if err != nil {
			return err
		}
		for r.Next() {
			var id string
			var v srv
			if err := r.Scan(&id, &v.rev, &v.deleted); err != nil {
				r.Close()
				return err
			}
			existing[id] = v
		}
		r.Close()
		if err := r.Err(); err != nil {
			return err
		}

		ep := EntityPlan{}
		inBackup := map[string]bool{}
		for _, row := range rows[e.Name] {
			inBackup[row.id] = true
			cur, found := existing[row.id]
			switch {
			case !found:
				ep.Insert++
			case req.Mode == "merge":
				ep.Skip++
				continue
			default:
				if cur.rev > p.LatestRev {
					plan.NewerOverwritten++
				}
				ep.Update++
			}
			if write {
				if err := upsert(ctx, q, e, deviceID, row); err != nil {
					return err
				}
			}
		}
		if req.Mode == "replace" {
			var gone []string
			for id, cur := range existing {
				if inBackup[id] || cur.deleted {
					continue
				}
				if cur.rev > p.LatestRev {
					plan.NewerOverwritten++
				}
				gone = append(gone, id)
			}
			ep.Tombstone = len(gone)
			if write && len(gone) > 0 {
				rev, err := dmsync.NextRev(ctx, q)
				if err != nil {
					return err
				}
				// One revision per batch is enough: clients pull everything with rev > cursor.
				if _, err := q.ExecContext(ctx,
					`UPDATE `+e.Name+` SET deleted_at=now(), rev=$1, updated_by=$2, server_updated_at=now()
					 WHERE id = ANY($3::uuid[])`, rev, deviceID, pq.Array(gone)); err != nil {
					return err
				}
			}
		}
		plan.Entities[e.Name] = ep
	}
	return nil
}

func upsert(ctx context.Context, q dmsync.DBTX, e *dmsync.Entity, deviceID string, row parsedRow) error {
	rev, err := dmsync.NextRev(ctx, q)
	if err != nil {
		return err
	}
	cols := []string{"id", "rev", "field_revs", "deleted_at", "updated_by"}
	ph := []string{"$1", "$2", "'{}'::jsonb", "$3", "$4"}
	args := []any{row.id, rev, nilTime(row.deleted), deviceID}
	sets := []string{"rev=EXCLUDED.rev", "field_revs='{}'::jsonb", "deleted_at=EXCLUDED.deleted_at",
		"updated_by=EXCLUDED.updated_by", "server_updated_at=now()"}
	for i := range e.Cols {
		c := &e.Cols[i]
		args = append(args, dmsync.Bind(c, row.vals[c.Name])) // absent optional fields become NULL
		cols = append(cols, c.Name)
		ph = append(ph, dmsync.Placeholder(c, len(args)))
		sets = append(sets, c.Name+"=EXCLUDED."+c.Name)
	}
	_, err = q.ExecContext(ctx, fmt.Sprintf(
		`INSERT INTO %s (%s) VALUES (%s) ON CONFLICT (id) DO UPDATE SET %s`,
		e.Name, strings.Join(cols, ","), strings.Join(ph, ","), strings.Join(sets, ",")), args...)
	return err
}

func nilTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return *t
}
