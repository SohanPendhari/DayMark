package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/daymark/daymark/backend/internal/database"
	"github.com/daymark/daymark/backend/migrations"
)

// ---- health, setup, pairing, auth ---------------------------------------------------

func TestHealth(t *testing.T) {
	e := newEnv(t)
	st, b, _ := e.call("GET", "/api/v1/health", "", nil)
	e.expect(200, st, b)
	st, b, _ = e.call("GET", "/api/v1/health/ready", "", nil)
	e.expect(200, st, b)
	if b["initialized"] != false {
		t.Fatalf("fresh instance should report initialized=false: %v", b)
	}
}

func TestSetupAndPairing(t *testing.T) {
	e := newEnv(t)
	st, b, _ := e.call("POST", "/api/v1/setup/init", "", J{"setup_secret": "wrong-wrong-wrong-wrong-wrong"})
	e.expect(401, st, b)

	st, b, _ = e.call("POST", "/api/v1/setup/init", "", J{"setup_secret": testSecret})
	e.expect(201, st, b)
	code := b["pairing_code"].(string)
	if len(code) != 9 || code[4] != '-' {
		t.Fatalf("unexpected code format %q", code)
	}
	// Accidental re-initialization is refused.
	st, b, _ = e.call("POST", "/api/v1/setup/init", "", J{"setup_secret": testSecret})
	e.expect(409, st, b)

	// Validation errors do not burn the code.
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": code, "label": "", "username": "o", "platform": "android"})
	e.expect(400, st, b)
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": code, "label": "x", "username": "o", "platform": "toaster"})
	e.expect(400, st, b)

	// Loosely typed code works; credential returned once.
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": strings.ToLower(strings.ReplaceAll(code, "-", " ")), "label": "Pixel", "username": "owner", "platform": "android"})
	e.expect(201, st, b)
	tok := b["token"].(string)
	if !strings.HasPrefix(tok, "dmk_") {
		t.Fatalf("token %q", tok)
	}
	// Single use.
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": code, "label": "Other", "username": "o", "platform": "android"})
	e.expect(401, st, b)
	// Wrong code.
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": "AAAA-AAAA", "label": "Other", "username": "o", "platform": "android"})
	e.expect(401, st, b)
	// The credential is not stored in clear text.
	if n := e.count(`SELECT count(*) FROM devices WHERE token_hash = convert_to($1,'UTF8')`, tok); n != 0 {
		t.Fatal("raw token stored")
	}
	// Authorized device works.
	st, b, _ = e.call("GET", "/api/v1/session", tok, nil)
	e.expect(200, st, b)
}

func TestPairingCodeExpiry(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	_, b, _ := e.call("POST", "/api/v1/devices/pairing-codes", tok, nil)
	code := b["pairing_code"].(string)
	e.db.Exec(`UPDATE pairing_codes SET expires_at = now() - interval '1 second'`)
	st, b, _ := e.call("POST", "/api/v1/pair", "", J{"code": code, "label": "x", "username": "o", "platform": "android"})
	e.expect(401, st, b)
}

func TestConcurrentPairingOnlyOneWins(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	_, b, _ := e.call("POST", "/api/v1/devices/pairing-codes", tok, nil)
	code := b["pairing_code"].(string)
	var wg sync.WaitGroup
	var mu sync.Mutex
	wins := 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			st, _, _ := e.call("POST", "/api/v1/pair", "", J{"code": code, "label": fmt.Sprint("d", i), "username": "o", "platform": "android"})
			if st == 201 {
				mu.Lock()
				wins++
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("%d devices paired with one single-use code", wins)
	}
}

func TestUnauthorizedRejected(t *testing.T) {
	e := newEnv(t)
	e.bootstrap()
	routes := [][2]string{
		{"GET", "/api/v1/session"}, {"GET", "/api/v1/devices"}, {"POST", "/api/v1/devices/pairing-codes"},
		{"POST", "/api/v1/sync/push"}, {"GET", "/api/v1/sync/pull"}, {"GET", "/api/v1/sync/status"},
		{"GET", "/api/v1/sync/conflicts"}, {"POST", "/api/v1/backups"}, {"GET", "/api/v1/backups"},
		{"POST", "/api/v1/backups/restore"}, {"DELETE", "/api/v1/devices/" + uuid.NewString()},
	}
	for _, r := range routes {
		for _, tok := range []string{"", "dmk_notarealtoken", "garbage"} {
			st, _, _ := e.call(r[0], r[1], tok, nil)
			if st != 401 {
				t.Errorf("%s %s token=%q => %d, want 401", r[0], r[1], tok, st)
			}
		}
	}
}

func TestBruteForceIsThrottled(t *testing.T) {
	e := newEnv(t, true) // real limiters
	e.bootstrap()
	var last int
	for i := 0; i < 8; i++ {
		last, _, _ = e.call("POST", "/api/v1/pair", "", J{"code": "BBBB-BBBB", "label": "x", "username": "o", "platform": "android"})
	}
	if last != 429 {
		t.Fatalf("attempt 8 => %d, want 429", last)
	}
	// Even a valid secret is throttled while locked out.
	st, _, _ := e.call("POST", "/api/v1/setup/recover", "", J{"setup_secret": testSecret})
	if st != 429 {
		t.Fatalf("recover during lockout => %d, want 429", st)
	}
}

