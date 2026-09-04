package wininput

import (
	"testing"

	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// mid is the normalized coordinate closest to the exact center (65535/2).
const mid = 32768

func TestMapNormalizedCorners(t *testing.T) {
	target := window.Rect{X: 10, Y: 20, W: 640, H: 480}
	if px, py := MapNormalized(0, 0, target); px != 10 || py != 20 {
		t.Errorf("origin -> (%d,%d), want (10,20)", px, py)
	}
	if px, py := MapNormalized(65535, 65535, target); px != 10+639 || py != 20+479 {
		t.Errorf("max -> (%d,%d), want (649,499)", px, py)
	}
}

// Band layout, landscape window: normalized coordinates land INSIDE the
// centered band, offset by bandX — never on the letterbox margins the phone
// does not see.
func TestTargetRectBandLandscape(t *testing.T) {
	client := window.Rect{X: 100, Y: 50, W: 1280, H: 720}
	target := TargetRect(client, true)
	// Contract: band 405x720 at client-local X=438.
	want := window.Rect{X: 100 + 438, Y: 50, W: 405, H: 720}
	if target != want {
		t.Fatalf("TargetRect = %+v, want %+v", target, want)
	}
	// Normalized x=0 hits the band's left edge, x=65535 its right edge.
	if px, _ := MapNormalized(0, 0, target); px != 538 {
		t.Errorf("left edge -> %d, want 538", px)
	}
	if px, _ := MapNormalized(65535, 0, target); px != 538+404 {
		t.Errorf("right edge -> %d, want %d", px, 538+404)
	}
}

// Crop/scale chain consistency: a tap at the phone's center must land at the
// window's CENTER COLUMN — the same pixels the capture crop put at the center
// of the encoded frame — for landscape windows of every parity, including the
// scaled 4K band. This is the invariant that keeps touch aligned with video
// through the whole crop -> scale -> hello -> normalize -> inject chain.
func TestBandCenterTapHitsWindowCenterColumn(t *testing.T) {
	for _, size := range [][2]int{
		{1280, 720}, {1281, 719}, {1920, 1080}, {1919, 1080},
		{2560, 1440}, {3840, 2160}, {1367, 767}, {901, 507},
	} {
		w, h := size[0], size[1]
		client := window.Rect{W: w, H: h}
		target := TargetRect(client, true)
		px, py := MapNormalized(mid, mid, target)
		// Window center column (0-based pixel indices 0..w-1): (w-1)/2 ± 1 px
		// of rounding slack across band centering + pixel-index mapping.
		center2 := w - 1 // center * 2
		if diff := 2*px - center2; diff < -3 || diff > 3 {
			t.Errorf("%dx%d: center tap -> column %d, window center %g", w, h, px, float64(center2)/2)
		}
		if diff := 2*py - (h - 1); diff < -3 || diff > 3 {
			t.Errorf("%dx%d: center tap -> row %d, window center %g", w, h, py, float64(h-1)/2)
		}
	}
}

// Band-vs-portrait mode switch: the same window rect maps full-window when
// band layout is off, and a PORTRAIT window maps full-window even when band
// layout is on (the contract's full-window fallback).
func TestTargetRectModeSwitch(t *testing.T) {
	landscape := window.Rect{X: 5, Y: 7, W: 1280, H: 720}
	if got := TargetRect(landscape, false); got != landscape {
		t.Errorf("portrait layout must map the full window: %+v", got)
	}
	portrait := window.Rect{X: 5, Y: 7, W: 552, H: 984}
	if got := TargetRect(portrait, true); got != portrait {
		t.Errorf("portrait window under band layout must map the full window: %+v", got)
	}
	// A degenerate rect never panics and falls back to the client rect.
	tiny := window.Rect{W: 4, H: 2}
	if got := TargetRect(tiny, true); got != tiny {
		t.Errorf("degenerate rect must fall back to itself: %+v", got)
	}
}

// Odd band width (405 wide): every normalized value must stay inside the
// band, monotonically.
func TestMapNormalizedOddWidthBounds(t *testing.T) {
	target := TargetRect(window.Rect{W: 1280, H: 720}, true)
	last := -1
	for _, nx := range []uint16{0, 1, 100, 16383, 32768, 49151, 65534, 65535} {
		px, _ := MapNormalized(nx, 0, target)
		if px < target.X || px > target.X+target.W-1 {
			t.Fatalf("nx=%d -> %d outside band [%d,%d]", nx, px, target.X, target.X+target.W-1)
		}
		if px < last {
			t.Fatalf("mapping not monotonic at nx=%d", nx)
		}
		last = px
	}
}
