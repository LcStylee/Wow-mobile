package signal

import (
	"bytes"
	"crypto/x509"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestTerminalQREncodesTypicalPairingURL(t *testing.T) {
	url := "https://192.168.178.23:8443/?token=0123456789abcdef0123456789abcdef"
	qr := terminalQR(url)
	if qr == "" {
		t.Fatal("terminalQR failed for a typical pairing URL")
	}
	// Half-block rendering: every emitted rune must be one of the four
	// block states (or newline), otherwise the terminal drawing is broken.
	for _, r := range qr {
		switch r {
		case '█', '▀', '▄', ' ', '\n':
		default:
			t.Fatalf("unexpected rune %q in QR rendering", r)
		}
	}
	if !strings.Contains(qr, "█") {
		t.Fatal("QR rendering contains no dark modules")
	}
}

func TestTerminalQRTooLongIsEmptyNotPanic(t *testing.T) {
	// Byte-mode capacity at level M tops out well below 3 KB.
	if qr := terminalQR(strings.Repeat("x", 4000)); qr != "" {
		t.Fatal("oversized content must yield no QR, not a truncated one")
	}
}

// The PWA is served from the embedded copy by default; --client-dir only
// overrides it when it names an existing directory (development), so the
// binary works no matter where it is started from.
func TestResolveClientFS(t *testing.T) {
	embedded := fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("embedded")}}
	servedIndex := func(fsys fs.FS) string {
		t.Helper()
		data, err := fs.ReadFile(fsys, "index.html")
		if err != nil {
			t.Fatalf("reading index.html: %v", err)
		}
		return string(data)
	}

	if got := servedIndex(resolveClientFS(embedded, "", testLogger())); got != "embedded" {
		t.Fatalf("no flag: expected the embedded FS, got %q", got)
	}
	if got := servedIndex(resolveClientFS(embedded, filepath.Join(t.TempDir(), "missing"), testLogger())); got != "embedded" {
		t.Fatalf("missing --client-dir must fall back to the embedded FS, got %q", got)
	}

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("disk"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := servedIndex(resolveClientFS(embedded, dir, testLogger())); got != "disk" {
		t.Fatalf("--client-dir override not served from disk: %q", got)
	}
}

// isolateCertDir points cert persistence at a per-test directory by swapping
// the userConfigDir seam — never via XDG_CONFIG_HOME, which os.UserConfigDir
// ignores on Windows/macOS, where the test would overwrite the user's real
// persisted tls-cert.pem/tls-key.pem.
func isolateCertDir(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	orig := userConfigDir
	userConfigDir = func() (string, error) { return dir, nil }
	t.Cleanup(func() { userConfigDir = orig })
}

// leafDER extracts the DER of the leaf for identity comparison.
func leafDER(t *testing.T, lanIPs []net.IP) []byte {
	t.Helper()
	cert, err := serverCertificate(lanIPs, testLogger())
	if err != nil {
		t.Fatalf("serverCertificate: %v", err)
	}
	return cert.Certificate[0]
}

func TestServerCertificatePersistsAcrossRestarts(t *testing.T) {
	isolateCertDir(t)
	ips := []net.IP{net.IPv4(192, 168, 1, 10)}

	first := leafDER(t, ips)
	second := leafDER(t, ips)
	if !bytes.Equal(first, second) {
		t.Fatal("certificate changed across restarts — the phone would be re-prompted every run")
	}

	leaf, err := x509.ParseCertificate(first)
	if err != nil {
		t.Fatalf("parsing persisted cert: %v", err)
	}
	for _, want := range append(ips, net.IPv4(127, 0, 0, 1)) {
		found := false
		for _, ip := range leaf.IPAddresses {
			if ip.Equal(want) {
				found = true
			}
		}
		if !found {
			t.Errorf("SAN missing IP %v", want)
		}
	}
}

func TestServerCertificateRegeneratedOnNewLANIP(t *testing.T) {
	isolateCertDir(t)
	old := leafDER(t, []net.IP{net.IPv4(192, 168, 1, 10)})
	// DHCP moved the host: the persisted cert no longer covers the address,
	// which would be a hard (unbypassable) name-mismatch — must regenerate.
	renewed := leafDER(t, []net.IP{net.IPv4(10, 0, 0, 7)})
	if bytes.Equal(old, renewed) {
		t.Fatal("certificate not regenerated for an uncovered LAN IP")
	}
}

// HostURL follows the configured bind: 127.0.0.1 for wildcard binds (which
// include loopback), the bound address itself for explicit loopback binds,
// and "" for a specific non-loopback bind — there the LoopbackOnly-guarded
// dashboard is unreachable and no URL must be advertised (callers warn and
// skip the GUI auto-open instead).
func TestHostURLFollowsBindAddress(t *testing.T) {
	cases := []struct {
		addr  string
		noTLS bool
		want  string
	}{
		{":8443", false, "https://127.0.0.1:8443/host/"},
		{"0.0.0.0:8443", false, "https://127.0.0.1:8443/host/"},
		{"[::]:9000", false, "https://127.0.0.1:9000/host/"},
		{":8443", true, "http://127.0.0.1:8443/host/"},
		{"127.0.0.1:8443", false, "https://127.0.0.1:8443/host/"},
		{"[::1]:8443", false, "https://[::1]:8443/host/"},
		{"localhost:8443", false, "https://localhost:8443/host/"},
		{"garbage", false, "https://127.0.0.1:8443/host/"}, // unparsable: default port, loopback
		// Non-loopback binds: loopback cannot reach the listener at all.
		{"192.168.1.5:8443", false, ""},
		{"[fe80::1]:8443", false, ""},
		{"10.0.0.2:8443", true, ""},
	}
	for _, tc := range cases {
		s := &Server{addr: tc.addr, noTLS: tc.noTLS}
		if got := s.HostURL(); got != tc.want {
			t.Errorf("HostURL(addr=%q noTLS=%v) = %q, want %q", tc.addr, tc.noTLS, got, tc.want)
		}
	}
}
