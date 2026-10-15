// Package auth implements private-instance setup, one-time device pairing,
// revocable device credentials and inactivity expiry.
package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/daymark/daymark/backend/internal/security"
)

var (
	ErrAlreadyInitialized = errors.New("already initialized")
	ErrNotInitialized     = errors.New("not initialized")
	ErrInvalidCode        = errors.New("invalid or expired pairing code")
	ErrUnauthorized       = errors.New("unauthorized")
	ErrNotFound           = errors.New("not found")
	ErrInvalidInput       = errors.New("invalid input")
)

type Device struct {
	ID         string     `json:"id"`
	Label      string     `json:"label"`
	Username   string     `json:"username"`
	Platform   string     `json:"platform"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt time.Time  `json:"last_seen_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty"`
}

type Service struct {
	DB        *sql.DB
	Secret    string
	DeviceTTL time.Duration
	CodeTTL   time.Duration
}

func (s *Service) Initialized(ctx context.Context) (bool, error) {
	var ok bool
	err := s.DB.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM instance)`).Scan(&ok)
	return ok, err
}

// Init marks the instance initialized exactly once (the primary key makes the race safe).
func (s *Service) Init(ctx context.Context) error {
	res, err := s.DB.ExecContext(ctx, `INSERT INTO instance DEFAULT VALUES ON CONFLICT DO NOTHING`)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrAlreadyInitialized
	}
	return nil
}

// NewPairingCode issues a short-lived single-use code. Older unused codes stay valid until
// they expire; use RevokeOutstandingCodes to invalidate them.
func (s *Service) NewPairingCode(ctx context.Context, createdBy string) (string, time.Time, error) {
	code := security.NewPairingCode()
	exp := time.Now().Add(s.CodeTTL).UTC()
	var by any
	if createdBy != "" {
		by = createdBy
	}
	_, err := s.DB.ExecContext(ctx,
		`INSERT INTO pairing_codes (code_hash, created_by, expires_at) VALUES ($1,$2,$3)`,
		security.HashCode(s.Secret, code), by, exp)
	return code, exp, err
}

func (s *Service) RevokeOutstandingCodes(ctx context.Context) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE pairing_codes SET used_at = now() WHERE used_at IS NULL`)
	return err
}

func validText(v string, max int) bool {
	v = strings.TrimSpace(v)
	return v != "" && utf8.ValidString(v) && utf8.RuneCountInString(v) <= max
}

// Pair atomically consumes a pairing code and registers the device.
// It returns the device and its raw credential (shown once, never stored).
func (s *Service) Pair(ctx context.Context, code, label, username, platform string) (*Device, string, error) {
	if !validText(label, 60) || !validText(username, 60) {
		return nil, "", fmt.Errorf("%w: label and username are required (max 60 characters)", ErrInvalidInput)
	}
	if platform != "android" && platform != "web" && platform != "other" {
		return nil, "", fmt.Errorf("%w: platform must be android, web or other", ErrInvalidInput)
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()

	// Single statement: only one concurrent request can win a given code.
	res, err := tx.ExecContext(ctx,
		`UPDATE pairing_codes SET used_at = now()
		 WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now()`,
		security.HashCode(s.Secret, code))
	if err != nil {
		return nil, "", err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return nil, "", ErrInvalidCode
	}
	token, hash := security.NewToken()
	d := &Device{ID: uuid.NewString(), Label: strings.TrimSpace(label), Username: strings.TrimSpace(username), Platform: platform}
	if err = tx.QueryRowContext(ctx,
		`INSERT INTO devices (id, label, username, platform, token_hash) VALUES ($1,$2,$3,$4,$5)
		 RETURNING created_at, last_seen_at`,
		d.ID, d.Label, d.Username, d.Platform, hash).Scan(&d.CreatedAt, &d.LastSeenAt); err != nil {
		return nil, "", err
	}
	return d, token, tx.Commit()
}

// Authenticate resolves a credential to an active device. Credentials expire after DeviceTTL
// of inactivity (sliding window) and stop working immediately when revoked.
func (s *Service) Authenticate(ctx context.Context, token string) (*Device, error) {
	if !strings.HasPrefix(token, "dmk_") || len(token) > 128 {
		return nil, ErrUnauthorized
	}
	d := &Device{}
	var revoked sql.NullTime
	err := s.DB.QueryRowContext(ctx,
		`SELECT id, label, username, platform, created_at, last_seen_at, revoked_at
		 FROM devices WHERE token_hash = $1`, security.HashToken(token)).
		Scan(&d.ID, &d.Label, &d.Username, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &revoked)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if revoked.Valid || time.Since(d.LastSeenAt) > s.DeviceTTL {
		return nil, ErrUnauthorized
	}
	// Throttle writes: refresh last_seen at most every 10 minutes.
	if time.Since(d.LastSeenAt) > 10*time.Minute {
		s.DB.ExecContext(ctx, `UPDATE devices SET last_seen_at = now() WHERE id = $1`, d.ID)
	}
	return d, nil
}

func (s *Service) ListDevices(ctx context.Context) ([]Device, error) {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, label, username, platform, created_at, last_seen_at, revoked_at
		 FROM devices ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		var d Device
		var rv pq.NullTime
		if err := rows.Scan(&d.ID, &d.Label, &d.Username, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &rv); err != nil {
			return nil, err
		}
		if rv.Valid {
			t := rv.Time
			d.RevokedAt = &t
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// Revoke disables a device immediately. Revoking an already-revoked device is a no-op.
func (s *Service) Revoke(ctx context.Context, id string) error {
	if _, err := uuid.Parse(id); err != nil {
		return ErrNotFound
	}
	res, err := s.DB.ExecContext(ctx,
		`UPDATE devices SET revoked_at = COALESCE(revoked_at, now()) WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// RevokeAll disables every device (used by the owner-only recovery flow).
func (s *Service) RevokeAll(ctx context.Context) (int64, error) {
	res, err := s.DB.ExecContext(ctx, `UPDATE devices SET revoked_at = now() WHERE revoked_at IS NULL`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Prune removes expired/used pairing codes older than a day.
func (s *Service) Prune(ctx context.Context) error {
	_, err := s.DB.ExecContext(ctx,
		`DELETE FROM pairing_codes WHERE expires_at < now() - interval '1 day'`)
	return err
}
