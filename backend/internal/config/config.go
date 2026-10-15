// Package config loads environment-based configuration and refuses insecure values.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Env             string // "production" or "development"
	Addr            string
	DatabaseURL     string
	SetupSecret     string
	AllowedOrigins  []string
	TrustProxyHops  int // number of reverse proxies in front (Render = 1); 0 = trust none
	CookieSameSite  string
	DeviceTTL       time.Duration // device/session expires after this much inactivity
	PairingCodeTTL  time.Duration
	BackupInterval  time.Duration // 0 disables scheduled backups
	BackupRetention int
	MigrateOnStart  bool
	MaxBodyBytes    int64
	MaxRestoreBytes int64
	DBMaxOpenConns  int
}

func (c Config) Production() bool { return c.Env == "production" }

// Load reads configuration from the environment via the given lookup function.
func Load(get func(string) string) (Config, error) {
	c := Config{
		Env:             def(get("DAYMARK_ENV"), "production"),
		DatabaseURL:     get("DATABASE_URL"),
		SetupSecret:     get("DAYMARK_SETUP_SECRET"),
		DeviceTTL:       dur(get("DEVICE_TTL"), 180*24*time.Hour),
		PairingCodeTTL:  dur(get("PAIRING_CODE_TTL"), 10*time.Minute),
		BackupInterval:  dur(get("BACKUP_INTERVAL"), 24*time.Hour),
		BackupRetention: num(get("BACKUP_RETENTION"), 14),
		MigrateOnStart:  def(get("MIGRATE_ON_START"), "true") == "true",
		MaxBodyBytes:    int64(num(get("MAX_BODY_BYTES"), 1<<20)),
		MaxRestoreBytes: int64(num(get("MAX_RESTORE_BYTES"), 32<<20)),
		DBMaxOpenConns:  num(get("DB_MAX_OPEN_CONNS"), 10),
		TrustProxyHops:  num(get("TRUST_PROXY_HOPS"), 0),
	}
	port := get("PORT")
	switch {
	case get("ADDR") != "":
		c.Addr = get("ADDR")
	case port != "":
		c.Addr = ":" + port
	default:
		c.Addr = ":8080"
	}
	for _, o := range strings.Split(get("ALLOWED_ORIGINS"), ",") {
		if o = strings.TrimRight(strings.TrimSpace(o), "/"); o != "" {
			c.AllowedOrigins = append(c.AllowedOrigins, o)
		}
	}
	c.CookieSameSite = strings.ToLower(def(get("COOKIE_SAMESITE"), map[bool]string{true: "none", false: "lax"}[c.Production()]))

	var errs []error
	if c.Env != "production" && c.Env != "development" {
		errs = append(errs, errors.New("DAYMARK_ENV must be production or development"))
	}
	if c.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL is required"))
	}
	if len(c.SetupSecret) < 24 {
		errs = append(errs, errors.New("DAYMARK_SETUP_SECRET is required and must be at least 24 characters"))
	}
	for _, o := range c.AllowedOrigins {
		if o == "*" || !(strings.HasPrefix(o, "https://") || (!c.Production() && strings.HasPrefix(o, "http://"))) {
			errs = append(errs, fmt.Errorf("ALLOWED_ORIGINS entry %q must be an exact https origin (http allowed only in development; no wildcard)", o))
		}
	}
	if c.CookieSameSite != "none" && c.CookieSameSite != "lax" && c.CookieSameSite != "strict" {
		errs = append(errs, errors.New("COOKIE_SAMESITE must be none, lax or strict"))
	}
	if c.BackupRetention < 1 {
		errs = append(errs, errors.New("BACKUP_RETENTION must be >= 1"))
	}
	return c, errors.Join(errs...)
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func num(v string, d int) int {
	if n, err := strconv.Atoi(v); err == nil {
		return n
	}
	return d
}

func dur(v string, d time.Duration) time.Duration {
	if v == "" {
		return d
	}
	if x, err := time.ParseDuration(v); err == nil {
		return x
	}
	return d
}

// FromOS loads configuration from the process environment.
func FromOS() (Config, error) { return Load(os.Getenv) }
