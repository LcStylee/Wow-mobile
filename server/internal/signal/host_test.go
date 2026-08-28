package signal

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
)

// hostTestMux builds a mux with the /host routes enabled, no TLS/listener
// needed.
func hostTestMux(t *testing.T, quit func()) (*http.ServeMux, *hoststatus.Status) {
	t.Helper()
	status := hoststatus.New("v-test", hoststatus.Step{ID: "game", Label: "World of Warcraft"})
	status.SetPairingURL("https://192.168.1.20:8443/?token=deadbeef")
	s := New(":0", "tok", false, fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("<html>dash</html>")}}, "", nil, testLogger())
	s.EnableHostUI(HostUI{
		FS:     fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("<html>dash</html>")}},
		Status: status,
		Quit:   quit,
	})
	mux := http.NewServeMux()
	s.registerHostRoutes(mux)
	return mux, status
}

// do performs a request against the mux with a spoofed RemoteAddr and a
// loopback Host header (LoopbackOnly checks both; httptest.NewRequest's
// default Host of example.com would trip the Host check).
func do(mux *http.ServeMux, method, target, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	req.RemoteAddr = remoteAddr
	req.Host = "127.0.0.1:8443"
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// SECURITY: every /host route must reject non-loopback peers with 403 — the
// dashboard carries the pairing token and must never leak it to the LAN.
func TestHostRoutesAreLoopbackOnly(t *testing.T) {
	mux, _ := hostTestMux(t, nil)
	routes := []struct{ method, path string }{
		{"GET", "/host"},
		{"GET", "/host/"},
		{"GET", "/host/index.html"},
		{"GET", "/host/api/status"},
		{"GET", "/host/qr.svg"},
		{"POST", "/host/api/quit"},
	}
	badPeers := []string{
		"192.168.1.30:51234",    // LAN phone
		"10.0.0.9:1024",         // other private range
		"8.8.8.8:443",           // public
		"[fe80::1%25eth0]:9000", // link-local v6
		"[2001:db8::2]:9000",    // global v6
		"garbage",               // unparsable => fail closed
	}
	for _, rt := range routes {
		for _, peer := range badPeers {
			if rec := do(mux, rt.method, rt.path, peer); rec.Code != http.StatusForbidden {
				t.Errorf("%s %s from %s: got %d, want 403", rt.method, rt.path, peer, rec.Code)
			} else if strings.Contains(rec.Body.String(), "deadbeef") {
				t.Errorf("%s %s from %s: 403 body leaks the token", rt.method, rt.path, peer)
			}
		}
	}

	// Loopback peers (v4 and v6) are served.
	for _, peer := range []string{"127.0.0.1:50000", "[::1]:50000"} {
		if rec := do(mux, "GET", "/host/api/status", peer); rec.Code != http.StatusOK {
			t.Errorf("loopback %s rejected: %d %s", peer, rec.Code, rec.Body.String())
		}
	}
}

// SECURITY: a loopback TCP peer is not enough by itself — under --no-tls a
// DNS-rebinding page (attacker domain re-resolved to 127.0.0.1) would reach
// these routes as a loopback peer but with its own hostname in Host, becoming
// same-origin with the dashboard. Every /host route must therefore also
// reject non-loopback Host headers with 403.
func TestHostRoutesRejectNonLoopbackHost(t *testing.T) {
	mux, _ := hostTestMux(t, nil)
	routes := []struct{ method, path string }{
		{"GET", "/host"},
		{"GET", "/host/"},
		{"GET", "/host/index.html"},
		{"GET", "/host/api/status"},
		{"GET", "/host/qr.svg"},
		{"POST", "/host/api/quit"},
	}
	badHosts := []string{
		"attacker.example",           // classic rebinding hostname
		"attacker.example:8443",      // with port
		"localhost.attacker.example", // prefix trick
		"127.0.0.1.attacker.example", // IP-lookalike trick
		"192.168.1.20:8443",          // the LAN pairing address itself
		"",                           // missing: fail closed
	}
	for _, rt := range routes {
		for _, h := range badHosts {
			req := httptest.NewRequest(rt.method, rt.path, nil)
			req.RemoteAddr = "127.0.0.1:50000" // rebinding: peer IS loopback
			req.Host = h
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, req)
			if rec.Code != http.StatusForbidden {
				t.Errorf("%s %s with Host %q: got %d, want 403", rt.method, rt.path, h, rec.Code)
			} else if strings.Contains(rec.Body.String(), "deadbeef") {
				t.Errorf("%s %s with Host %q: 403 body leaks the token", rt.method, rt.path, h)
			}
		}
	}

	// Every legitimate way of naming this machine's loopback is served.
	goodHosts := []string{
		"127.0.0.1", "127.0.0.1:8443", "localhost", "LocalHost:8443",
		"[::1]", "[::1]:8443",
	}
	for _, h := range goodHosts {
		req := httptest.NewRequest("GET", "/host/api/status", nil)
		req.RemoteAddr = "127.0.0.1:50000"
		req.Host = h
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Errorf("loopback Host %q rejected: %d %s", h, rec.Code, rec.Body.String())
		}
	}
}

