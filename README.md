# DAYMARK

Plan your day. Track your progress. A private, local-first task, reminder and progress app (Flutter on Android and web, Go + PostgreSQL sync service).

## Status

| Area | State |
|---|---|
| Brand (supplied DAYMARK artwork, icon/favicon/manifest mapping, brand guide, Flutter theme tokens and logo widgets) | Done. Assets applied by `branding/apply_brand.py` and verified; Dart files **not compiled** (no Flutter SDK in the build environment). See `branding/brand-guide.md` for known issues and missing variants. |
| Go backend (pairing, device auth, sync, conflicts, backup/restore, migrations, Docker, Render blueprint) | Done and tested: 43 tests passing, including real PostgreSQL integration tests (also run with `-race`). Compiled binary smoke-tested. **Docker image and Render deploy not run** (no Docker/Render access here). |
| Flutter app (Drift DB, sync client, UI, notifications, focus timer, reports) | **Not started.** The protocol the client must implement is specified in `docs/api-and-sync.md`. |

## Layout

```
branding/    source/ (supplied artwork, unmodified), apply_brand.py, brand-guide.md, fonts/
apps/client/ Flutter theme tokens, logo widgets, bundled logos/font, staged Android/web icon files (app itself not yet built)
backend/     Go API (cmd/api, internal/{config,database,security,auth,sync,backup,api}, migrations)
docs/        api-and-sync.md, security.md, deployment.md
```

## Quick start (backend)

```powershell
copy .env.example .env      # set POSTGRES_PASSWORD and DAYMARK_SETUP_SECRET
docker compose up --build
```
Full instructions, tests, Render deployment and troubleshooting: [docs/deployment.md](docs/deployment.md).
Protocol and conflict rules: [docs/api-and-sync.md](docs/api-and-sync.md). Threat model: [docs/security.md](docs/security.md). Brand: [branding/brand-guide.md](branding/brand-guide.md).

## Design decisions worth knowing

- **No JWT, no accounts:** one-time pairing codes issue revocable per-device credentials (bearer token on mobile, HttpOnly cookie on web).
- **Field-level conflict detection** with server revisions (not device clocks); the losing value is preserved for manual resolution.
- **Tombstones win:** a stale device can never resurrect a deleted record.
- **No foreign keys on synced tables**, deliberately: offline devices deliver children and parents in any order.
- **Backup is separate from sync:** restores validate first, default to non-destructive `merge`, and `replace` refuses to discard newer data without `force`.
- Simplifications vs the original spec: tasks/projects live in one registry-driven `sync` package instead of separate packages; rate limiting is in-memory (single instance).