func TestSetupRecoverFlow(t *testing.T) {
	e := newEnv(t)
	st, b, _ := e.call("POST", "/api/v1/setup/recover", "", J{"setup_secret": testSecret})
	e.expect(409, st, b) // not initialized yet
	tok, _ := e.bootstrap()

	st, b, _ = e.call("POST", "/api/v1/setup/recover", "", J{"setup_secret": "nope-nope-nope-nope-nope-nope"})
	e.expect(401, st, b)

	_, b, _ = e.call("POST", "/api/v1/devices/pairing-codes", tok, nil)
	stale := b["pairing_code"].(string)
	st, b, _ = e.call("POST", "/api/v1/setup/recover", "", J{"setup_secret": testSecret, "revoke_all_devices": true})
	e.expect(201, st, b)
	if b["devices_revoked"].(float64) != 1 {
		t.Fatalf("expected 1 device revoked: %v", b)
	}
	st, b, _ = e.call("GET", "/api/v1/session", tok, nil)
	e.expect(401, st, b)
	// Outstanding codes were voided; the fresh one works.
	st, b, _ = e.call("POST", "/api/v1/pair", "", J{"code": stale, "label": "x", "username": "o", "platform": "android"})
	e.expect(401, st, b)
	newTok, _ := e.pairWith(b2code(t, e), "Replacement", "android")
	st, b, _ = e.call("GET", "/api/v1/session", newTok, nil)
	e.expect(200, st, b)
}

func b2code(t *testing.T, e *env) string {
	st, b, _ := e.call("POST", "/api/v1/setup/recover", "", J{"setup_secret": testSecret})
	e.expect(201, st, b)
	return b["pairing_code"].(string)
}

func TestRevokedDeviceLosesAccessImmediately(t *testing.T) {
	e := newEnv(t)
	a, _ := e.bootstrap()
	b, bid := e.addDevice(a, "Laptop")
	e.push(b, op("projects", uuid.NewString(), "create", 0, J{"name": "P", "created_at": ts0, "updated_at": ts0}))

	st, body, _ := e.call("DELETE", "/api/v1/devices/"+bid, a, nil)
	e.expect(204, st, body)
	for _, r := range [][2]string{{"GET", "/api/v1/sync/pull"}, {"POST", "/api/v1/sync/push"}, {"GET", "/api/v1/backups"}} {
		if st, _, _ := e.call(r[0], r[1], b, nil); st != 401 {
			t.Errorf("revoked device %s %s => %d, want 401", r[0], r[1], st)
		}
	}
	if st, body, _ := e.call("GET", "/api/v1/sync/pull", a, nil); st != 200 {
		t.Fatalf("other device broken: %d %v", st, body)
	}
	st, body, _ = e.call("DELETE", "/api/v1/devices/"+uuid.NewString(), a, nil)
	e.expect(404, st, body)
	st, body, _ = e.call("DELETE", "/api/v1/devices/not-a-uuid", a, nil)
	e.expect(404, st, body)
	// Revoking twice is harmless.
	st, body, _ = e.call("DELETE", "/api/v1/devices/"+bid, a, nil)
	e.expect(204, st, body)
}

func TestDeviceExpiresAfterInactivity(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	e.db.Exec(`UPDATE devices SET last_seen_at = now() - interval '200 days'`)
	st, b, _ := e.call("GET", "/api/v1/session", tok, nil)
	e.expect(401, st, b)
}

func TestSessionsSurviveServerRestart(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	id := uuid.NewString()
	e.push(tok, op("tasks", id, "create", 0, taskFields("persisted")))
	e.start(true) // brand-new server instance, same database
	if _, ok := mustFind(e, tok, id); !ok {
		t.Fatal("data lost across restart")
	}
}

func mustFind(e *env, tok, id string) (J, bool) {
	d, del, ok := find(e.pull(tok, 0, 500), id)
	return d, ok && !del
}

func TestWebSessionCookie(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	_, b, _ := e.call("POST", "/api/v1/devices/pairing-codes", tok, nil)
	st, body, resp := e.call("POST", "/api/v1/pair", "", J{"code": b["pairing_code"], "label": "Chrome", "username": "owner", "platform": "web"})
	e.expect(201, st, body)
	if _, leaked := body["token"]; leaked {
		t.Fatal("web credential must not appear in the response body")
	}
	var c *http.Cookie
	for _, k := range resp.Cookies() {
		if k.Name == "dm_session" {
			c = k
		}
	}
	if c == nil || !c.HttpOnly || c.MaxAge <= 0 {
		t.Fatalf("session cookie missing or not HttpOnly: %+v", c)
	}
	cookie := "dm_session=" + c.Value
	st, body, _ = e.call("GET", "/api/v1/session", "", nil, "Cookie", cookie)
	e.expect(200, st, body)

	push := J{"ops": []J{op("projects", uuid.NewString(), "create", 0, J{"name": "P", "created_at": ts0, "updated_at": ts0})}}
	// CSRF protections for cookie-authenticated writes.
	st, body, _ = e.call("POST", "/api/v1/sync/push", "", push, "Cookie", cookie)
	e.expect(403, st, body)
	st, body, _ = e.call("POST", "/api/v1/sync/push", "", push, "Cookie", cookie, "X-Daymark-Client", "web", "Origin", "https://evil.example")
	e.expect(403, st, body)
	st, body, _ = e.call("POST", "/api/v1/sync/push", "", push, "Cookie", cookie, "X-Daymark-Client", "web", "Origin", "http://localhost:8081")
	e.expect(200, st, body)

	st, body, _ = e.call("POST", "/api/v1/session/logout", "", nil)
	if st != 204 {
		t.Fatalf("logout => %d", st)
	}
}

