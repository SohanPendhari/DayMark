# DAYMARK API and sync protocol (v1)

Base path `/api/v1`. JSON only. Errors: `{"error":{"code":"...","message":"..."}}`.
Auth: mobile sends `Authorization: Bearer dmk_...`; web uses the HttpOnly `dm_session` cookie and must add the header `X-Daymark-Client: web` on every non-GET request.

## Endpoints

| Method and path | Auth | Purpose |
|---|---|---|
| GET `/health` | none | Liveness (no DB). Used by Render. |
| GET `/health/ready` | none | DB reachable? Returns `initialized`. Use for the setup "test connection" step. |
| POST `/setup/init` | setup secret | First-time init; returns the first pairing code. 409 once initialized. |
| POST `/setup/recover` | setup secret | Owner recovery: voids outstanding codes, optional `revoke_all_devices`, returns a fresh code. Never touches data. |
| POST `/pair` | pairing code | `{code,label,username,platform}`; platform is `android`, `web` or `other`. Mobile gets `token` once; web gets only the cookie. |
| GET `/session` | device | Current device; slides the web cookie lifetime. |
| POST `/session/logout` | none | Clears the web cookie (does not revoke the device). |
| GET `/devices` | device | List devices and `current_device_id`. |
| POST `/devices/pairing-codes` | device | Code for adding another device. |
| DELETE `/devices/{id}` | device | Revoke; effective immediately. |
| POST `/sync/push` | device | Upload operations. |
| GET `/sync/pull?cursor=N&limit=M` | device | Download changes after a cursor. |
| GET `/sync/status` | device | `latest_rev`, `unresolved_conflicts`, `last_backup_at`. |
| GET `/sync/conflicts`, POST `/sync/conflicts/{id}/resolve` | device | List / resolve (`keep_server` or `apply_mine`). |
| POST `/backups`, GET `/backups`, GET `/backups/{id}/download`, POST `/backups/restore` | device | Snapshots and restore. |

## Records

Every synced row has a client-generated UUID `id`, a server `rev` (global, strictly increasing change number), and a tombstone `deleted_at`. Six entities: `projects`, `tasks`, `subtasks`, `reminders`, `activity_logs` (append-only), `focus_sessions`. Column lists and limits are in `backend/internal/sync/registry.go`, and that registry is the only source of table and column names, so clients can never name a table or column. Timestamps are RFC 3339 and are stored in UTC at microsecond precision. Reminder local notification ids never leave the device.

## Push

```json
POST /sync/push
{"ops":[{"op_id":"<uuid>","entity":"tasks","id":"<uuid>","type":"create|update|delete","base_rev":0,"fields":{"title":"..."}}]}
```
1-100 ops per request. Response `{"results":[{"op_id","status","rev","conflicts","error","replayed"}]}`, one per op, same order.

| status | Client action |
|---|---|
| `applied` | Remove the op from the queue; store `rev` as the record's `base_rev`. |
| `partial` | Unrelated fields were applied; `conflicts` lists fields where the server value won. Remove the op; refresh via pull. |
| `conflict` | Nothing applied (`already_exists`, `record_deleted`, or all fields conflicted). Remove the op; surface it if relevant. |
| `rejected` | The op is invalid and retrying will not help. Move it to the "failed" list for the Sync dashboard. |
| (HTTP 5xx / network error) | **The whole batch rolled back.** Keep every op queued and retry with backoff and jitter. |

Rules the server enforces:
- **Idempotent:** an `op_id` is processed at most once. Resending returns the stored result with `"replayed":true`. Always reuse the same `op_id` on retry.
- **Atomic:** a database error rolls back the whole batch, including idempotency records. A validation problem rejects only that op.
- **Create** requires every required field. An existing id returns `conflict/already_exists`.
- **Update** sends only changed fields. Immutable fields (`created_at`, `task_id`, `started_at`) are rejected.
- **Delete** is idempotent and always wins. A tombstoned record can never be edited or re-created by a stale device.
- **base_rev** is the `rev` the device last saw for that record. For several queued edits before an ack, `0` or the last known rev both work (see below).

## Conflict policy

Detection is per field, not per record. A field conflicts only if *another device* changed it at a revision newer than `base_rev`. Therefore:
- Edits to different fields of the same record merge silently.
- A device's own earlier edits never conflict with its later ones.
- If both devices set the same value, there is no conflict.
- Otherwise the server's value is kept (deterministic, independent of device clocks) and the losing value is stored. `GET /sync/conflicts` returns `{field:{mine,server}}`, and `apply_mine` re-applies it as a new edit.
- Ordering uses server revisions only, never device clocks. `updated_at` columns are display data.

## Pull

`GET /sync/pull?cursor=<last committed>&limit=200` (max 500) returns `{changes:[{entity,id,rev,deleted,data}], next_cursor, has_more, latest_rev}` ordered by `rev`. Tombstones carry only `{id, deleted_at}`.

Client procedure: apply `changes` to the local DB in one transaction (upsert, or delete when `deleted`); **commit `next_cursor` in that same transaction**; repeat while `has_more`; then reconcile reminders for changed tasks. Re-applying a change is harmless, so a crash before commit only repeats work. Skip changes that would overwrite a record with a still-pending local op, since that op will reconcile on push.

**Cursor safety:** all writers are serialized by a PostgreSQL advisory lock and revisions are allocated inside it, so commit order equals revision order. A client can never skip a revision. Revisions may have gaps after rollbacks, which is harmless.

## Backups

`POST /backups` snapshots everything (including tombstones) in one repeatable-read transaction and stores it gzipped with a SHA-256. Scheduled backups (default every 24 h) only run if data changed. Retention keeps the newest `BACKUP_RETENTION` (14) plus the 3 newest pre-restore safety snapshots.

**Sync vs restore:** sync moves *current* changes between devices; restore *rewinds* shared state to a past snapshot.

`POST /backups/restore {backup_id | backup, mode, dry_run, confirm:"RESTORE", force}`
- `dry_run:true` validates the whole file and returns a per-entity plan; nothing changes.
- `merge` (default) only re-creates records missing from the server. It never overwrites newer edits and never resurrects deletions.
- `replace` makes the server match the snapshot (extra records become tombstones, so every device converges through normal sync). If it would discard anything changed after the snapshot, it returns **409 `would_overwrite_newer`** with the plan, and proceeds only with `force:true`. A `pre_restore` safety snapshot is taken first, so a replace is itself reversible.
- Validation runs before any write; the apply is one transaction, so an interrupted restore changes nothing.
- Restore resets per-field conflict history; devices with unsynced edits will apply them on top of the restored state.
- Clients should treat a 409 or a restore as a prompt to run a pull.
