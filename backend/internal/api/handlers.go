package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/daymark/daymark/backend/internal/auth"
	"github.com/daymark/daymark/backend/internal/backup"
	"github.com/daymark/daymark/backend/internal/security"
	dmsync "github.com/daymark/daymark/backend/internal/sync"
)

// ---- health -------------------------------------------------------------------------

// health is a cheap liveness probe (no database access) suitable for Render's health check.
func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "version": s.version, "time": time.Now().UTC()})
}

// ready verifies the database is reachable. Clients use it for the "test connection" step.
func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.db.PingContext(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "db_unavailable", "database unavailable")
		return
	}
	init, err := s.auth.Initialized(ctx)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "db_unavailable", "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ready", "initialized": init, "version": s.version})
}

// ---- setup & pairing ----------------------------------------------------------------

// gate applies the strict per-IP rate limit and the failure lockout shared by every
// endpoint that accepts a secret or a pairing code. It returns the per-IP guard key.
func (s *Server) gate(w http.ResponseWriter, r *http.Request) (ip string, ok bool) {
	ip = s.clientIP(r)
	if !s.sensitive.Allow(ip) || s.guard.Blocked("ip:"+ip) || s.guard.Blocked("global") {
		w.Header().Set("Retry-After", "60")
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; wait a few minutes")
		return ip, false
	}
	return ip, true
}

func (s *Server) failed(ip string) { s.guard.Fail("ip:" + ip); s.guard.Fail("global") }

type setupReq struct {
	SetupSecret string `json:"setup_secret"`
	RevokeAll   bool   `json:"revoke_all_devices"`
}

type codeResp struct {
	PairingCode string    `json:"pairing_code"`
	ExpiresAt   time.Time `json:"expires_at"`
	Revoked     int64     `json:"devices_revoked,omitempty"`
}

// setupInit initializes a brand-new private instance exactly once and issues the first
// pairing code. It requires the owner's bootstrap secret (an environment variable).
func (s *Server) setupInit(w http.ResponseWriter, r *http.Request) {
	ip, ok := s.gate(w, r)
	if !ok {
		return
	}
	var req setupReq
	if !decode(w, r, &req) {
		return
	}
	if !security.SecretEqual(req.SetupSecret, s.cfg.SetupSecret) {
		s.failed(ip)
		writeErr(w, http.StatusUnauthorized, "unauthorized", "invalid setup secret")
		return
	}
	if err := s.auth.Init(r.Context()); errors.Is(err, auth.ErrAlreadyInitialized) {
		writeErr(w, http.StatusConflict, "already_initialized", "already initialized; use /setup/recover to re-pair")
		return
	} else if err != nil {
		s.internal(w, r, err)
		return
	}
	code, exp, err := s.auth.NewPairingCode(r.Context(), "")
	if err != nil {
		s.internal(w, r, err)
		return
	}
	s.log.Info("instance initialized")
	writeJSON(w, http.StatusCreated, codeResp{PairingCode: code, ExpiresAt: exp})
}

// setupRecover is the owner-only way back in when every device is lost or compromised.
// It never touches data. It voids outstanding codes, optionally revokes all devices,
// and issues one fresh code.
func (s *Server) setupRecover(w http.ResponseWriter, r *http.Request) {
	ip, ok := s.gate(w, r)
	if !ok {
		return
	}
	var req setupReq
	if !decode(w, r, &req) {
		return
	}
	if !security.SecretEqual(req.SetupSecret, s.cfg.SetupSecret) {
		s.failed(ip)
		writeErr(w, http.StatusUnauthorized, "unauthorized", "invalid setup secret")
		return
	}
	if init, err := s.auth.Initialized(r.Context()); err != nil {
		s.internal(w, r, err)
		return
	} else if !init {
		writeErr(w, http.StatusConflict, "not_initialized", "not initialized yet; use /setup/init")
		return
	}
	resp := codeResp{}
	if err := s.auth.RevokeOutstandingCodes(r.Context()); err != nil {
		s.internal(w, r, err)
		return
	}
	if req.RevokeAll {
		n, err := s.auth.RevokeAll(r.Context())
		if err != nil {
			s.internal(w, r, err)
			return
		}
		resp.Revoked = n
	}
	var err error
	if resp.PairingCode, resp.ExpiresAt, err = s.auth.NewPairingCode(r.Context(), ""); err != nil {
		s.internal(w, r, err)
		return
	}
	s.log.Warn("recovery pairing code issued", "devices_revoked", resp.Revoked)
	writeJSON(w, http.StatusCreated, resp)
}