func TestCORS(t *testing.T) {
	e := newEnv(t)
	_, _, r := e.call("OPTIONS", "/api/v1/sync/push", "", nil, "Origin", "http://localhost:8081", "Access-Control-Request-Method", "POST")
	if r.Header.Get("Access-Control-Allow-Origin") != "http://localhost:8081" || r.Header.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("allowed origin not honoured: %v", r.Header)
	}
	_, _, r = e.call("OPTIONS", "/api/v1/sync/push", "", nil, "Origin", "https://evil.example", "Access-Control-Request-Method", "POST")
	if r.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("disallowed origin received CORS headers")
	}
	_, _, r = e.call("GET", "/api/v1/health", "", nil, "Origin", "https://evil.example")
	if v := r.Header.Get("Access-Control-Allow-Origin"); v != "" {
		t.Fatalf("wildcard/foreign origin echoed: %q", v)
	}
}

func TestRateLimitsAndBodyLimit(t *testing.T) {
	e := newEnv(t, true)
	got429 := false
	for i := 0; i < 150; i++ {
		if st, _, _ := e.call("GET", "/api/v1/health", "", nil); st == 429 {
			got429 = true
			break
		}
	}
	if !got429 {
		t.Fatal("global rate limit never triggered")
	}

	e2 := newEnv(t)
	tok, _ := e2.bootstrap()
	big := `{"ops":[],"pad":"` + strings.Repeat("x", 2<<20) + `"}`
	st, _, _ := e2.call("POST", "/api/v1/sync/push", tok, big)
	if st != 413 && st != 400 {
		t.Fatalf("oversized body => %d, want 413", st)
	}
}

// ---- sync: validation, idempotency, rollback -----------------------------------------

func TestPushPullAndCursor(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	pid, tid := uuid.NewString(), uuid.NewString()
	res := e.push(tok,
		op("projects", pid, "create", 0, J{"name": "Home", "color": "#C5A45D", "created_at": ts0, "updated_at": ts0}),
		op("tasks", tid, "create", 0, taskFields("Buy milk")))
	if res[0]["status"] != "applied" || res[1]["status"] != "applied" || rev(res[1]) <= rev(res[0]) {
		t.Fatalf("unexpected results %v", res)
	}
	b := e.pull(tok, 0, 100)
	if len(changes(b)) != 2 || b["has_more"] != false {
		t.Fatalf("pull = %v", b)
	}
	next := int(b["next_cursor"].(float64))
	if next != rev(res[1]) {
		t.Fatalf("next_cursor %d != last rev %d", next, rev(res[1]))
	}
	if again := e.pull(tok, next, 100); len(changes(again)) != 0 || int(again["next_cursor"].(float64)) != next {
		t.Fatalf("incremental pull should be empty: %v", again)
	}
	// Only the changed record is transferred.
	e.push(tok, op("tasks", tid, "update", rev(res[1]), J{"title": "Buy oat milk", "updated_at": "2026-01-01T11:00:00Z"}))
	inc := e.pull(tok, next, 100)
	if len(changes(inc)) != 1 {
		t.Fatalf("incremental pull should return 1 change: %v", inc)
	}
	d, _, _ := find(inc, tid)
	if d["title"] != "Buy oat milk" || d["priority"].(float64) != 1 {
		t.Fatalf("data = %v", d)
	}
	if _, leaked := d["field_revs"]; leaked {
		t.Fatal("server bookkeeping leaked to client")
	}
}

func TestPullPagination(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	want := map[string]bool{}
	var ops []J
	for i := 0; i < 25; i++ {
		id := uuid.NewString()
		want[id] = true
		ops = append(ops, op("tasks", id, "create", 0, taskFields(fmt.Sprint("t", i))))
	}
	e.push(tok, ops...)
	cursor, seen, pages := 0, map[string]bool{}, 0
	for {
		b := e.pull(tok, cursor, 10)
		pages++
		for _, c := range changes(b) {
			if seen[c["id"].(string)] {
				t.Fatal("duplicate change across pages")
			}
			seen[c["id"].(string)] = true
		}
		cursor = int(b["next_cursor"].(float64))
		if b["has_more"] == false {
			break
		}
	}
	if len(seen) != 25 || pages != 3 {
		t.Fatalf("saw %d changes in %d pages", len(seen), pages)
	}
	st, b, _ := e.call("GET", "/api/v1/sync/pull?cursor=-1", tok, nil)
	e.expect(400, st, b)
	st, b, _ = e.call("GET", "/api/v1/sync/pull?cursor=abc", tok, nil)
	e.expect(400, st, b)
}

func TestIdempotentRetry(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	id := uuid.NewString()
	o := op("tasks", id, "create", 0, taskFields("once"))
	first := e.push(tok, o)
	second := e.push(tok, o) // the client retried after a lost response
	if second[0]["replayed"] != true || rev(second[0]) != rev(first[0]) || second[0]["status"] != "applied" {
		t.Fatalf("retry not replayed: %v vs %v", first, second)
	}
	if n := e.count(`SELECT count(*) FROM tasks WHERE id=$1`, id); n != 1 {
		t.Fatalf("%d rows after retry", n)
	}
	// A retried update must not be applied twice or conflict with itself.
	u := op("tasks", id, "update", rev(first[0]), J{"title": "twice"})
	r1 := e.push(tok, u)
	before := e.count(`SELECT rev FROM tasks WHERE id=$1`, id)
	r2 := e.push(tok, u)
	if after := e.count(`SELECT rev FROM tasks WHERE id=$1`, id); after != before || r2[0]["replayed"] != true || rev(r1[0]) != rev(r2[0]) {
		t.Fatalf("update replay changed state: %v %v", r1, r2)
	}
}

