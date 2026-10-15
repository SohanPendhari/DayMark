package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/daymark/daymark/backend/internal/config"
	"github.com/daymark/daymark/backend/internal/database"
	"github.com/daymark/daymark/backend/internal/security"
	"github.com/daymark/daymark/backend/migrations"
)

const testSecret = "test-secret-test-secret-test-1234"

type env struct {
	t   *testing.T
	db  *sql.DB
	cfg config.Config
	srv *Server
	ts  *httptest.Server
	url string // database URL bound to this test's schema
}

type J = map[string]any

// newEnv builds an isolated schema in the test database, migrates it, and starts the API.
// Rate limiters are relaxed unless strict is set (tests make many requests from one IP).
func newEnv(t *testing.T, strict ...bool) *env {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	admin, err := sql.Open("postgres", base)
	if err != nil {
		t.Fatal(err)
	}
	schema := "t_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:16]
	if _, err := admin.Exec("CREATE SCHEMA " + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Exec("DROP SCHEMA " + schema + " CASCADE"); admin.Close() })

	url := base + "&search_path=" + schema
	cfg, err := config.Load(func(k string) string {
		return map[string]string{
			"DATABASE_URL": url, "DAYMARK_SETUP_SECRET": testSecret, "DAYMARK_ENV": "development",
			"ALLOWED_ORIGINS": "http://localhost:8081", "BACKUP_RETENTION": "5",
		}[k]
	})
	if err != nil {
		t.Fatal(err)
	}
	e := &env{t: t, cfg: cfg, url: url}
	e.db, err = sql.Open("postgres", url)
	if err != nil {
		t.Fatal(err)
	}
	e.db.SetMaxOpenConns(10)
	t.Cleanup(func() { e.db.Close() })
	if _, err := database.Migrate(context.Background(), e.db, migrations.FS); err != nil {
		t.Fatal(err)
	}
	e.start(len(strict) == 0 || !strict[0])
	return e
}

func (e *env) start(relax bool) {
	if e.ts != nil {
		e.ts.Close()
	}
	e.srv = New(e.cfg, e.db, slog.New(slog.NewTextHandler(io.Discard, nil)), "test")
	if relax {
		e.srv.global = security.NewLimiter(1e6, 1e6)
		e.srv.sensitive = security.NewLimiter(1e6, 1e6)
	}
	e.ts = httptest.NewServer(e.srv.Handler())
	e.t.Cleanup(e.ts.Close)
}

// call performs a request and returns status, decoded JSON body, and the raw response.
func (e *env) call(method, path, token string, body any, hdr ...string) (int, J, *http.Response) {
	e.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		rd = strings.NewReader(b)
	case []byte:
		rd = bytes.NewReader(b)
	default:
		raw, err := json.Marshal(b)
		if err != nil {
			e.t.Fatal(err)
		}
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.ts.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out J
	json.Unmarshal(raw, &out)
	return resp.StatusCode, out, resp
}

func (e *env) expect(want int, got int, body J) {
	e.t.Helper()
	if got != want {
		e.t.Fatalf("status = %d, want %d; body = %v", got, want, body)
	}
}

// bootstrap initializes the instance and pairs the first (mobile) device.
func (e *env) bootstrap() (token, deviceID string) {
	e.t.Helper()
	st, b, _ := e.call("POST", "/api/v1/setup/init", "", J{"setup_secret": testSecret})
	e.expect(201, st, b)
	return e.pairWith(b["pairing_code"].(string), "Pixel", "android")
}

func (e *env) pairWith(code, label, platform string) (string, string) {
	e.t.Helper()
	st, b, _ := e.call("POST", "/api/v1/pair", "", J{"code": code, "label": label, "username": "owner", "platform": platform})
	e.expect(201, st, b)
	dev := b["device"].(J)
	tok, _ := b["token"].(string)
	return tok, dev["id"].(string)
}

// addDevice pairs another mobile device using an authorized one.
func (e *env) addDevice(viaToken, label string) (string, string) {
	e.t.Helper()
	st, b, _ := e.call("POST", "/api/v1/devices/pairing-codes", viaToken, nil)
	e.expect(201, st, b)
	return e.pairWith(b["pairing_code"].(string), label, "android")
}

const ts0 = "2026-01-01T10:00:00Z"

func op(entity, id, typ string, base int, fields J) J {
	o := J{"op_id": uuid.NewString(), "entity": entity, "id": id, "type": typ, "base_rev": base}
	if fields != nil {
		o["fields"] = fields
	}
	return o
}

func taskFields(title string) J {
	return J{"title": title, "status": "pending", "priority": 1, "postponed_count": 0, "created_at": ts0, "updated_at": ts0}
}

func (e *env) push(token string, ops ...J) []J {
	e.t.Helper()
	st, b, _ := e.call("POST", "/api/v1/sync/push", token, J{"ops": ops})
	e.expect(200, st, b)
	var out []J
	for _, r := range b["results"].([]any) {
		out = append(out, r.(J))
	}
	return out
}

func (e *env) pull(token string, cursor int, limit int) J {
	e.t.Helper()
	st, b, _ := e.call("GET", fmt.Sprintf("/api/v1/sync/pull?cursor=%d&limit=%d", cursor, limit), token, nil)
	e.expect(200, st, b)
	return b
}

func rev(r J) int { return int(r["rev"].(float64)) }

func changes(b J) []J {
	var out []J
	for _, c := range b["changes"].([]any) {
		out = append(out, c.(J))
	}
	return out
}

// find returns the data of the latest change for an id, plus its deleted flag.
func find(b J, id string) (data J, deleted bool, ok bool) {
	for _, c := range changes(b) {
		if c["id"] == id {
			data, deleted, ok = c["data"].(J), c["deleted"].(bool), true
		}
	}
	return
}

func (e *env) count(q string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.db.QueryRow(q, args...).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func context_() context.Context { return context.Background() }

func newTextLogger(w io.Writer) *slog.Logger { return slog.New(slog.NewTextHandler(w, nil)) }

func newServer(s *Server) *httptest.Server { return httptest.NewServer(s.Handler()) }
