// Package database opens PostgreSQL and applies versioned migrations.
package database

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

const migrationLockKey = 7_201_001

// Open connects with pooling and waits (bounded) for the database to accept connections.
func Open(ctx context.Context, url string, maxOpen int) (*sql.DB, error) {
	db, err := sql.Open("postgres", url)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxOpen / 2)
	db.SetConnMaxLifetime(30 * time.Minute)
	db.SetConnMaxIdleTime(5 * time.Minute)

	deadline := time.Now().Add(30 * time.Second)
	for {
		pctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		err = db.PingContext(pctx)
		cancel()
		if err == nil {
			return db, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			db.Close()
			return nil, fmt.Errorf("database not reachable: %w", err)
		}
		time.Sleep(time.Second)
	}
}

// Migrate applies every unapplied NNNN_name.sql in order, each in its own transaction.
// A session-level advisory lock prevents concurrent instances from racing.
func Migrate(ctx context.Context, db *sql.DB, files fs.FS) (applied []int, err error) {
	conn, err := db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if _, err = conn.ExecContext(ctx, `SELECT pg_advisory_lock($1)`, migrationLockKey); err != nil {
		return nil, err
	}
	defer conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock($1)`, migrationLockKey)

	if _, err = conn.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version int PRIMARY KEY, name text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, err
	}
	names, err := fs.Glob(files, "*.sql")
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	for _, name := range names {
		version, perr := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if perr != nil {
			return applied, fmt.Errorf("bad migration file name %q", name)
		}
		var exists bool
		if err = conn.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version=$1)`, version).Scan(&exists); err != nil {
			return applied, err
		}
		if exists {
			continue
		}
		body, rerr := fs.ReadFile(files, name)
		if rerr != nil {
			return applied, rerr
		}
		tx, terr := conn.BeginTx(ctx, nil)
		if terr != nil {
			return applied, terr
		}
		if _, err = tx.ExecContext(ctx, string(body)); err == nil {
			_, err = tx.ExecContext(ctx, `INSERT INTO schema_migrations (version, name) VALUES ($1,$2)`, version, name)
		}
		if err != nil {
			tx.Rollback()
			return applied, fmt.Errorf("migration %s failed: %w", name, err)
		}
		if err = tx.Commit(); err != nil {
			return applied, err
		}
		applied = append(applied, version)
	}
	return applied, nil
}