func TestInvalidOperationsRejected(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	id := uuid.NewString()
	e.push(tok, op("tasks", id, "create", 0, taskFields("ok")))
	log := uuid.NewString()
	e.push(tok, op("activity_logs", log, "create", 0, J{"event_type": "created", "occurred_at": ts0, "created_at": ts0}))

	long := strings.Repeat("x", 501)
	cases := map[string]J{
		"unknown entity":        op("users", uuid.NewString(), "create", 0, J{"a": 1}),
		"bad id":                op("tasks", "not-a-uuid", "create", 0, taskFields("x")),
		"unknown field":         op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"rev": 99})),
		"sql-ish field":         op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"title; DROP TABLE tasks": "x"})),
		"deleted_at injection":  op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"deleted_at": ts0})),
		"bad enum":              op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"status": "done"})),
		"priority range":        op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"priority": 9})),
		"title too long":        op("tasks", uuid.NewString(), "create", 0, taskFields(long)),
		"blank title":           op("tasks", uuid.NewString(), "create", 0, taskFields("   ")),
		"missing required":      op("tasks", uuid.NewString(), "create", 0, J{"title": "x"}),
		"bad timestamp":         op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"due_at": "tomorrow"})),
		"wrong type":            op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"priority": "high"})),
		"bad project uuid":      op("tasks", uuid.NewString(), "create", 0, merge(taskFields("x"), J{"project_id": "nope"})),
		"null required":         op("tasks", id, "update", 1, J{"title": nil}),
		"immutable edit":        op("tasks", id, "update", 1, J{"created_at": "2027-01-01T00:00:00Z"}),
		"empty update":          op("tasks", id, "update", 1, J{}),
		"update missing record": op("tasks", uuid.NewString(), "update", 1, J{"title": "x"}),
		"append-only update":    op("activity_logs", log, "update", 1, J{"event_type": "x"}),
		"bad event type":        op("activity_logs", uuid.NewString(), "create", 0, J{"event_type": "Bad Type!", "occurred_at": ts0, "created_at": ts0}),
		"metadata scalar":       op("activity_logs", uuid.NewString(), "create", 0, J{"event_type": "x", "occurred_at": ts0, "created_at": ts0, "metadata": "str"}),
		"unknown type":          op("tasks", id, "upsert", 0, J{"title": "x"}),
		"negative base":         op("tasks", id, "update", -1, J{"title": "x"}),
		"base ahead of server":  op("tasks", id, "update", 999999, J{"title": "x"}),
		"bad op id":             J{"op_id": "x", "entity": "tasks", "id": id, "type": "delete"},
	}
	before := e.count(`SELECT count(*) FROM tasks`)
	for name, o := range cases {
		r := e.push(tok, o)
		if r[0]["status"] != "rejected" || r[0]["error"] == "" {
			t.Errorf("%s: got %v, want rejected", name, r[0])
		}
	}
	if after := e.count(`SELECT count(*) FROM tasks`); after != before {
		t.Fatalf("invalid ops changed data: %d -> %d", before, after)
	}
	if d, ok := mustFind(e, tok, id); !ok || d["title"] != "ok" {
		t.Fatalf("existing record damaged: %v", d)
	}

	// Batch-level validation.
	st, b, _ := e.call("POST", "/api/v1/sync/push", tok, J{"ops": []J{}})
	e.expect(400, st, b)
	var many []J
	for i := 0; i < 101; i++ {
		many = append(many, op("tasks", uuid.NewString(), "create", 0, taskFields("x")))
	}
	st, b, _ = e.call("POST", "/api/v1/sync/push", tok, J{"ops": many})
	e.expect(400, st, b)
	st, b, _ = e.call("POST", "/api/v1/sync/push", tok, "{not json")
	e.expect(400, st, b)
	st, b, _ = e.call("POST", "/api/v1/sync/push", tok, `{"ops":[],"extra":1}`)
	e.expect(400, st, b)
	st, b, _ = e.call("POST", "/api/v1/sync/push", tok, `{"ops":[{"op_id":"`+uuid.NewString()+`","entity":"tasks","id":"`+uuid.NewString()+`","type":"delete"}]} {"x":1}`)
	e.expect(400, st, b)
}

