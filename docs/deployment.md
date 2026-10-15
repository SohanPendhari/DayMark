# Backend: run, test, deploy

## Local development (Windows, PowerShell)

Requirements: Go 1.22+, Docker Desktop (or a local PostgreSQL 14+).

```powershell
copy .env.example .env            # then fill POSTGRES_PASSWORD and DAYMARK_SETUP_SECRET
docker compose up --build         # PostgreSQL + API on http://localhost:8080
```
Without Docker, run PostgreSQL yourself, then:
```powershell
cd backend
$env:DATABASE_URL = "postgres://user:pass@localhost:5432/daymark?sslmode=disable"
$env:DAYMARK_SETUP_SECRET = "<24+ random characters>"
$env:DAYMARK_ENV = "development"
go run ./cmd/api migrate          # apply migrations and exit
go run ./cmd/api                  # start the API (also migrates unless MIGRATE_ON_START=false)
```
First-time setup:
```powershell
curl.exe -X POST http://localhost:8080/api/v1/setup/init -d '{\"setup_secret\":\"<secret>\"}'
```

## Tests

The integration tests use a real PostgreSQL and isolate each test in its own schema (dropped afterwards). The URL must already contain a `?`:
```powershell
$env:TEST_DATABASE_URL = "postgres://user:pass@localhost:5432/daymark_test?sslmode=disable"
cd backend
go vet ./...
go test -count=1 ./...
go test -race -count=1 ./...      # needs a C compiler (e.g. MinGW)
```
Without `TEST_DATABASE_URL` the database tests skip and only unit tests run.

## Deploy to Render

1. Push the repo to GitHub. In Render: **New > Blueprint**, pick the repo (`render.yaml`).
2. When prompted, set `DAYMARK_SETUP_SECRET` (use a password manager) and `ALLOWED_ORIGINS` (your exact web origin, e.g. `https://daymark.example.com`; leave the local origin out of production).
3. Wait for the deploy; `GET https://<service>.onrender.com/api/v1/health/ready` should return `{"status":"ready","initialized":false}`.
4. Initialize once: `POST /api/v1/setup/init` with the secret. Enter the returned code in the app within 10 minutes.
5. Migrations run automatically at start (`MIGRATE_ON_START=true`). To run them separately: `api migrate` as a one-off command.

Notes
- **HTTPS:** Render terminates TLS; the API refuses plain-HTTP requests and sends HSTS. `TRUST_PROXY_HOPS=1` makes rate limits use the real client IP.
- **Connection pooling:** `DB_MAX_OPEN_CONNS` (default 10). Keep it under your plan's connection limit.
- **Sleeping free tier:** the service sleeps after inactivity and the first request takes tens of seconds. Clients must treat timeouts as normal, keep working locally, and retry with backoff. Nothing is lost because pushes are idempotent and atomic.
- **Free PostgreSQL on Render expires** after a limited period (check Render's current terms). Plan for it: use a paid database, or download a backup regularly (`GET /backups/{id}/download`).
- **Single instance:** rate limits and maintenance are per process; do not scale out without moving them to the database.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| API exits with `invalid configuration` | Read the message: a missing `DATABASE_URL`, secret under 24 characters, wildcard or non-https origin in production. |
| `database not reachable` at start | Wrong URL, or the DB is still starting. The API retries for 30 s. On Render use the *internal* URL. |
| 401 on every call | Token revoked or expired (180 days idle). Re-pair (`/setup/recover`). |
| `invalid_code` | Expired (10 min), already used, or mistyped. Ambiguous letters are not used; dashes and case are ignored. |
| 429 `rate_limited` on pairing | Too many wrong attempts. Wait 15 minutes. |
| Browser: CORS error | The web origin is not in `ALLOWED_ORIGINS`, or has a trailing path or wrong scheme. |
| Browser pairs but then gets 401 | Cookie blocked. Cross-site needs `COOKIE_SAMESITE=none` + HTTPS. Better: serve the web app and API from the same site. |
| 403 `csrf` | Web client missing the `X-Daymark-Client: web` header, or the `Origin` is not allowed. |
| 409 `would_overwrite_newer` on restore | Intended safeguard. Review the plan; resend with `force:true` only if you accept losing newer changes. |
| 500 on push | Database problem. The batch rolled back; the client keeps the ops queued. Check logs with the `X-Request-Id`. |
