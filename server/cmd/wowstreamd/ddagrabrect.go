// The pure crop-coordinate arithmetic behind the zero-copy ddagrab path,
// extracted from the Windows-only ddagrabTarget so it is unit-testable on
// every platform (the live half needs a Win32 window.Tracker and DXGI; this
// half is just rectangles). ddagrabTarget (platform_windows.go) is a thin
// shell: measure the client rect, ddagrabScreenRect, window.LocateOutput,
// outputLocalRect.
package main

import (
	"fmt"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// ddagrabScreenRect resolves the SCREEN-SPACE rectangle a ddagrab launch
// would capture for the client area rc against the encW x encH frame the
// encoder will produce, or a human-readable reason the gdigrab fallback must
// be taken instead (eff is then zero).
//
// subRect, when non-nil, is a CLIENT-LOCAL sub-rectangle (band mode's
// centered 9:16 band): its offset is added to rc's screen origin — which
// ClientToScreen already made decoration-free, so no window-chrome term ever
// appears here. It is first guarded against a stale band (the window changed
// between main's frame decision and this launch): the crop must lie inside
// the client area.
//
// The size invariant is load-bearing: the ddagrab filter graph has no scaler
// — the crop IS the encoded frame (capture.Config.CaptureRect invariant) —
// so a capture rect that differs from the encode size (an odd-sized window
// or band even-floored, a design-capped band, or a resize since the argv
// snapshot) must go through gdigrab, whose crop/scale filters produce the
// advertised geometry. Cropping encW x encH here instead would frame desktop
// pixels around a smaller window, cut a larger one, or run past the monitor
// edge and fail outright — the black-frames-with-working-clicks failure.
func ddagrabScreenRect(rc window.Rect, encW, encH int, subRect *capture.Rect) (eff window.Rect, reason string) {
	eff = rc
	if subRect != nil {
		if subRect.X < 0 || subRect.Y < 0 || subRect.X+subRect.W > rc.W || subRect.Y+subRect.H > rc.H {
			return window.Rect{}, fmt.Sprintf("band crop %dx%d at (%d,%d) no longer fits the %dx%d client area",
				subRect.W, subRect.H, subRect.X, subRect.Y, rc.W, rc.H)
		}
		eff = window.Rect{X: rc.X + subRect.X, Y: rc.Y + subRect.Y, W: subRect.W, H: subRect.H}
	}
	if eff.W != encW || eff.H != encH {
		return window.Rect{}, fmt.Sprintf("capture rect %dx%d differs from the %dx%d encode size",
			eff.W, eff.H, encW, encH)
	}
	return eff, ""
}

// outputLocalRect translates the screen-space capture rect eff into the
// LOCAL coordinate space of the DXGI output whose desktop rect is desktop
// (window.LocateOutput resolved it as the output containing eff): ddagrab's
// offset_x/offset_y are relative to the captured output's top-left corner,
// not to the virtual desktop — a secondary monitor left of the primary has
// negative screen coordinates but non-negative output-local ones.
func outputLocalRect(eff, desktop window.Rect) *capture.Rect {
	return &capture.Rect{X: eff.X - desktop.X, Y: eff.Y - desktop.Y, W: eff.W, H: eff.H}
}
