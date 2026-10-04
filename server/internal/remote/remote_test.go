package remote

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"testing"
	"time"
)

func TestDecide(t *testing.T) {
	const lan = "192.168.1.20"
	cases := []struct {
		name               string
		haveGW             bool
		mapErr             error
		upnp, stun         string
		wantState, wantPub string
	}{
		{"router opens, addresses agree", true, nil, "203.0.113.7", "203.0.113.7", StateOpen, "203.0.113.7"},
		{"router opens, STUN silent", true, nil, "203.0.113.7", "", StateOpen, "203.0.113.7"},
		{"provider CGNAT (router WAN 100.64/10)", true, nil, "100.72.1.9", "198.51.100.4", StateCGNAT, ""},
		{"double NAT (router WAN private)", true, nil, "192.168.0.2", "198.51.100.4", StateCGNAT, ""},
		{"second NAT in front (addresses differ)", true, nil, "203.0.113.7", "198.51.100.4", StateCGNAT, ""},
		{"router refuses mapping", true, errors.New("refused"), "203.0.113.7", "203.0.113.7", StateManual, "203.0.113.7"},
		{"no UPnP router", false, nil, "", "203.0.113.7", StateManual, "203.0.113.7"},
		{"offline", false, nil, "", "", StateFailed, ""},
	}
	for _, c := range cases {
		r := decide(c.haveGW, c.mapErr, c.upnp, c.stun, lan, 8443, 8443)
		if r.state != c.wantState || r.publicIP != c.wantPub {
			t.Errorf("%s: got %s/%q, want %s/%q", c.name, r.state, r.publicIP, c.wantState, c.wantPub)
		}
		if r.message == "" {
			t.Errorf("%s: empty message", c.name)
		}
	}
}

func TestIsShared(t *testing.T) {
	for ip, want := range map[string]bool{
		"10.0.0.1": true, "192.168.1.1": true, "172.16.5.5": true, "100.64.0.1": true,
		"100.127.255.254": true, "127.0.0.1": true, "203.0.113.7": false, "8.8.8.8": false,
	} {
		if got := isShared(net.ParseIP(ip)); got != want {
			t.Errorf("isShared(%s) = %v", ip, got)
		}
	}
}

type fakeGW struct {
	mu      sync.Mutex
	mapped  map[string]bool
	deleted map[string]bool
}

func (g *fakeGW) AddPortMappingCtx(_ context.Context, _ string, _ uint16, proto string, _ uint16, _ string, _ bool, _ string, _ uint32) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.mapped[proto] = true
	return nil
}
func (g *fakeGW) DeletePortMappingCtx(_ context.Context, _ string, _ uint16, proto string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.deleted[proto] = true
	return nil
}
func (g *fakeGW) GetExternalIPAddressCtx(context.Context) (string, error) { return "203.0.113.7", nil }
func (g *fakeGW) LocalAddr() net.IP                                       { return net.ParseIP("192.168.1.20") }

func TestControllerLifecycle(t *testing.T) {
	gw := &fakeGW{mapped: map[string]bool{}, deleted: map[string]bool{}}
	var mu sync.Mutex
	var advertised []string
	c := New(8443, 8443, slog.New(slog.NewTextHandler(io.Discard, nil)), func(ip string) error {
		mu.Lock()
		advertised = append(advertised, ip)
		mu.Unlock()
		return nil
	})
	c.discover = func(context.Context) (gateway, error) { return gw, nil }
	c.stunIP = func(context.Context) (string, error) { return "203.0.113.7", nil }

	c.SetEnabled(true)
	deadline := time.Now().Add(3 * time.Second)
	for c.Status().State != StateOpen {
		if time.Now().After(deadline) {
			t.Fatalf("never opened: %+v", c.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
	s := c.Status()
	if s.PublicIP != "203.0.113.7" || s.LANIP != "192.168.1.20" || !s.Enabled {
		t.Fatalf("status: %+v", s)
	}
	if !gw.mapped["TCP"] || !gw.mapped["UDP"] {
		t.Fatalf("mapped: %v", gw.mapped)
	}

	c.SetEnabled(false)
	if c.Status().State != StateOff {
		t.Fatalf("not off: %+v", c.Status())
	}
	if !gw.deleted["TCP"] || !gw.deleted["UDP"] {
		t.Fatalf("router ports not closed: %v", gw.deleted)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(advertised) != 2 || advertised[0] != "203.0.113.7" || advertised[1] != "" {
		t.Fatalf("advertised: %q", advertised)
	}
}