// The dashboard page itself must not require the pairing token — the status
// endpoint (loopback-only) is what carries it.
func TestHostPageServedWithoutToken(t *testing.T) {
	mux, _ := hostTestMux(t, nil)
	rec := do(mux, "GET", "/host/", "127.0.0.1:9999")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "dash") {
		t.Fatalf("dashboard page not served: %d %q", rec.Code, rec.Body.String())
	}
	if rec := do(mux, "GET", "/host", "127.0.0.1:9999"); rec.Code != http.StatusMovedPermanently {
		t.Fatalf("/host must redirect to /host/: %d", rec.Code)
	}
}

// Status JSON is served with the contract shape the page polls.
func TestHostStatusJSON(t *testing.T) {
	mux, status := hostTestMux(t, nil)
	status.SetStep("game", hoststatus.StateOK, "found")
	status.SetEncoder("h264_nvenc")
	rec := do(mux, "GET", "/host/api/status", "127.0.0.1:9999")
	if rec.Code != http.StatusOK {
		t.Fatalf("status: %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("content type: %q", ct)
	}
	var got struct {
		Version string `json:"version"`
		Steps   []struct {
			ID    string `json:"id"`
			State string `json:"state"`
		} `json:"steps"`
		Encoder    string `json:"encoder"`
		PairingURL string `json:"pairingUrl"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("status JSON: %v\n%s", err, rec.Body.String())
	}
	if got.Version != "v-test" || got.Encoder != "h264_nvenc" ||
		len(got.Steps) != 1 || got.Steps[0].ID != "game" || got.Steps[0].State != "ok" ||
		!strings.Contains(got.PairingURL, "token=") {
		t.Fatalf("status content wrong: %+v", got)
	}
}

// POST /host/api/quit triggers the graceful-shutdown callback exactly like
// Ctrl+C — but only with the dashboard's CSRF header: a same-machine browser
// is a loopback peer, so a cross-origin no-cors POST (which cannot carry a
// custom header) must not be able to kill the stream.
func TestHostQuit(t *testing.T) {
	quitCh := make(chan struct{}, 1)
	mux, _ := hostTestMux(t, func() { quitCh <- struct{}{} })

	// SECURITY: without the header (what a drive-by cross-origin request can
	// send at most), quit is refused even from loopback.
	if rec := do(mux, "POST", "/host/api/quit", "127.0.0.1:9999"); rec.Code != http.StatusForbidden {
		t.Fatalf("headerless quit not rejected: %d", rec.Code)
	}
	select {
	case <-quitCh:
		t.Fatal("headerless quit invoked the shutdown callback")
	default:
	}

	req := httptest.NewRequest("POST", "/host/api/quit", nil)
	req.RemoteAddr = "127.0.0.1:9999"
	req.Host = "127.0.0.1:8443"
	req.Header.Set("X-Wowmobile-Quit", "1")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("quit: %d", rec.Code)
	}
	select {
	case <-quitCh:
	case <-time.After(5 * time.Second):
		t.Fatal("quit callback not invoked")
	}
	// And never from the LAN, header or not.
	req = httptest.NewRequest("POST", "/host/api/quit", nil)
	req.RemoteAddr = "192.168.1.30:1"
	req.Host = "127.0.0.1:8443"
	req.Header.Set("X-Wowmobile-Quit", "1")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("LAN quit not rejected: %d", rec.Code)
	}
}

// svgDoc is the minimal structure needed to validate the QR SVG.
type svgDoc struct {
	XMLName xml.Name `xml:"svg"`
	ViewBox string   `xml:"viewBox,attr"`
	Rects   []struct {
		Fill string `xml:"fill,attr"`
	} `xml:"rect"`
	G struct {
		Rects []struct {
			X string `xml:"x,attr"`
			Y string `xml:"y,attr"`
		} `xml:"rect"`
	} `xml:"g"`
}

// The SVG emitter must be valid XML and draw exactly the same module matrix
// the ASCII banner path renders (same library, same content => same bitmap).
func TestQRSVGMatchesModuleMatrix(t *testing.T) {
	const url = "https://192.168.1.20:8443/?token=0123456789abcdef0123456789abcdef"
	svg, err := qrSVG(url)
	if err != nil {
		t.Fatalf("qrSVG: %v", err)
	}
	var doc svgDoc
	if err := xml.Unmarshal(svg, &doc); err != nil {
		t.Fatalf("emitted SVG is not valid XML: %v\n%s", err, svg)
	}

	modules, err := qrModules(url)
	if err != nil {
		t.Fatalf("qrModules: %v", err)
	}
	dark := 0
	for _, row := range modules {
		for _, d := range row {
			if d {
				dark++
			}
		}
	}
	if dark == 0 {
		t.Fatal("module matrix has no dark modules")
	}
	if got := len(doc.G.Rects); got != dark {
		t.Fatalf("SVG draws %d modules, matrix has %d dark modules", got, dark)
	}
	if want := len(modules); doc.ViewBox != fmt.Sprintf("0 0 %d %d", want, want) {
		t.Fatalf("viewBox %q does not match matrix size %d", doc.ViewBox, want)
	}

	// The ASCII path renders the same matrix; it must agree it is scannable
	// (non-empty) for the same content.
	if terminalQR(url) == "" {
		t.Fatal("ASCII QR path failed for the same content")
	}
}

func TestQRSVGTooLongErrorsNotPanics(t *testing.T) {
	if _, err := qrSVG(strings.Repeat("x", 4000)); err == nil {
		t.Fatal("oversized content must error")
	}
}
