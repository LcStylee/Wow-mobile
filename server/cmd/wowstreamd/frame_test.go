package main

import (
	"strings"
	"testing"

	"github.com/LcStylee/Wow-mobile/server/internal/phones"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

func TestFrameResolverLadder(t *testing.T) {
	var probeRect window.Rect
	probeOK := false
	var persisted string
	fr := newFrameResolver("", func() (window.Rect, bool) { return probeRect, probeOK }, func(id string) { persisted = id })

	// No outline, nothing picked: the default phone.
	d, ok := fr.Resolve(1920, 1080)
	def := phones.Default()
	want, _ := window.ComputePhoneFrame(1920, 1080, def.StreamW, def.StreamH)
	if !ok || d.source != window.SourceDefault || d.frame.Band != want.Band {
		t.Fatalf("default: %+v ok=%v", d, ok)
	}
	// The outline wins over everything.
	probeRect, probeOK = window.Rect{X: 700, Y: 10, W: 500, H: 1000}, true
	d, _ = fr.Resolve(1920, 1080)
	if d.source != window.SourceOutline || d.frame.Band != probeRect {
		t.Fatalf("outline: %+v", d)
	}
	if got, ok := fr.Crop(1920, 1080); !ok || got != probeRect {
		t.Fatalf("input crop must equal the capture crop: %+v", got)
	}
	// Outline hidden (loading screen): the last detection holds at the same size.
	probeOK = false
	d, _ = fr.Resolve(1920, 1080)
	if d.source != window.SourceLast || d.frame.Band != probeRect {
		t.Fatalf("last: %+v", d)
	}
	// ...but not at a different client size: dashboard phone then.
	if err := fr.SetPhone("galaxy-a07"); err != nil || persisted != "galaxy-a07" {
		t.Fatalf("SetPhone: %v persisted=%q", err, persisted)
	}
	d, _ = fr.Resolve(2560, 1440)
	if d.source != window.SourceDashboard || d.phone.ID != "galaxy-a07" {
		t.Fatalf("dashboard: %+v", d)
	}
	// An outline outside the client area is ignored.
	probeRect, probeOK = window.Rect{X: 2000, Y: 0, W: 900, H: 1400}, true
	d, _ = fr.Resolve(2560, 1440)
	if d.source != window.SourceDashboard {
		t.Fatalf("out-of-bounds outline accepted: %+v", d)
	}
	if err := fr.SetPhone("nokia-3310"); err == nil {
		t.Fatal("unknown phone accepted")
	}
}

func TestFrameResolverDriftDebounced(t *testing.T) {
	probeOK := false
	probeRect := window.Rect{X: 700, Y: 10, W: 500, H: 1000}
	fr := newFrameResolver("iphone-17", func() (window.Rect, bool) { return probeRect, probeOK }, nil)
	if _, ok := fr.Resolve(1920, 1080); !ok {
		t.Fatal("resolve")
	}
	if _, drift := fr.Drift(1920, 1080); drift {
		t.Fatal("no change must not drift")
	}
	probeOK = true // the user logged in: the outline appears
	if _, drift := fr.Drift(1920, 1080); drift {
		t.Fatal("first sighting must be debounced")
	}
	reason, drift := fr.Drift(1920, 1080)
	if !drift || !strings.Contains(reason, "addon outline") {
		t.Fatalf("second sighting must drift: %q %v", reason, drift)
	}
	fr.Resolve(1920, 1080) // the relaunch
	if _, drift := fr.Drift(1920, 1080); drift {
		t.Fatal("settled frame must not drift")
	}
	// A different client size is the watchdog's rect check, not a drift.
	if _, drift := fr.Drift(1280, 720); drift {
		t.Fatal("size change reported as frame drift")
	}
}