type pairReq struct {
	Code     string `json:"code"`
	Label    string `json:"label"`
	Username string `json:"username"`
	Platform string `json:"platform"`
}

// pair exchanges a single-use code for a device credential. Mobile receives the token in
// the body (to store in platform secure storage); web receives it only as an HttpOnly cookie.
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	ip, ok := s.gate(w, r)
	if !ok {
		return
	}
	var req pairReq
	if !decode(w, r, &req) {
		return
	}
	d, token, err := s.auth.Pair(r.Context(), req.Code, req.Label, req.Username, req.Platform)
	switch {
	case errors.Is(err, auth.ErrInvalidCode):
		s.failed(ip)
		writeErr(w, http.StatusUnauthorized, "invalid_code", "the pairing code is invalid, expired or already used")
		return
	case errors.Is(err, auth.ErrInvalidInput):
		writeErr(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	resp := map[string]any{"device": d, "server_time": time.Now().UTC()}
	if d.Platform == "web" {
		s.setCookie(w, token)
	} else {
		resp["token"] = token
	}
	s.log.Info("device paired", "device_id", d.ID, "platform", d.Platform)
	writeJSON(w, http.StatusCreated, resp)
}

func (s *Server) setCookie(w http.ResponseWriter, token string) {
	ss := map[string]http.SameSite{"none": http.SameSiteNoneMode, "lax": http.SameSiteLaxMode, "strict": http.SameSiteStrictMode}[s.cfg.CookieSameSite]
	http.SetCookie(w, &http.Cookie{
		Name: cookieName, Value: token, Path: "/api/", HttpOnly: true,
		Secure:   s.cfg.Production() || s.cfg.CookieSameSite == "none",
		SameSite: ss, MaxAge: int(s.cfg.DeviceTTL.Seconds()),
	})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/api/", MaxAge: -1, HttpOnly: true,
		Secure: s.cfg.Production() || s.cfg.CookieSameSite == "none"})
	w.WriteHeader(http.StatusNoContent)
}

// ---- session & devices --------------------------------------------------------------

func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	if viaCookie, _ := r.Context().Value(cookieAuthKey).(bool); viaCookie {
		if c, err := r.Cookie(cookieName); err == nil {
			s.setCookie(w, c.Value) // slide the cookie lifetime along with server-side activity
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"device": deviceOf(r), "server_time": time.Now().UTC()})
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	list, err := s.auth.ListDevices(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": list, "current_device_id": deviceOf(r).ID})
}

func (s *Server) newPairingCode(w http.ResponseWriter, r *http.Request) {
	if !s.sensitive.Allow("code:" + deviceOf(r).ID) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many requests")
		return
	}
	code, exp, err := s.auth.NewPairingCode(r.Context(), deviceOf(r).ID)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, codeResp{PairingCode: code, ExpiresAt: exp})
}

func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	switch err := s.auth.Revoke(r.Context(), id); {
	case errors.Is(err, auth.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "device not found")
	case err != nil:
		s.internal(w, r, err)
	default:
		s.log.Warn("device revoked", "device_id", id, "by", deviceOf(r).ID)
		w.WriteHeader(http.StatusNoContent)
	}
}

// ---- sync ---------------------------------------------------------------------------

func (s *Server) push(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Ops []dmsync.Op `json:"ops"`
	}
	if !decode(w, r, &req) {
		return
	}
	res, err := s.sync.Push(r.Context(), deviceOf(r).ID, req.Ops)
	switch {
	case errors.Is(err, dmsync.ErrInvalid):
		writeErr(w, http.StatusBadRequest, "invalid_request", err.Error())
	case err != nil:
		s.internal(w, r, err) // whole batch rolled back; client keeps the ops queued and retries
	default:
		writeJSON(w, http.StatusOK, map[string]any{"results": res, "server_time": time.Now().UTC()})
	}
}

