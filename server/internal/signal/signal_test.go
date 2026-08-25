package signal

import (
	"bytes"
	"crypto/x509"
	"io"
	"log/slog"
	"net"
	"strings"
	"testing"
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
	t.Setenv("XDG_CONFIG_HOME", t.TempDir()) // isolate os.UserConfigDir
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
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	old := leafDER(t, []net.IP{net.IPv4(192, 168, 1, 10)})
	// DHCP moved the host: the persisted cert no longer covers the address,
	// which would be a hard (unbypassable) name-mismatch — must regenerate.
	renewed := leafDER(t, []net.IP{net.IPv4(10, 0, 0, 7)})
	if bytes.Equal(old, renewed) {
		t.Fatal("certificate not regenerated for an uncovered LAN IP")
	}
}
