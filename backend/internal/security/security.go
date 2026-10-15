// Package security holds credential generation/hashing and in-memory abuse limiters.
package security

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"strings"
	"sync"
	"time"
)

// Unambiguous alphabet (no I, L, O, 0, 1): 31 symbols, 8 characters ~ 39.6 bits.
const codeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// NewToken returns a 256-bit random device credential and its SHA-256 hash.
// Only the hash is stored; the token itself is shown to the client once.
func NewToken() (token string, hash []byte) {
	b := make([]byte, 32)
	mustRand(b)
	token = "dmk_" + base64.RawURLEncoding.EncodeToString(b)
	return token, HashToken(token)
}

func HashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// NewPairingCode returns a display code like "ABCD-EFGH". Rejection sampling keeps
// every symbol equally likely (248 = 31*8 is the largest multiple of 31 below 256).
func NewPairingCode() string {
	out := make([]byte, 0, 9)
	buf := make([]byte, 1)
	for len(out) < 9 {
		if len(out) == 4 {
			out = append(out, '-')
			continue
		}
		mustRand(buf)
		if buf[0] < 248 {
			out = append(out, codeAlphabet[int(buf[0])%31])
		}
	}
	return string(out)
}

// NormalizeCode uppercases and strips separators so users can type codes loosely.
func NormalizeCode(s string) string {
	s = strings.ToUpper(s)
	return strings.NewReplacer("-", "", " ", "").Replace(s)
}

// HashCode keys the hash with the server secret so a leaked table cannot be brute-forced offline.
func HashCode(secret, code string) []byte {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(NormalizeCode(code)))
	return m.Sum(nil)
}

// SecretEqual compares secrets in constant time (hashing first hides length differences).
func SecretEqual(a, b string) bool {
	ha, hb := sha256.Sum256([]byte(a)), sha256.Sum256([]byte(b))
	return subtle.ConstantTimeCompare(ha[:], hb[:]) == 1
}

func mustRand(b []byte) {
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
}

// Limiter is a per-key token bucket.
type Limiter struct {
	mu     sync.Mutex
	rate   float64 // tokens per second
	burst  float64
	now    func() time.Time
	bucket map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

func NewLimiter(perSecond float64, burst int) *Limiter {
	return &Limiter{rate: perSecond, burst: float64(burst), now: time.Now, bucket: map[string]*bucket{}}
}

func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.bucket[key]
	if !ok {
		if len(l.bucket) > 10_000 { // bound memory: drop idle (full) buckets
			for k, v := range l.bucket {
				if now.Sub(v.last).Seconds()*l.rate >= l.burst {
					delete(l.bucket, k)
				}
			}
		}
		b = &bucket{tokens: l.burst, last: now}
		l.bucket[key] = b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// FailureGuard locks an action after too many failures in a sliding window.
type FailureGuard struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	now    func() time.Time
	fails  map[string][]time.Time
}

func NewFailureGuard(max int, window time.Duration) *FailureGuard {
	return &FailureGuard{max: max, window: window, now: time.Now, fails: map[string][]time.Time{}}
}

func (g *FailureGuard) prune(key string) []time.Time {
	cut := g.now().Add(-g.window)
	list := g.fails[key]
	i := 0
	for i < len(list) && list[i].Before(cut) {
		i++
	}
	list = list[i:]
	if len(list) == 0 {
		delete(g.fails, key)
	} else {
		g.fails[key] = list
	}
	return list
}

func (g *FailureGuard) Blocked(key string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.prune(key)) >= g.max
}

func (g *FailureGuard) Fail(key string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prune(key)
	g.fails[key] = append(g.fails[key], g.now())
}
