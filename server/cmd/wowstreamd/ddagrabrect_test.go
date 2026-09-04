package main

import (
	"strings"
	"testing"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// The zero-copy ddagrab crop arithmetic (client rect + band sub-rect ->
// screen rect, stale-band bounds guard, no-scaler size invariant,
// output-local translation) is the one real crop-coordinate math on the
// capture side; the live shell around it (ddagrabTarget) needs a Win32
// Tracker and DXGI, so THESE tests are what pins the arithmetic.
func TestDdagrabScreenRect(t *testing.T) {
	cases := []struct {
		name       string
		rc         window.Rect
		encW, encH int
		sub        *capture.Rect
		want       window.Rect // meaningful only when wantReason == ""
		wantReason string      // substring of the expected gdigrab-fallback reason
	}{
		// Portrait full-window mode: no sub-rect, the client rect passes
		// through verbatim (screen origin included).
		{
			name: "full-window verbatim",
			rc:   window.Rect{X: 684, Y: 48, W: 552, H: 984},
			encW: 552, encH: 984,
			want: window.Rect{X: 684, Y: 48, W: 552, H: 984},
		},
		// Full-window with an odd-sized client: the even-floored encode
		// differs, so the no-scaler invariant forces gdigrab.
		{
			name: "full-window odd size mismatch",
			rc:   window.Rect{X: 0, Y: 0, W: 553, H: 985},
			encW: 552, encH: 984,
			wantReason: "capture rect 553x985 differs from the 552x984 encode size",
		},
		// Band mode, borderless 1920x1080 desktop window at the screen
		// origin: the 608x1080 band (contract vector) folds to screen x=656.
		{
			name: "band fold at origin",
			rc:   window.Rect{X: 0, Y: 0, W: 1920, H: 1080},
			encW: 608, encH: 1080,
			sub:  &capture.Rect{X: 656, Y: 0, W: 608, H: 1080},
			want: window.Rect{X: 656, Y: 0, W: 608, H: 1080},
		},
		// The same band in a decorated window whose CLIENT AREA sits at
		// screen (100,50): the band offset adds to the client-area screen
		// origin — ClientToScreen already excluded decorations, so no chrome
		// term appears anywhere.
		{
			name: "band fold with client screen origin",
			rc:   window.Rect{X: 100, Y: 50, W: 1920, H: 1080},
			encW: 608, encH: 1080,
			sub:  &capture.Rect{X: 656, Y: 0, W: 608, H: 1080},
			want: window.Rect{X: 756, Y: 50, W: 608, H: 1080},
		},
		// A window on a secondary monitor LEFT of the primary: negative
		// screen coordinates fold like any others.
		{
			name: "band fold on negative-origin monitor",
			rc:   window.Rect{X: -2560, Y: 0, W: 1920, H: 1080},
			encW: 608, encH: 1080,
			sub:  &capture.Rect{X: 656, Y: 0, W: 608, H: 1080},
			want: window.Rect{X: -1904, Y: 0, W: 608, H: 1080},
		},
		// Stale band: the window shrank between main's frame decision and
		// this launch — the crop no longer fits and must not frame desktop
		// pixels right of the window.
		{
			name: "stale band out of bounds",
			rc:   window.Rect{X: 0, Y: 0, W: 1280, H: 720},
			encW: 608, encH: 1080,
			sub:        &capture.Rect{X: 656, Y: 0, W: 608, H: 1080},
			wantReason: "band crop 608x1080 at (656,0) no longer fits the 1280x720 client area",
		},
		// A negative sub-rect origin is out of the client area by definition.
		{
			name: "negative band origin rejected",
			rc:   window.Rect{X: 0, Y: 0, W: 1920, H: 1080},
			encW: 608, encH: 1080,
			sub:        &capture.Rect{X: -1, Y: 0, W: 608, H: 1080},
			wantReason: "no longer fits",
		},
		// The design-capped 4K band (1215x2160 encoded at 1080x1920): W/H
		// differ from encW/encH, so the invariant forces the scaled band onto
		// the tested gdigrab crop+scale path — never a ddagrab crop.
		{
			name: "scaled 4K band forced to gdigrab",
			rc:   window.Rect{X: 0, Y: 0, W: 3840, H: 2160},
			encW: 1080, encH: 1920,
			sub:        &capture.Rect{X: 1312, Y: 0, W: 1215, H: 2160},
			wantReason: "capture rect 1215x2160 differs from the 1080x1920 encode size",
		},
		// An even-floored odd-width band (405x720 -> 404x720) likewise.
		{
			name: "even-floored band forced to gdigrab",
			rc:   window.Rect{X: 0, Y: 0, W: 1280, H: 720},
			encW: 404, encH: 720,
			sub:        &capture.Rect{X: 438, Y: 0, W: 405, H: 720},
			wantReason: "capture rect 405x720 differs from the 404x720 encode size",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			eff, reason := ddagrabScreenRect(tc.rc, tc.encW, tc.encH, tc.sub)
			if tc.wantReason != "" {
				if !strings.Contains(reason, tc.wantReason) {
					t.Fatalf("reason = %q, want it to contain %q", reason, tc.wantReason)
				}
				if eff != (window.Rect{}) {
					t.Errorf("eff must be zero on fallback, got %+v", eff)
				}
				return
			}
			if reason != "" {
				t.Fatalf("unexpected gdigrab fallback: %q", reason)
			}
			if eff != tc.want {
				t.Errorf("eff = %+v, want %+v", eff, tc.want)
			}
		})
	}
}

func TestOutputLocalRect(t *testing.T) {
	// Primary monitor at the desktop origin: screen == output-local.
	got := outputLocalRect(
		window.Rect{X: 656, Y: 0, W: 608, H: 1080},
		window.Rect{X: 0, Y: 0, W: 1920, H: 1080})
	if want := (capture.Rect{X: 656, Y: 0, W: 608, H: 1080}); *got != want {
		t.Errorf("primary output crop = %+v, want %+v", *got, want)
	}
	// Secondary monitor left of the primary (negative desktop origin):
	// ddagrab's offset_x/offset_y are relative to THAT output's top-left, so
	// the negative screen X becomes a non-negative local offset.
	got = outputLocalRect(
		window.Rect{X: -1904, Y: 0, W: 608, H: 1080},
		window.Rect{X: -2560, Y: 0, W: 1920, H: 1080})
	if want := (capture.Rect{X: 656, Y: 0, W: 608, H: 1080}); *got != want {
		t.Errorf("secondary output crop = %+v, want %+v", *got, want)
	}
	// A monitor stacked below the primary translates Y the same way.
	got = outputLocalRect(
		window.Rect{X: 100, Y: 1130, W: 552, H: 984},
		window.Rect{X: 0, Y: 1080, W: 2560, H: 1440})
	if want := (capture.Rect{X: 100, Y: 50, W: 552, H: 984}); *got != want {
		t.Errorf("stacked output crop = %+v, want %+v", *got, want)
	}
}
