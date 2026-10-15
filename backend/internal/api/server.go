// Package api wires the HTTP layer: routing, middleware, and handlers.
package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/daymark/daymark/backend/internal/auth"
	"github.com/daymark/daymark/backend/internal/backup"
	"github.com/daymark/daymark/backend/internal/config"
	"github.com/daymark/daymark/backend/internal/security"
	dmsync "github.com/daymark/daymark/backend/internal/sync"
)

const (
	cookieName = "dm_session"
	clientHdr  = "X-Daymark-Client"
)

type Server struct {
	cfg       config.Config
	log       *slog.Logger
	db        *sql.DB
	auth      *auth.Service
	sync      *dmsync.Service
	backup    *backup.Service
	global    *security.Limiter
	sensitive *security.Limiter
	guard     *security.FailureGuard
	version   string
	mux       *http.ServeMux
}

type ctxKey int

const (
	deviceKey ctxKey = iota
	cookieAuthKey
)

func New(cfg config.Config, db *sql.DB, log *slog.Logger, version string) *Server {
	s := &Server{
		cfg: cfg, log: log, db: db, version: version,
		auth:      &auth.Service{DB: db, Secret: cfg.SetupSecret, DeviceTTL: cfg.DeviceTTL, CodeTTL: cfg.PairingCodeTTL},
		sync:      &dmsync.Service{DB: db},
		backup:    &backup.Service{DB: db, Retention: cfg.BackupRetention},
		global:    security.NewLimiter(20, 60),
		sensitive: security.NewLimiter(5.0/60, 5), // ~5 attempts/minute/IP
		guard:     security.NewFailureGuard(10, 15*time.Minute),
		mux:       http.NewServeMux(),
	}
	s.routes()
	return s
}

func (s *Server) Backup() *backup.Service { return s.backup }

func (s *Server) routes() {
	m := s.mux
	m.HandleFunc("GET /api/v1/health", s.health)
	m.HandleFunc("GET /api/v1/health/ready", s.ready)

	m.HandleFunc("POST /api/v1/setup/init", s.setupInit)
	m.HandleFunc("POST /api/v1/setup/recover", s.setupRecover)
	m.HandleFunc("POST /api/v1/pair", s.pair)
	m.HandleFunc("POST /api/v1/session/logout", s.logout)

	m.HandleFunc("GET /api/v1/session", s.requireAuth(s.session))
	m.HandleFunc("GET /api/v1/devices", s.requireAuth(s.listDevices))
	m.HandleFunc("POST /api/v1/devices/pairing-codes", s.requireAuth(s.newPairingCode))
	m.HandleFunc("DELETE /api/v1/devices/{id}", s.requireAuth(s.revokeDevice))

	m.HandleFunc("POST /api/v1/sync/push", s.requireAuth(s.push))
	m.HandleFunc("GET /api/v1/sync/pull", s.requireAuth(s.pull))
	m.HandleFunc("GET /api/v1/sync/status", s.requireAuth(s.syncStatus))
	m.HandleFunc("GET /api/v1/sync/conflicts", s.requireAuth(s.conflicts))
	m.HandleFunc("POST /api/v1/sync/conflicts/{id}/resolve", s.requireAuth(s.resolveConflict))

	m.HandleFunc("POST /api/v1/backups", s.requireAuth(s.createBackup))
	m.HandleFunc("GET /api/v1/backups", s.requireAuth(s.listBackups))
	m.HandleFunc("GET /api/v1/backups/{id}/download", s.requireAuth(s.downloadBackup))
	m.HandleFunc("POST /api/v1/backups/restore", s.requireAuth(s.restore))
}

// Handler returns the router wrapped in the middleware chain (outermost first).
func (s *Server) Handler() http.Handler {
	return s.recoverer(s.requestScope(s.cors(s.mux)))
}

// ---- helpers ------------------------------------------------------------------------

type errBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	Plan any `json:"plan,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	var b errBody
	b.Error.Code, b.Error.Message = code, msg
	writeJSON(w, status, b)
}

// decode reads exactly one JSON value, rejecting unknown fields and trailing data.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "request body too large")
		} else {
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		}
		return false
	}
	if _, err := dec.Token(); err != io.EOF {
		writeErr(w, http.StatusBadRequest, "bad_request", "unexpected data after JSON body")
		return false
	}
	return true
}

func (s *Server) internal(w http.ResponseWriter, r *http.Request, err error) {
	// Log the error class only; never request bodies, credentials or task content.
	s.log.Error("internal error", "path", r.URL.Path, "err", err.Error())
	writeErr(w, http.StatusInternalServerError, "internal", "internal error")
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxyHops > 0 {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			i := len(parts) - s.cfg.TrustProxyHops
			if i < 0 {
				i = 0
			}
			return strings.TrimSpace(parts[i])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Server) originAllowed(o string) bool {
	for _, a := range s.cfg.AllowedOrigins {
		if a == o {
			return true
		}
	}
	return false
}

// ---- middleware ---------------------------------------------------------------------

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.log.Error("panic", "path", r.URL.Path, "panic", rec)
				writeErr(w, http.StatusInternalServerError, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(c int) { w.status = c; w.ResponseWriter.WriteHeader(c) }

// requestScope: request id, security headers, HTTPS check, global rate limit, body limit,
// timeout, and a structured access log (method, path, status, duration only).
func (s *Server) requestScope(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := uuid.NewString()
		h := w.Header()
		h.Set("X-Request-Id", id)
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		if s.cfg.Production() {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		sw := &statusWriter{ResponseWriter: w, status: 200}

		switch {
		case s.cfg.Production() && s.cfg.TrustProxyHops > 0 && r.Header.Get("X-Forwarded-Proto") == "http":
			writeErr(sw, http.StatusBadRequest, "https_required", "use HTTPS")
		case r.Method != http.MethodOptions && !s.global.Allow(s.clientIP(r)):
			sw.Header().Set("Retry-After", "5")
			writeErr(sw, http.StatusTooManyRequests, "rate_limited", "too many requests")
		default:
			limit, timeout := s.cfg.MaxBodyBytes, 30*time.Second
			if r.URL.Path == "/api/v1/backups/restore" {
				limit, timeout = s.cfg.MaxRestoreBytes, 120*time.Second
			}
			ctx, cancel := context.WithTimeout(r.Context(), timeout)
			defer cancel()
			r = r.WithContext(ctx)
			if r.Body != nil {
				r.Body = http.MaxBytesReader(sw, r.Body, limit)
			}
			next.ServeHTTP(sw, r)
		}
		s.log.Info("request", "id", id, "method", r.Method, "path", r.URL.Path,
			"status", sw.status, "ms", time.Since(start).Milliseconds())
	})
}

// cors allows only exact configured origins (never a wildcard) and supports credentials
// so the web client's HttpOnly session cookie works cross-origin.
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); o != "" && s.originAllowed(o) {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", o)
			h.Set("Access-Control-Allow-Credentials", "true")
			h.Add("Vary", "Origin")
			if r.Method == http.MethodOptions {
				h.Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, "+clientHdr)
				h.Set("Access-Control-Max-Age", "600")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent) // no CORS headers => browser blocks the request
			return
		}
		next.ServeHTTP(w, r)
	})
}

// requireAuth accepts a Bearer token (mobile) or the HttpOnly session cookie (web).
// Cookie-authenticated unsafe requests must also carry the custom client header and,
// when the browser sends an Origin, an allowed one (CSRF defence in depth).
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, viaCookie := "", false
		if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
			token = strings.TrimSpace(h[7:])
		} else if c, err := r.Cookie(cookieName); err == nil {
			token, viaCookie = c.Value, true
		}
		if token == "" {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "authentication required")
			return
		}
		if viaCookie && r.Method != http.MethodGet && r.Method != http.MethodHead {
			if r.Header.Get(clientHdr) != "web" {
				writeErr(w, http.StatusForbidden, "csrf", "missing client header")
				return
			}
			if o := r.Header.Get("Origin"); o != "" && !s.originAllowed(o) {
				writeErr(w, http.StatusForbidden, "csrf", "origin not allowed")
				return
			}
		}
		d, err := s.auth.Authenticate(r.Context(), token)
		if errors.Is(err, auth.ErrUnauthorized) {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "device is not authorized; pair it again")
			return
		}
		if err != nil {
			s.internal(w, r, err)
			return
		}
		ctx := context.WithValue(r.Context(), deviceKey, d)
		ctx = context.WithValue(ctx, cookieAuthKey, viaCookie)
		next(w, r.WithContext(ctx))
	}
}

func deviceOf(r *http.Request) *auth.Device { return r.Context().Value(deviceKey).(*auth.Device) }
