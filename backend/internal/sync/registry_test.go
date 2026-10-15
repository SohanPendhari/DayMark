package sync

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func raw(s string) json.RawMessage { return json.RawMessage(s) }

func TestDecodeKinds(t *testing.T) {
	task := Lookup("tasks")
	ok := map[string]string{
		"title": `"Hi"`, "priority": `3`, "status": `"completed"`, "due_at": `"2026-03-01T10:00:00+05:30"`,
		"project_id": `"123e4567-e89b-12d3-a456-426614174000"`, "description": `null`,
	}
	for f, v := range ok {
		if _, err := Decode(task.Col(f), raw(v)); err != nil {
			t.Errorf("%s=%s should be valid: %v", f, v, err)
		}
	}
	bad := map[string]string{
		"title": `""`, "priority": `4`, "status": `"nope"`, "due_at": `"2026-13-01"`, "project_id": `"x"`,
		"estimated_minutes": `1.5`, "postponed_count": `"3"`, "created_at": `null`, "title2": `1`,
	}
	for f, v := range bad {
		c := task.Col(f)
		if c == nil {
			continue
		}
		if _, err := Decode(c, raw(v)); err == nil {
			t.Errorf("%s=%s should be invalid", f, v)
		}
	}
	if _, err := Decode(task.Col("title"), raw(`"`+strings.Repeat("é", 501)+`"`)); err == nil {
		t.Error("length is counted in characters, 501 must fail")
	}
	if _, err := Decode(task.Col("title"), raw(`"`+strings.Repeat("é", 500)+`"`)); err != nil {
		t.Errorf("500 multibyte characters must pass: %v", err)
	}
	if _, err := Decode(task.Col("title"), raw(`"a\u0000b"`)); err == nil {
		t.Error("NUL bytes must be rejected (PostgreSQL cannot store them)")
	}
}

func TestTimesNormalizeToUTC(t *testing.T) {
	v, err := Decode(Lookup("tasks").Col("due_at"), raw(`"2026-03-01T10:00:00+05:30"`))
	if err != nil {
		t.Fatal(err)
	}
	if got := v.(time.Time); got.Location() != time.UTC || got.Hour() != 4 || got.Minute() != 30 {
		t.Fatalf("got %v", got)
	}
	a, _ := Decode(Lookup("tasks").Col("due_at"), raw(`"2026-03-01T04:30:00Z"`))
	if !SameValue(v, a) {
		t.Fatal("same instant in different zones must compare equal")
	}
}

func TestValidateFields(t *testing.T) {
	task := Lookup("tasks")
	if _, err := ValidateFields(task, map[string]json.RawMessage{"rev": raw("1")}, true); err == nil {
		t.Error("server-managed field must be rejected")
	}
	if _, err := ValidateFields(task, map[string]json.RawMessage{"created_at": raw(`"2026-01-01T00:00:00Z"`)}, false); err == nil {
		t.Error("immutable field must be rejected on update")
	}
	if _, err := ValidateFields(task, map[string]json.RawMessage{"title": raw(`"x"`)}, true); err == nil {
		t.Error("missing required fields must be rejected on create")
	}
}

func TestRegistryIsConsistent(t *testing.T) {
	names := map[string]bool{}
	for _, e := range Entities {
		if names[e.Name] || !identOK(e.Name) {
			t.Errorf("bad or duplicate entity %q", e.Name)
		}
		names[e.Name] = true
		for _, c := range e.Cols {
			if !identOK(c.Name) {
				t.Errorf("%s.%s is not a safe SQL identifier", e.Name, c.Name)
			}
			switch c.Name {
			case "id", "rev", "field_revs", "deleted_at", "updated_by", "server_updated_at":
				t.Errorf("%s.%s collides with a server-managed column", e.Name, c.Name)
			}
			if c.Kind == Text && c.MaxLen == 0 {
				t.Errorf("%s.%s: text column needs MaxLen", e.Name, c.Name)
			}
		}
	}
	if Lookup("users") != nil || Lookup("tasks; DROP TABLE tasks") != nil {
		t.Error("lookup must only know registered entities")
	}
}

func identOK(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r == '_' || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}
