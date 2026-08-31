package signal

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestStampVersion(t *testing.T) {
	in := []byte("const VERSION = '__WM_VERSION__';\nconst CACHE = 'shell-' + VERSION;")
	out := string(stampVersion(in, "v1.2.3"))
	if !strings.Contains(out, "const VERSION = 'v1.2.3';") {
		t.Fatalf("placeholder not stamped: %q", out)
	}
	if strings.Contains(out, "__WM_VERSION__") {
		t.Fatalf("placeholder leaked: %q", out)
	}
	// A hostile/odd version cannot break out of the JS string literal.
	out = string(stampVersion(in, "v1';alert(1)//\\\n"))
	if strings.Contains(out, "'v1';") || strings.Contains(out, "\\") {
		t.Fatalf("unsafe characters survived stamping: %q", out)
	}
	// No placeholder: bytes pass through untouched.
	plain := []byte("const VERSION = 'hardcoded';")
	if got := string(stampVersion(plain, "v9")); got != string(plain) {
		t.Fatalf("stamping mutated a placeholder-free file: %q", got)
	}
}

// The served sw.js / js/version.js carry the SERVER version, so every release
// busts the cached PWA shell automatically and the phone can display what it
// runs. no-cache (revalidate) — a service worker must always see updates.
func TestHandleStampedServesVersionedShell(t *testing.T) {
	client := fstest.MapFS{
		"sw.js":         &fstest.MapFile{Data: []byte("const CACHE = 'wowmobile-shell-' + '__WM_VERSION__';")},
		"js/version.js": &fstest.MapFile{Data: []byte("export const CLIENT_VERSION = '__WM_VERSION__';")},
	}
	s := New(":0", "tok", true, client, "", "v7.7.7", nil, testLogger())
	for _, name := range []string{"sw.js", "js/version.js"} {
		rec := httptest.NewRecorder()
		s.handleStamped(name)(rec, httptest.NewRequest(http.MethodGet, "/"+name, nil))
		res := rec.Result()
		body, _ := io.ReadAll(res.Body)
		if res.StatusCode != http.StatusOK {
			t.Fatalf("%s: status %d", name, res.StatusCode)
		}
		if !strings.Contains(string(body), "v7.7.7") || strings.Contains(string(body), "__WM_VERSION__") {
			t.Errorf("%s not stamped: %q", name, body)
		}
		if cc := res.Header.Get("Cache-Control"); cc != "no-cache" {
			t.Errorf("%s: Cache-Control = %q, want no-cache", name, cc)
		}
		if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/javascript") {
			t.Errorf("%s: Content-Type = %q", name, ct)
		}
	}
}