func merge(a, b J) J {
	out := J{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func TestBatchRollsBackOnDatabaseError(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	if _, err := e.db.Exec(`
		CREATE FUNCTION boom() RETURNS trigger AS $$ BEGIN
		  IF NEW.title = 'boom' THEN RAISE EXCEPTION 'simulated failure'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql;
		CREATE TRIGGER boom_t BEFORE INSERT ON tasks FOR EACH ROW EXECUTE FUNCTION boom();`); err != nil {
		t.Fatal(err)
	}
	pid := uuid.NewString()
	batch := []J{
		op("projects", pid, "create", 0, J{"name": "P", "created_at": ts0, "updated_at": ts0}),
		op("tasks", uuid.NewString(), "create", 0, taskFields("boom")),
	}
	st, b, _ := e.call("POST", "/api/v1/sync/push", tok, J{"ops": batch})
	e.expect(500, st, b)
	if n := e.count(`SELECT count(*) FROM projects`) + e.count(`SELECT count(*) FROM applied_ops`); n != 0 {
		t.Fatalf("partial batch committed (%d rows)", n)
	}
	if strings.Contains(fmt.Sprint(b), "simulated") {
		t.Fatalf("internal error detail leaked: %v", b)
	}
	// After the fault clears, the very same batch (same op ids) succeeds: safe to retry.
	e.db.Exec(`DROP TRIGGER boom_t ON tasks`)
	batch[1] = op("tasks", uuid.NewString(), "create", 0, taskFields("fine"))
	res := e.push(tok, batch...)
	if res[0]["status"] != "applied" || res[1]["status"] != "applied" {
		t.Fatalf("retry failed: %v", res)
	}
}

// ---- tombstones, conflicts, concurrency -----------------------------------------------

func TestTombstonesPropagateAndStick(t *testing.T) {
	e := newEnv(t)
	a, _ := e.bootstrap()
	b, _ := e.addDevice(a, "Browser")
	id := uuid.NewString()
	c := e.push(a, op("tasks", id, "create", 0, taskFields("secret title")))
	// Browser syncs it.
	cur := int(e.pull(b, 0, 100)["next_cursor"].(float64))
	// Phone deletes.
	d := e.push(a, op("tasks", id, "delete", rev(c[0]), nil))
	if d[0]["status"] != "applied" || rev(d[0]) <= rev(c[0]) {
		t.Fatalf("delete result %v", d)
	}
	pb := e.pull(b, cur, 100)
	data, deleted, ok := find(pb, id)
	if !ok || !deleted || data["deleted_at"] == nil {
		t.Fatalf("browser did not receive tombstone: %v", pb)
	}
	if _, leaked := data["title"]; leaked {
		t.Fatal("tombstone leaks record content")
	}
	// A stale device editing or recreating the deleted record cannot resurrect it.
	r := e.push(b, op("tasks", id, "update", rev(c[0]), J{"title": "zombie"}))
	if r[0]["status"] != "conflict" || r[0]["error"] != "record_deleted" {
		t.Fatalf("stale update on tombstone: %v", r[0])
	}
	r = e.push(b, op("tasks", id, "create", 0, taskFields("zombie")))
	if r[0]["status"] != "conflict" {
		t.Fatalf("recreate over tombstone: %v", r[0])
	}
	// Deleting again and deleting unknown ids are harmless.
	if r = e.push(a, op("tasks", id, "delete", 0, nil), op("tasks", uuid.NewString(), "delete", 0, nil)); r[0]["status"] != "applied" || r[1]["status"] != "applied" {
		t.Fatalf("idempotent delete: %v", r)
	}
	if n := e.count(`SELECT count(*) FROM tasks WHERE id=$1 AND deleted_at IS NOT NULL`, id); n != 1 {
		t.Fatal("tombstone row missing")
	}
}

func TestFieldLevelConflictHandling(t *testing.T) {
	e := newEnv(t)
	phone, _ := e.bootstrap()
	web, _ := e.addDevice(phone, "Browser")
	id := uuid.NewString()
	c := e.push(phone, op("tasks", id, "create", 0, taskFields("Original")))
	base := rev(c[0]) // both devices have synced this revision

	// Phone edits the title.
	p := e.push(phone, op("tasks", id, "update", base, J{"title": "Phone title"}))
	if p[0]["status"] != "applied" {
		t.Fatal(p)
	}
	// Browser (still at base) edits an UNRELATED field: must apply, not overwrite phone's title.
	w := e.push(web, op("tasks", id, "update", base, J{"priority": 3}))
	if w[0]["status"] != "applied" {
		t.Fatalf("unrelated field edit should merge: %v", w[0])
	}
	// Browser edits the SAME field from the old base: conflict, server value kept, loser preserved.
	w = e.push(web, op("tasks", id, "update", base, J{"title": "Web title", "status": "in_progress"}))
	if w[0]["status"] != "partial" || fmt.Sprint(w[0]["conflicts"]) != "[title]" {
		t.Fatalf("expected partial with conflicting title: %v", w[0])
	}
	d, _ := mustFind(e, phone, id)
	if d["title"] != "Phone title" || d["priority"].(float64) != 3 || d["status"] != "in_progress" {
		t.Fatalf("merged state wrong: %v", d)
	}
	st, b, _ := e.call("GET", "/api/v1/sync/conflicts", web, nil)
	e.expect(200, st, b)
	list := b["conflicts"].([]any)
	if len(list) != 1 {
		t.Fatalf("conflicts = %v", list)
	}
	cf := list[0].(J)
	title := cf["fields"].(J)["title"].(J)
	if title["mine"] != "Web title" || title["server"] != "Phone title" {
		t.Fatalf("conflict detail %v", title)
	}
	st, b, _ = e.call("GET", "/api/v1/sync/status", web, nil)
	e.expect(200, st, b)
	if b["status"].(J)["unresolved_conflicts"].(float64) != 1 {
		t.Fatalf("status = %v", b)
	}

	// Manual resolution: apply the preserved version.
	cid := int(cf["id"].(float64))
	st, b, _ = e.call("POST", fmt.Sprintf("/api/v1/sync/conflicts/%d/resolve", cid), web, J{"resolution": "apply_mine"})
	e.expect(200, st, b)
	if d, _ := mustFind(e, phone, id); d["title"] != "Web title" {
		t.Fatalf("apply_mine did not apply: %v", d)
	}
	st, b, _ = e.call("POST", fmt.Sprintf("/api/v1/sync/conflicts/%d/resolve", cid), web, J{"resolution": "keep_server"})
	e.expect(404, st, b) // already resolved
	st, b, _ = e.call("POST", fmt.Sprintf("/api/v1/sync/conflicts/%d/resolve", cid), web, J{"resolution": "bogus"})
	if st != 400 && st != 404 {
		t.Fatalf("bogus resolution => %d", st)
	}
}

func TestSameDeviceEditsNeverSelfConflict(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	id := uuid.NewString()
	// The device queued create + two edits before any acknowledgement, all with base_rev 0.
	res := e.push(tok,
		op("tasks", id, "create", 0, taskFields("v1")),
		op("tasks", id, "update", 0, J{"title": "v2"}),
		op("tasks", id, "update", 0, J{"title": "v3", "priority": 2}))
	for _, r := range res {
		if r["status"] != "applied" {
			t.Fatalf("self-conflict: %v", res)
		}
	}
	if d, _ := mustFind(e, tok, id); d["title"] != "v3" || d["priority"].(float64) != 2 {
		t.Fatalf("final state %v", d)
	}
}

func TestConvergentEditsAreNotConflicts(t *testing.T) {
	e := newEnv(t)
	a, _ := e.bootstrap()
	b, _ := e.addDevice(a, "B")
	id := uuid.NewString()
	c := e.push(a, op("tasks", id, "create", 0, taskFields("x")))
	base := rev(c[0])
	e.push(a, op("tasks", id, "update", base, J{"status": "completed", "completed_at": ts0}))
	r := e.push(b, op("tasks", id, "update", base, J{"status": "completed", "completed_at": ts0}))
	if r[0]["status"] != "applied" || r[0]["conflicts"] != nil {
		t.Fatalf("both devices completed the task; should converge quietly: %v", r[0])
	}
	if e.count(`SELECT count(*) FROM sync_conflicts`) != 0 {
		t.Fatal("spurious conflict recorded")
	}
}

func TestConcurrentWritersGetUniqueOrderedRevisions(t *testing.T) {
	e := newEnv(t)
	a, _ := e.bootstrap()
	b, _ := e.addDevice(a, "B")
	shared := uuid.NewString()
	e.push(a, op("tasks", shared, "create", 0, taskFields("shared")))

	const workers, per = 8, 6
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			tok := a
			if w%2 == 1 {
				tok = b
			}
			for i := 0; i < per; i++ {
				st, body, _ := e.call("POST", "/api/v1/sync/push", tok, J{"ops": []J{
					op("tasks", uuid.NewString(), "create", 0, taskFields(fmt.Sprint("w", w, "-", i))),
					op("tasks", shared, "update", 0, J{"title": fmt.Sprint("edit-", w, "-", i)}),
				}})
				if st != 200 {
					t.Errorf("concurrent push => %d %v", st, body)
					return
				}
			}
		}(w)
	}
	wg.Wait()

	all := e.pull(a, 0, 500)
	seen, last := map[int]bool{}, 0
	for _, c := range changes(all) {
		r := int(c["rev"].(float64))
		if seen[r] || r <= last {
			t.Fatalf("revisions not unique/increasing at %d (last %d)", r, last)
		}
		seen[r], last = true, r
	}
	if n := e.count(`SELECT count(*) FROM tasks`); n != workers*per+1 {
		t.Fatalf("expected %d tasks, got %d", workers*per+1, n)
	}
	// No lost-update corruption: exactly one coherent title.
	if d, _ := mustFind(e, a, shared); !strings.HasPrefix(d["title"].(string), "edit-") {
		t.Fatalf("shared record corrupted: %v", d)
	}
}

