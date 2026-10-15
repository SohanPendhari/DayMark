# DAYMARK security model and threat model

## What protects the app

| Control | Detail |
|---|---|
| Private instance | No sign-up. The owner holds a bootstrap secret (`DAYMARK_SETUP_SECRET`, at least 24 characters, refused at startup if missing or short). |
| Pairing | 8-character code (about 39.6 bits, no look-alike symbols), 10 minute expiry, single use, consumed atomically (verified: 8 concurrent attempts, 1 winner). Stored only as a keyed HMAC. |
| Brute force | Strict per-IP limit (about 5 attempts/minute), a 10-failure per-IP lockout and a 10-failure global lockout over 15 minutes, on `/pair`, `/setup/*`. Constant-time secret comparison. |
| Device credentials | 256-bit random token, only its SHA-256 is stored. Revocable; revocation is effective on the next request. Expires after 180 days of inactivity (`DEVICE_TTL`, sliding). |
| Web session | HttpOnly, Secure, SameSite cookie; the token is never in a response body and never in `localStorage`. Cookie-authenticated writes require `X-Daymark-Client: web` and an allowed `Origin`. |
| Mobile | Token returned once; the app must store it in platform secure storage (Keystore). |
| Transport | HTTPS terminated by Render; HSTS sent in production; plain-HTTP requests are refused when proxy hops are configured. |
| CORS | Exact origins only; no wildcard; startup refuses `*`. |
| Input | Strict JSON (unknown fields and trailing data rejected), static entity/column whitelist, typed validation, parameterized SQL only, 1 MB body (32 MB for restore), 100 ops per push. |
| Data exposure | Tombstones carry no content; server bookkeeping columns are never sent. Logs contain method, path, status, timing only. A test asserts no token, setup secret or task text appears in logs. |
| Database | Never exposed to clients; Render database has an empty IP allow-list. Use the internal connection string. |
| Process | Non-root distroless container, graceful shutdown, request timeouts, panic recovery. No debug endpoints. |

## Residual risks

- **Stolen unlocked phone or browser profile:** the attacker has full access until you revoke that device (Settings > Devices, from another device, or `POST /setup/recover` with `revoke_all_devices`). Use a device lock screen.
- **Stolen token (malware, backup of app data):** same as above. Tokens are not bound to hardware.
- **Lost setup secret:** you cannot add or recover devices. Rotate it by changing the Render env var (existing devices keep working; outstanding pairing codes become unverifiable and expire).
- **Compromised Render account or database:** the provider can read task data. There is no end-to-end encryption in v1.
- **Server-side data is plaintext in PostgreSQL**, protected only by Render's disk encryption and access controls.
- **Username is a label, not authentication.**
- **Shared global lockout:** an attacker who can reach the API can lock out pairing for 15 minutes (a denial of service, not a bypass). Existing devices are unaffected.
- **Rate-limit state is in memory:** it resets on restart and is per instance. This design assumes a single API instance.
- **Free-tier hosting** cold starts and database expiry are availability and durability risks, not confidentiality risks (see deployment.md).
- Dependencies: only `lib/pq` and `google/uuid`. Re-run `go list -m -u all` and `govulncheck` periodically (not run in this environment).

## Revocation and re-pairing

1. From any authorized device: `DELETE /devices/{id}`; the device is rejected immediately.
2. If no device is usable: `POST /setup/recover {"setup_secret": "...", "revoke_all_devices": true}` returns a fresh code. Pair the replacement device with it.
3. After a suspected compromise: revoke all, rotate `DAYMARK_SETUP_SECRET`, review `/devices`.