func (s *Server) pull(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cursor, limit := int64(0), 0
	var err error
	if v := q.Get("cursor"); v != "" {
		if cursor, err = strconv.ParseInt(v, 10, 64); err != nil || cursor < 0 {
			writeErr(w, http.StatusBadRequest, "invalid_request", "cursor must be a non-negative integer")
			return
		}
	}
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 {
			writeErr(w, http.StatusBadRequest, "invalid_request", "limit must be a positive integer")
			return
		}
	}
	resp, err := s.sync.Pull(r.Context(), cursor, limit)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) syncStatus(w http.ResponseWriter, r *http.Request) {
	st, err := s.sync.Status(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": st, "device": deviceOf(r)})
}

func (s *Server) conflicts(w http.ResponseWriter, r *http.Request) {
	list, err := s.sync.Conflicts(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"conflicts": list})
}

func (s *Server) resolveConflict(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found", "conflict not found")
		return
	}
	var req struct {
		Resolution string `json:"resolution"`
	}
	if !decode(w, r, &req) {
		return
	}
	rev, err := s.sync.Resolve(r.Context(), id, deviceOf(r).ID, req.Resolution)
	switch {
	case errors.Is(err, dmsync.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "conflict not found or already resolved")
	case errors.Is(err, dmsync.ErrInvalid):
		writeErr(w, http.StatusBadRequest, "invalid_request", err.Error())
	case err != nil:
		s.internal(w, r, err)
	default:
		writeJSON(w, http.StatusOK, map[string]any{"resolved": true, "rev": rev})
	}
}

// ---- backups ------------------------------------------------------------------------

func (s *Server) createBackup(w http.ResponseWriter, r *http.Request) {
	m, err := s.backup.Create(r.Context(), "manual", deviceOf(r).ID)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func (s *Server) listBackups(w http.ResponseWriter, r *http.Request) {
	list, err := s.backup.List(r.Context())
	if err != nil {
		s.internal(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"backups": list})
}

func (s *Server) downloadBackup(w http.ResponseWriter, r *http.Request) {
	_, raw, err := s.backup.Load(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, backup.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "backup not found")
	case errors.Is(err, backup.ErrInvalid):
		writeErr(w, http.StatusConflict, "backup_corrupt", err.Error())
	case err != nil:
		s.internal(w, r, err)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="daymark-backup-%s.json"`, time.Now().UTC().Format("2006-01-02")))
		w.Write(raw)
	}
}

func (s *Server) restore(w http.ResponseWriter, r *http.Request) {
	var req backup.RestoreRequest
	if !decode(w, r, &req) {
		return
	}
	plan, err := s.backup.Restore(r.Context(), deviceOf(r).ID, req)
	switch {
	case errors.Is(err, backup.ErrWouldOverwriteNewer):
		var b errBody
		b.Error.Code = "would_overwrite_newer"
		b.Error.Message = "records changed after this backup would be discarded; review the plan and resend with force=true"
		b.Plan = plan
		writeJSON(w, http.StatusConflict, b)
	case errors.Is(err, backup.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "backup not found")
	case errors.Is(err, backup.ErrInvalid):
		writeErr(w, http.StatusBadRequest, "invalid_backup", err.Error())
	case err != nil:
		s.internal(w, r, err)
	default:
		if plan.Applied {
			s.log.Warn("backup restored", "mode", plan.Mode, "device_id", deviceOf(r).ID)
		}
		writeJSON(w, http.StatusOK, plan)
	}
}

// ---- maintenance --------------------------------------------------------------------

// RunMaintenance takes scheduled backups (only when data changed since the last one) and
// prunes stale idempotency records and pairing codes. It returns when ctx is cancelled.
func (s *Server) RunMaintenance(ctx context.Context) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	lastBackup := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		if s.cfg.BackupInterval > 0 && time.Since(lastBackup) >= s.cfg.BackupInterval {
			lastBackup = time.Now()
			s.scheduledBackup(ctx)
		}
		s.sync.Prune(ctx, 120*24*time.Hour)
		s.auth.Prune(ctx)
	}
}

func (s *Server) scheduledBackup(ctx context.Context) {
	cur, err := s.sync.LatestRev(ctx)
	if err != nil {
		s.log.Error("scheduled backup: rev lookup failed", "err", err.Error())
		return
	}
	var last int64 = -1
	s.db.QueryRowContext(ctx, `SELECT latest_rev FROM backups WHERE kind <> 'pre_restore' ORDER BY created_at DESC LIMIT 1`).Scan(&last)
	if last == cur {
		return // nothing changed since the last snapshot
	}
	if _, err := s.backup.Create(ctx, "scheduled", ""); err != nil {
		s.log.Error("scheduled backup failed", "err", err.Error())
		return
	}
	s.log.Info("scheduled backup created")
}