func TestEveryEntityRoundTrips(t *testing.T) {
	e := newEnv(t)
	tok, dev := e.bootstrap()
	tid := uuid.NewString()
	ids := map[string]string{}
	mk := func(entity string, f J) {
		id := uuid.NewString()
		ids[entity] = id
		if r := e.push(tok, op(entity, id, "create", 0, f)); r[0]["status"] != "applied" {
			t.Fatalf("%s: %v", entity, r[0])
		}
	}
	e.push(tok, op("tasks", tid, "create", 0, merge(taskFields("T"), J{
		"description": "d", "category": "work", "start_at": ts0, "due_at": "2026-01-02T10:00:00Z",
		"estimated_minutes": 45, "recurrence_rule": "FREQ=WEEKLY;BYDAY=MO", "project_id": uuid.NewString()})))
	mk("projects", J{"name": "P", "description": "d", "color": "#C5A45D", "created_at": ts0, "updated_at": ts0, "archived_at": nil})
	mk("subtasks", J{"task_id": tid, "title": "S", "is_done": false, "sort_order": 1, "created_at": ts0, "updated_at": ts0})
	mk("reminders", J{"task_id": tid, "scheduled_at": "2026-01-02T09:00:00+05:30", "time_zone": "Asia/Kolkata", "enabled": true, "recurrence_rule": "FREQ=DAILY", "created_at": ts0, "updated_at": ts0})
	mk("activity_logs", J{"task_id": tid, "event_type": "completed", "occurred_at": ts0, "device_id": dev, "created_at": ts0, "metadata": J{"from": "pending", "n": 1}})
	mk("focus_sessions", J{"task_id": tid, "started_at": ts0, "ended_at": "2026-01-01T10:25:00Z", "accumulated_seconds": 1500, "created_at": ts0, "updated_at": ts0})

	b := e.pull(tok, 0, 100)
	for entity, id := range ids {
		if _, deleted, ok := find(b, id); !ok || deleted {
			t.Errorf("%s not returned by pull", entity)
		}
	}
	rem, _, _ := find(b, ids["reminders"])
	if rem["scheduled_at"] != "2026-01-02T03:30:00+00:00" { // normalized to UTC
		t.Errorf("reminder time = %v", rem["scheduled_at"])
	}
	act, _, _ := find(b, ids["activity_logs"])
	if act["metadata"].(J)["from"] != "pending" {
		t.Errorf("metadata = %v", act["metadata"])
	}
	// Append-only entity can be deleted (tombstoned).
	if r := e.push(tok, op("activity_logs", ids["activity_logs"], "delete", 0, nil)); r[0]["status"] != "applied" {
		t.Fatal(r)
	}
}

