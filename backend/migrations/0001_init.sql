-- DAYMARK schema v1. Entities have no foreign keys on purpose: devices sync offline,
-- so a child (e.g. a subtask) can legitimately arrive before or after its parent.
-- Every synced row carries: rev (global change sequence), field_revs (per-field
-- revision + device, for field-level conflict detection), deleted_at (tombstone).

CREATE SEQUENCE change_seq;

CREATE TABLE instance (
    id             boolean PRIMARY KEY DEFAULT true CHECK (id),
    initialized_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE devices (
    id           uuid PRIMARY KEY,
    label        text NOT NULL,
    username     text NOT NULL,
    platform     text NOT NULL,
    token_hash   bytea NOT NULL UNIQUE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz
);

CREATE TABLE pairing_codes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code_hash  bytea NOT NULL UNIQUE,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);

CREATE TABLE projects (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    name text NOT NULL, description text, color text,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL, archived_at timestamptz
);

CREATE TABLE tasks (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    title text NOT NULL, description text,
    status text NOT NULL, priority integer NOT NULL DEFAULT 0,
    project_id uuid, category text,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL,
    start_at timestamptz, due_at timestamptz, completed_at timestamptz,
    estimated_minutes integer, postponed_count integer NOT NULL DEFAULT 0,
    recurrence_rule text
);

CREATE TABLE subtasks (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    task_id uuid NOT NULL, title text NOT NULL, is_done boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL
);

CREATE TABLE reminders (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    task_id uuid NOT NULL, scheduled_at timestamptz NOT NULL, recurrence_rule text,
    time_zone text, enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL
);

CREATE TABLE activity_logs (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    task_id uuid, event_type text NOT NULL, occurred_at timestamptz NOT NULL,
    device_id uuid, metadata jsonb, created_at timestamptz NOT NULL
);

CREATE TABLE focus_sessions (
    id uuid PRIMARY KEY, rev bigint NOT NULL, field_revs jsonb NOT NULL DEFAULT '{}',
    deleted_at timestamptz, updated_by uuid NOT NULL, server_updated_at timestamptz NOT NULL DEFAULT now(),
    task_id uuid, started_at timestamptz NOT NULL, ended_at timestamptz,
    accumulated_seconds integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL, updated_at timestamptz NOT NULL
);

CREATE INDEX projects_rev_idx ON projects (rev);
CREATE INDEX tasks_rev_idx ON tasks (rev);
CREATE INDEX tasks_status_idx ON tasks (status) WHERE deleted_at IS NULL;
CREATE INDEX tasks_due_idx ON tasks (due_at) WHERE deleted_at IS NULL;
CREATE INDEX tasks_project_idx ON tasks (project_id) WHERE deleted_at IS NULL;
CREATE INDEX subtasks_rev_idx ON subtasks (rev);
CREATE INDEX subtasks_task_idx ON subtasks (task_id);
CREATE INDEX reminders_rev_idx ON reminders (rev);
CREATE INDEX reminders_task_idx ON reminders (task_id);
CREATE INDEX activity_logs_rev_idx ON activity_logs (rev);
CREATE INDEX activity_logs_task_idx ON activity_logs (task_id);
CREATE INDEX focus_sessions_rev_idx ON focus_sessions (rev);

-- Idempotency: every processed operation's result is stored by its client-generated id.
CREATE TABLE applied_ops (
    op_id      uuid PRIMARY KEY,
    device_id  uuid NOT NULL,
    result     jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX applied_ops_created_idx ON applied_ops (created_at);

-- Field-level conflicts: the losing (rejected) values are preserved for manual resolution.
CREATE TABLE sync_conflicts (
    id          bigserial PRIMARY KEY,
    entity      text NOT NULL,
    record_id   uuid NOT NULL,
    op_id       uuid NOT NULL,
    device_id   uuid NOT NULL,
    fields      jsonb NOT NULL,  -- {"field": {"mine": v, "server": v}}
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolution  text
);
CREATE INDEX sync_conflicts_open_idx ON sync_conflicts (id) WHERE resolved_at IS NULL;

CREATE TABLE backups (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        text NOT NULL CHECK (kind IN ('manual','scheduled','pre_restore')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    latest_rev  bigint NOT NULL,
    record_counts jsonb NOT NULL,
    sha256      bytea NOT NULL,
    size_bytes  integer NOT NULL,
    payload     bytea NOT NULL  -- gzip-compressed JSON
);
CREATE INDEX backups_created_idx ON backups (created_at DESC);
