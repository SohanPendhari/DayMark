package security

import (
	"strings"
	"testing"
	"time"
)

func TestPairingCodeFormatAndUniqueness(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 2000; i++ {
		c := NewPairingCode()
		if len(c) != 9 || c[4] != '-' {
			t.Fatalf("bad format %q", c)
		}
		for _, r := range strings.ReplaceAll(c, "-", "") {
			if !strings.ContainsRune(codeAlphabet, r) {
				t.Fatalf("symbol %q outside alphabet", r)
			}
		}
		if seen[c] {
			t.Fatalf("duplicate code %q in 2000 draws", c)
		}
		seen[c] = true
	}
	for _, bad := range "ILO01" {
		if strings.ContainsRune(codeAlphabet, bad) {
			t.Fatalf("ambiguous symbol %q in alphabet", bad)
		}
	}
}

func TestCodeHashing(t *testing.T) {
	if string(HashCode("k", "abcd-efgh")) != string(HashCode("k", " ABCD EFGH ")) {
		t.Fatal("normalization should make loosely typed codes equal")
	}
	if string(HashCode("k1", "ABCD-EFGH")) == string(HashCode("k2", "ABCD-EFGH")) {
		t.Fatal("hash must depend on the server secret")
	}
}

func TestTokens(t *testing.T) {
	a, ha := NewToken()
	b, _ := NewToken()
	if a == b || !strings.HasPrefix(a, "dmk_") || len(a) < 40 {
		t.Fatalf("weak tokens %q %q", a, b)
	}
	if string(HashToken(a)) != string(ha) {
		t.Fatal("hash mismatch")
	}
	if strings.Contains(string(ha), a) {
		t.Fatal("hash must not contain token")
	}
}

func TestSecretEqual(t *testing.T) {
	if !SecretEqual("abc", "abc") || SecretEqual("abc", "abd") || SecretEqual("abc", "abcd") || SecretEqual("", "x") {
		t.Fatal("SecretEqual wrong")
	}
}

func TestLimiterRefills(t *testing.T) {
	now := time.Unix(1000, 0)
	l := NewLimiter(1, 3)
	l.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if !l.Allow("a") {
			t.Fatal("burst should be allowed")
		}
	}
	if l.Allow("a") {
		t.Fatal("burst exhausted")
	}
	if !l.Allow("b") {
		t.Fatal("keys are independent")
	}
	now = now.Add(2 * time.Second)
	if !l.Allow("a") || !l.Allow("a") || l.Allow("a") {
		t.Fatal("expected exactly 2 tokens after 2s")
	}
}

func TestFailureGuardWindow(t *testing.T) {
	now := time.Unix(1000, 0)
	g := NewFailureGuard(3, time.Minute)
	g.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if g.Blocked("k") {
			t.Fatal("blocked too early")
		}
		g.Fail("k")
	}
	if !g.Blocked("k") || g.Blocked("other") {
		t.Fatal("lockout wrong")
	}
	now = now.Add(2 * time.Minute)
	if g.Blocked("k") {
		t.Fatal("lockout should expire")
	}
}