func TestMigrationsAreIdempotent(t *testing.T) {
	e := newEnv(t)
	applied, err := database.Migrate(context_(), e.db, migrations.FS)
	if err != nil || len(applied) != 0 {
		t.Fatalf("second run applied=%v err=%v", applied, err)
	}
}

// ---- backup & restore -----------------------------------------------------------------

func TestBackupRestoreLifecycle(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	pid, t1, t2, t3 := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(tok,
		op("projects", pid, "create", 0, J{"name": "P", "created_at": ts0, "updated_at": ts0}),
		op("tasks", t1, "create", 0, taskFields("T1")),
		op("tasks", t2, "create", 0, taskFields("T2")))

	st, bk, _ := e.call("POST", "/api/v1/backups", tok, nil)
	e.expect(201, st, bk)
	bid := bk["id"].(string)
	if bk["record_counts"].(J)["tasks"].(float64) != 2 {
		t.Fatalf("counts %v", bk["record_counts"])
	}
	st, lst, _ := e.call("GET", "/api/v1/backups", tok, nil)
	e.expect(200, st, lst)
	if len(lst["backups"].([]any)) != 1 {
		t.Fatalf("list %v", lst)
	}

	// Life goes on after the backup.
	e.push(tok,
		op("tasks", t1, "update", 0, J{"title": "T1 edited"}),
		op("tasks", t2, "delete", 0, nil),
		op("tasks", t3, "create", 0, taskFields("T3 new")))
	latest := e.pull(tok, 0, 500)["latest_rev"]

	restore := func(req J) (int, J) {
		st, b, _ := e.call("POST", "/api/v1/backups/restore", tok, req)
		return st, b
	}
	// A restore needs explicit confirmation.
	if st, b := restore(J{"backup_id": bid}); st != 400 {
		t.Fatalf("unconfirmed restore => %d %v", st, b)
	}
	// Dry run reports the plan and changes nothing.
	st, plan := restore(J{"backup_id": bid, "mode": "merge", "dry_run": true})
	if st != 200 || plan["applied"] != false {
		t.Fatalf("dry run: %d %v", st, plan)
	}
	// Merge never overwrites newer data or resurrects deletions.
	st, plan = restore(J{"backup_id": bid, "mode": "merge", "confirm": "RESTORE"})
	if st != 200 || plan["applied"] != true || plan["entities"].(J)["tasks"].(J)["skip"].(float64) != 2 {
		t.Fatalf("merge: %d %v", st, plan)
	}
	if after := e.pull(tok, 0, 500)["latest_rev"]; after != latest {
		t.Fatalf("merge restore changed data (rev %v -> %v)", latest, after)
	}
	// Replace would discard newer work: refused without force, and the plan says how much.
	st, plan = restore(J{"backup_id": bid, "mode": "replace", "confirm": "RESTORE"})
	if st != 409 || plan["error"].(J)["code"] != "would_overwrite_newer" || plan["plan"].(J)["newer_than_backup"].(float64) != 3 {
		t.Fatalf("replace without force: %d %v", st, plan)
	}
	if after := e.pull(tok, 0, 500)["latest_rev"]; after != latest {
		t.Fatal("refused restore still changed data")
	}
	cursor := int(latest.(float64))
	st, plan = restore(J{"backup_id": bid, "mode": "replace", "confirm": "RESTORE", "force": true})
	if st != 200 || plan["applied"] != true || plan["safety_backup_id"] == "" {
		t.Fatalf("forced replace: %d %v", st, plan)
	}
	// Every device converges through ordinary sync: restored values, resurrected T2, tombstoned T3.
	pb := e.pull(tok, cursor, 500)
	if d, del, _ := find(pb, t1); del || d["title"] != "T1" {
		t.Fatalf("T1 not restored: %v", d)
	}
	if _, del, ok := find(pb, t2); !ok || del {
		t.Fatal("T2 not restored")
	}
	if _, del, ok := find(pb, t3); !ok || !del {
		t.Fatal("T3 (created after backup) should be tombstoned by replace")
	}
	// The pre-restore safety snapshot exists, so even a replace is reversible.
	st, lst, _ = e.call("GET", "/api/v1/backups", tok, nil)
	kinds := fmt.Sprint(lst["backups"])
	if !strings.Contains(kinds, "pre_restore") {
		t.Fatalf("no safety backup: %s", kinds)
	}
	// Download returns a complete, parseable document.
	_, _, resp := e.call("GET", "/api/v1/backups/"+bid+"/download", tok, nil)
	if resp.StatusCode != 200 || !strings.Contains(resp.Header.Get("Content-Disposition"), "attachment") {
		t.Fatalf("download: %d %v", resp.StatusCode, resp.Header)
	}
}

