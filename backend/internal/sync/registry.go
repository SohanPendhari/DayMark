// Package sync implements DAYMARK's two-way synchronization: a static entity registry
// (the only source of table and column names), strict field validation, an idempotent
// transactional push, a cursor-based pull, and field-level conflict handling.
package sync

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

type Kind int

const (
	Text Kind = iota
	Int
	Bool
	Time
	UUID
	JSON
	Enum
)

// Col describes one client-writable column.
type Col struct {
	Name      string
	Kind      Kind
	Required  bool // must be present and non-null on create; cannot be nulled later
	Immutable bool // settable on create only
	MaxLen    int  // Text, in characters
	Min, Max  int64
	Enum      []string
}

type Entity struct {
	Name       string // wire name and table name; both come from this static list only
	AppendOnly bool   // may be created and deleted, never edited
	Cols       []Col
	byName     map[string]*Col
}

func (e *Entity) Col(name string) *Col { return e.byName[name] }

var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func ValidUUID(s string) bool { return uuidRe.MatchString(s) }

var Entities = []*Entity{
	{Name: "projects", Cols: []Col{
		{Name: "name", Kind: Text, Required: true, MaxLen: 200},
		{Name: "description", Kind: Text, MaxLen: 5000},
		{Name: "color", Kind: Text, MaxLen: 16},
		{Name: "created_at", Kind: Time, Required: true, Immutable: true},
		{Name: "updated_at", Kind: Time, Required: true},
		{Name: "archived_at", Kind: Time},
	}},
	{Name: "tasks", Cols: []Col{
		{Name: "title", Kind: Text, Required: true, MaxLen: 500},
		{Name: "description", Kind: Text, MaxLen: 20000},
		{Name: "status", Kind: Enum, Required: true, Enum: []string{"pending", "in_progress", "completed", "cancelled"}},
		{Name: "priority", Kind: Int, Required: true, Min: 0, Max: 3},
		{Name: "project_id", Kind: UUID},
		{Name: "category", Kind: Text, MaxLen: 100},
		{Name: "created_at", Kind: Time, Required: true, Immutable: true},
		{Name: "updated_at", Kind: Time, Required: true},
		{Name: "start_at", Kind: Time},
		{Name: "due_at", Kind: Time},
		{Name: "completed_at", Kind: Time},
		{Name: "estimated_minutes", Kind: Int, Min: 0, Max: 100000},
		{Name: "postponed_count", Kind: Int, Required: true, Min: 0, Max: 100000},
		{Name: "recurrence_rule", Kind: Text, MaxLen: 500},
	}},
	{Name: "subtasks", Cols: []Col{
		{Name: "task_id", Kind: UUID, Required: true, Immutable: true},
		{Name: "title", Kind: Text, Required: true, MaxLen: 500},
		{Name: "is_done", Kind: Bool, Required: true},
		{Name: "sort_order", Kind: Int, Required: true, Min: -1000000, Max: 1000000},
		{Name: "created_at", Kind: Time, Required: true, Immutable: true},
		{Name: "updated_at", Kind: Time, Required: true},
	}},
	{Name: "reminders", Cols: []Col{
		{Name: "task_id", Kind: UUID, Required: true, Immutable: true},
		{Name: "scheduled_at", Kind: Time, Required: true},
		{Name: "recurrence_rule", Kind: Text, MaxLen: 500},
		{Name: "time_zone", Kind: Text, MaxLen: 64},
		{Name: "enabled", Kind: Bool, Required: true},
		{Name: "created_at", Kind: Time, Required: true, Immutable: true},
		{Name: "updated_at", Kind: Time, Required: true},
	}},
	{Name: "activity_logs", AppendOnly: true, Cols: []Col{
		{Name: "task_id", Kind: UUID},
		{Name: "event_type", Kind: Text, Required: true, MaxLen: 40},
		{Name: "occurred_at", Kind: Time, Required: true},
		{Name: "device_id", Kind: UUID},
		{Name: "metadata", Kind: JSON},
		{Name: "created_at", Kind: Time, Required: true},
	}},
	{Name: "focus_sessions", Cols: []Col{
		{Name: "task_id", Kind: UUID},
		{Name: "started_at", Kind: Time, Required: true, Immutable: true},
		{Name: "ended_at", Kind: Time},
		{Name: "accumulated_seconds", Kind: Int, Required: true, Min: 0, Max: 31_536_000},
		{Name: "created_at", Kind: Time, Required: true, Immutable: true},
		{Name: "updated_at", Kind: Time, Required: true},
	}},
}

var byName = map[string]*Entity{}

