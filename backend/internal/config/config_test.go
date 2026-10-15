package config

import (
	"strings"
	"testing"
)

func load(m map[string]string) (Config, error) { return Load(func(k string) string { return m[k] }) }

const goodSecret = "0123456789abcdef0123456789abcdef"

func TestLoadDefaultsAreSecure(t *testing.T) {
	c, err := load(map[string]string{"DATABASE_URL": "postgres://x", "DAYMARK_SETUP_SECRET": goodSecret})
	if err != nil {
		t.Fatal(err)
	}
	if !c.Production() || c.CookieSameSite != "none" || c.Addr != ":8080" || c.TrustProxyHops != 0 {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestLoadRejectsInsecureConfig(t *testing.T) {
	base := func() map[string]string {
		return map[string]string{"DATABASE_URL": "postgres://x", "DAYMARK_SETUP_SECRET": goodSecret}
	}
	cases := map[string]func(map[string]string){
		"missing database": func(m map[string]string) { delete(m, "DATABASE_URL") },
		"missing secret":   func(m map[string]string) { delete(m, "DAYMARK_SETUP_SECRET") },
		"short secret":     func(m map[string]string) { m["DAYMARK_SETUP_SECRET"] = "changeme" },
		"wildcard origin":  func(m map[string]string) { m["ALLOWED_ORIGINS"] = "*" },
		"http in prod":     func(m map[string]string) { m["ALLOWED_ORIGINS"] = "http://example.com" },
		"bad env":          func(m map[string]string) { m["DAYMARK_ENV"] = "staging" },
		"bad samesite":     func(m map[string]string) { m["COOKIE_SAMESITE"] = "whatever" },
	}
	for name, mutate := range cases {
		m := base()
		mutate(m)
		if _, err := load(m); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestLoadParsing(t *testing.T) {
	c, err := load(map[string]string{
		"DATABASE_URL": "postgres://x", "DAYMARK_SETUP_SECRET": goodSecret, "PORT": "10000",
		"ALLOWED_ORIGINS": "https://a.example/, https://b.example", "DAYMARK_ENV": "development",
		"ALLOWED_ORIGINS_X": "ignored", "DEVICE_TTL": "48h", "TRUST_PROXY_HOPS": "1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":10000" || strings.Join(c.AllowedOrigins, ",") != "https://a.example,https://b.example" ||
		c.DeviceTTL.Hours() != 48 || c.TrustProxyHops != 1 || c.CookieSameSite != "lax" {
		t.Fatalf("%+v", c)
	}
	if _, err := load(map[string]string{"DATABASE_URL": "x", "DAYMARK_SETUP_SECRET": goodSecret,
		"DAYMARK_ENV": "development", "ALLOWED_ORIGINS": "http://localhost:8080"}); err != nil {
		t.Fatalf("http origin should be allowed in development: %v", err)
	}
}