func TestRestoreRejectsInvalidBackupsAndRollsBack(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	keep := uuid.NewString()
	e.push(tok, op("tasks", keep, "create", 0, taskFields("keep me")))
	before := e.pull(tok, 0, 500)["latest_rev"]

	bad := map[string]J{
		"not a backup":   {"format": "other", "version": 1, "tables": J{}},
		"future version": {"format": "daymark-backup", "version": 99, "tables": J{}},
		"unknown table":  {"format": "daymark-backup", "version": 1, "tables": J{"users": []J{{"id": uuid.NewString()}}}},
		"bad row":        {"format": "daymark-backup", "version": 1, "tables": J{"tasks": []J{{"id": uuid.NewString(), "title": "x"}}}},
		"bad id":         {"format": "daymark-backup", "version": 1, "tables": J{"tasks": []J{merge(taskFields("x"), J{"id": "zzz"})}}},
		"duplicate id": {"format": "daymark-backup", "version": 1, "tables": J{"tasks": []J{
			merge(taskFields("a"), J{"id": keep}), merge(taskFields("b"), J{"id": keep})}}},
	}
	for name, payload := range bad {
		st, b, _ := e.call("POST", "/api/v1/backups/restore", tok, J{"backup": payload, "mode": "replace", "confirm": "RESTORE", "force": true})
		if st != 400 || b["error"].(J)["code"] != "invalid_backup" {
			t.Errorf("%s => %d %v", name, st, b)
		}
	}
	st, b, _ := e.call("POST", "/api/v1/backups/restore", tok, J{"backup_id": uuid.NewString(), "confirm": "RESTORE"})
	e.expect(404, st, b)
	st, b, _ = e.call("POST", "/api/v1/backups/restore", tok, J{"confirm": "RESTORE"})
	e.expect(400, st, b)
	st, b, _ = e.call("POST", "/api/v1/backups/restore", tok, J{"backup_id": uuid.NewString(), "backup": J{}, "confirm": "RESTORE"})
	e.expect(400, st, b)

	// An interrupted restore (simulated database failure mid-way) leaves no partial state.
	e.db.Exec(`CREATE FUNCTION boom() RETURNS trigger AS $$ BEGIN
		IF NEW.title = 'boom' THEN RAISE EXCEPTION 'simulated'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql;
		CREATE TRIGGER boom_t BEFORE INSERT ON tasks FOR EACH ROW EXECUTE FUNCTION boom()`)
	payload := J{"format": "daymark-backup", "version": 1, "latest_rev": 0, "tables": J{"tasks": []J{
		merge(taskFields("fine"), J{"id": uuid.NewString()}), merge(taskFields("boom"), J{"id": uuid.NewString()})}}}
	st, b, _ = e.call("POST", "/api/v1/backups/restore", tok, J{"backup": payload, "mode": "replace", "confirm": "RESTORE", "force": true})
	e.expect(500, st, b)
	// Sequence values are not transactional, so revision numbers may have gaps (harmless:
	// cursors only need monotonicity). What matters is that no row changed.
	if got := e.pull(tok, int(before.(float64)), 500); len(changes(got)) != 0 {
		t.Fatalf("interrupted restore changed data: %v", got["changes"])
	}
	if n := e.count(`SELECT count(*) FROM tasks`); n != 1 {
		t.Fatalf("interrupted restore left %d tasks, want 1", n)
	}
	if d, ok := mustFind(e, tok, keep); !ok || d["title"] != "keep me" {
		t.Fatal("existing data damaged by failed restore")
	}
}

func TestCorruptBackupIsDetected(t *testing.T) {
	e := newEnv(t)
	tok, _ := e.bootstrap()
	e.push(tok, op("tasks", uuid.NewString(), "create", 0, taskFields("x")))
	_, bk, _ := e.call("POST", "/api/v1/backups", tok, nil)
	e.db.Exec(`UPDATE backups SET sha256 = decode(repeat('00',32),'hex')`)
	st, b, _ := e.call("GET", "/api/v1/backups/"+bk["id"].(string)+"/download", tok, nil)
	e.expect(409, st, b)
	st, b, _ = e.call("POST", "/api/v1/backups/restore", tok, J{"backup_id": bk["id"], "confirm": "RESTORE"})
	e.expect(400, st, b)
}

func TestBackupRetentionAndScheduledSkipUnchanged(t *testing.T) {
	e := newEnv(t) // BACKUP_RETENTION=5
	tok, _ := e.bootstrap()
	e.push(tok, op("tasks", uuid.NewString(), "create", 0, taskFields("x")))
	for i := 0; i < 7; i++ {
		st, b, _ := e.call("POST", "/api/v1/backups", tok, nil)
		e.expect(201, st, b)
	}
	if n := e.count(`SELECT count(*) FROM backups WHERE kind='manual'`); n != 5 {
		t.Fatalf("retention kept %d backups, want 5", n)
	}
	e.srv.scheduledBackup(context_()) // nothing changed since the last backup
	if n := e.count(`SELECT count(*) FROM backups WHERE kind='scheduled'`); n != 0 {
		t.Fatal("scheduled backup ran with no changes")
	}
	e.push(tok, op("tasks", uuid.NewString(), "create", 0, taskFields("y")))
	e.srv.scheduledBackup(context_())
	if n := e.count(`SELECT count(*) FROM backups WHERE kind='scheduled'`); n != 1 {
		t.Fatal("scheduled backup did not run after a change")
	}
}

func TestLogsDoNotContainSecretsOrContent(t *testing.T) {
	var buf strings.Builder
	e := newEnv(t)
	e.srv.log = newTextLogger(&buf)
	e.ts.Close()
	e.ts = newServer(e.srv)
	tok, _ := e.bootstrap()
	e.push(tok, op("tasks", uuid.NewString(), "create", 0, merge(taskFields("TOP-SECRET-TITLE"), J{"description": "TOP-SECRET-NOTES"})))
	e.call("POST", "/api/v1/backups", tok, nil)
	out := buf.String()
	for _, s := range []string{tok, "TOP-SECRET", testSecret} {
		if strings.Contains(out, s) {
			t.Fatalf("log contains %q", s)
		}
	}
	if !strings.Contains(out, "request") {
		t.Fatal("expected access logs")
	}
	_ = json.Marshal
}