func init() {
	for _, e := range Entities {
		e.byName = map[string]*Col{}
		for i := range e.Cols {
			e.byName[e.Cols[i].Name] = &e.Cols[i]
		}
		byName[e.Name] = e
	}
}

func Lookup(name string) *Entity { return byName[name] }

var eventTypeRe = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

func isNull(raw json.RawMessage) bool { return bytes.Equal(bytes.TrimSpace(raw), []byte("null")) }

// Decode validates one JSON value against a column and returns a comparable Go value
// (string, int64, bool, time.Time in UTC, parsed JSON, or nil).
func Decode(c *Col, raw json.RawMessage) (any, error) {
	if len(raw) == 0 || isNull(raw) {
		if c.Required {
			return nil, fmt.Errorf("%s is required", c.Name)
		}
		return nil, nil
	}
	bad := func(format string, a ...any) (any, error) {
		return nil, fmt.Errorf("%s: %s", c.Name, fmt.Sprintf(format, a...))
	}
	switch c.Kind {
	case Text:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return bad("must be a string")
		}
		if !utf8.ValidString(s) || strings.ContainsRune(s, 0) {
			return bad("invalid characters")
		}
		if utf8.RuneCountInString(s) > c.MaxLen {
			return bad("too long (max %d)", c.MaxLen)
		}
		if c.Required && strings.TrimSpace(s) == "" {
			return bad("must not be empty")
		}
		if c.Name == "event_type" && !eventTypeRe.MatchString(s) {
			return bad("must be lower_snake_case")
		}
		return s, nil
	case Int:
		var n int64
		if err := json.Unmarshal(raw, &n); err != nil {
			return bad("must be an integer")
		}
		if n < c.Min || n > c.Max {
			return bad("must be between %d and %d", c.Min, c.Max)
		}
		return n, nil
	case Bool:
		var b bool
		if err := json.Unmarshal(raw, &b); err != nil {
			return bad("must be a boolean")
		}
		return b, nil
	case Time:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return bad("must be an RFC 3339 string")
		}
		t, err := time.Parse(time.RFC3339Nano, s)
		if err != nil {
			return bad("must be an RFC 3339 timestamp")
		}
		if t.Year() < 1970 || t.Year() > 2200 {
			return bad("out of range")
		}
		return t.UTC().Round(time.Microsecond), nil // PostgreSQL stores microseconds
	case UUID:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil || !ValidUUID(s) {
			return bad("must be a UUID")
		}
		return strings.ToLower(s), nil
	case Enum:
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return bad("must be a string")
		}
		for _, v := range c.Enum {
			if v == s {
				return s, nil
			}
		}
		return bad("must be one of %s", strings.Join(c.Enum, ", "))
	case JSON:
		if len(raw) > 16*1024 {
			return bad("too large (max 16 KB)")
		}
		var v any
		if err := json.Unmarshal(raw, &v); err != nil {
			return bad("invalid JSON")
		}
		switch v.(type) {
		case map[string]any, []any:
			return v, nil
		}
		return bad("must be an object or array")
	}
	return bad("unsupported kind")
}

// Bind converts a decoded value to a database argument.
func Bind(c *Col, v any) any {
	if v == nil {
		return nil
	}
	if c.Kind == JSON {
		b, _ := json.Marshal(v)
		return string(b)
	}
	return v
}

// Placeholder returns the SQL placeholder for argument position n.
func Placeholder(c *Col, n int) string {
	if c.Kind == JSON {
		return fmt.Sprintf("$%d::jsonb", n)
	}
	return fmt.Sprintf("$%d", n)
}

// SameValue reports whether two decoded values are equal.
func SameValue(a, b any) bool {
	if ta, ok := a.(time.Time); ok {
		tb, ok := b.(time.Time)
		return ok && ta.Equal(tb)
	}
	return reflect.DeepEqual(a, b)
}

// ValidateFields checks client-supplied fields against the registry. Unknown fields,
// read-only fields (rev, deleted_at, ...), and immutable edits are all rejected.
func ValidateFields(e *Entity, fields map[string]json.RawMessage, create bool) (map[string]any, error) {
	out := make(map[string]any, len(fields))
	for name, raw := range fields {
		c := e.Col(name)
		if c == nil {
			return nil, fmt.Errorf("unknown field %q", name)
		}
		if !create && c.Immutable {
			return nil, fmt.Errorf("%s cannot be changed after creation", name)
		}
		v, err := Decode(c, raw)
		if err != nil {
			return nil, err
		}
		out[name] = v
	}
	if create {
		for i := range e.Cols {
			c := &e.Cols[i]
			if _, ok := out[c.Name]; !ok && c.Required {
				return nil, fmt.Errorf("%s is required", c.Name)
			}
		}
	}
	return out, nil
}
