package rtc

import (
	"io"
	"log/slog"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}

// gatheredSDP returns the local SDP of a fresh offer once ICE gathering is
// complete — the candidates a phone would be given.
func gatheredSDP(t *testing.T, m *Manager) string {
	t.Helper()
	pc, err := m.newPeerConnection()
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	if _, err := pc.CreateDataChannel("probe", nil); err != nil {
		t.Fatal(err)
	}
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	done := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("ICE gathering did not complete")
	}
	return pc.LocalDescription().SDP
}

func candidates(sdp string) []string {
	var out []string
	for _, l := range strings.Split(sdp, "\n") {
		if strings.HasPrefix(l, "a=candidate:") {
			out = append(out, strings.TrimSpace(l))
		}
	}
	return out
}

func TestRemotePlayCandidates(t *testing.T) {
	port := freeUDPPort(t)
	m, err := NewManager(Options{FPS: 60, ICEUDPPort: port, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	if m.udpMux == nil {
		t.Fatal("fixed UDP port not opened")
	}
	p := " " + strconv.Itoa(port) + " typ host"

	// LAN only: every UDP candidate is on the one forwarded port.
	lan := candidates(gatheredSDP(t, m))
	if len(lan) == 0 {
		t.Skip("no network interfaces with an address in this environment")
	}
	for _, c := range lan {
		if strings.Contains(c, " udp ") && !strings.Contains(c, p) {
			t.Fatalf("UDP candidate off the fixed port: %s", c)
		}
	}

	// Remote play: the public address is offered too, same port, and the
	// LAN candidates stay (a phone at home still pairs directly).
	const public = "203.0.113.7"
	if err := m.SetPublicIP(public); err != nil {
		t.Fatal(err)
	}
	remote := candidates(gatheredSDP(t, m))
	var sawPublic bool
	for _, c := range remote {
		if strings.Contains(c, " "+public+p) {
			sawPublic = true
		}
	}
	t.Logf("remote candidates:\n%s", strings.Join(remote, "\n"))
	if !sawPublic {
		t.Fatalf("public address not offered on port %d:\n%s", port, strings.Join(remote, "\n"))
	}
	if len(remote) <= len(lan)-1 {
		t.Fatalf("LAN candidates dropped: %d before, %d after", len(lan), len(remote))
	}

	// Turning it off again stops advertising it.
	if err := m.SetPublicIP(""); err != nil {
		t.Fatal(err)
	}
	for _, c := range candidates(gatheredSDP(t, m)) {
		if strings.Contains(c, public) {
			t.Fatalf("public address still offered after SetPublicIP(\"\"): %s", c)
		}
	}
}

func TestSetPublicIPNeedsFixedPort(t *testing.T) {
	m, err := NewManager(Options{FPS: 60, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.SetPublicIP("203.0.113.7"); err == nil {
		t.Fatal("public address accepted without the fixed UDP port")
	}
}
