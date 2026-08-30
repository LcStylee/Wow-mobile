// Monitor-fit math for --resolution fit: the largest 9:16 portrait client
// area that fits the primary monitor's work area once window decorations are
// accounted for. Pure and portable — the Windows-only measurements (work
// area, decoration extents) are taken by the caller (install.System) and fed
// in as plain integers, so this file is unit-testable everywhere.
package window

import "fmt"

// Conservative window-decoration extents, used when the exact
// AdjustWindowRectEx measurement is unavailable: 8 px resize borders left and
// right (16 total), plus a 32 px title bar and the top/bottom borders
// vertically (48 total). These match a standard WS_OVERLAPPEDWINDOW at 100%
// scaling and only ever err a few pixels large — a slightly smaller window
// beats one that does not fit.
const (
	FallbackDecorationW = 16
	FallbackDecorationH = 48
)

// Design aspect of the portrait window (ARCHITECTURE.md §1): 9:16, the
// 1080x1920 design space every addon layout constant is expressed in.
const (
	aspectW = 9
	aspectH = 16
)

// minFitW/H reject work areas too small for a playable window: below a
// quarter of the design size the deck's 90 px touch targets shrink under
// ~7 mm and the encode is pointless. Callers fall back to the design
// resolution (with its own warning) instead.
const (
	minFitW = 270
	minFitH = 480
)

// FitPortraitClient computes the largest client area with the 9:16 portrait
// design aspect that fits a workW x workH monitor work area after reserving
// decorW x decorH for the window frame (borders + title bar). Both returned
// dimensions are even (every supported H.264 encoder needs mod-2 sizes for
// 4:2:0) and rounded DOWN, so the window always genuinely fits; the aspect is
// therefore exact to within one even-rounding step (< 2 px). ok is false when
// the work area cannot hold even a minimal (270x480) window — degenerate or
// misreported monitors — and the caller should keep a default instead.
func FitPortraitClient(workW, workH, decorW, decorH int) (w, h int, ok bool) {
	availW := workW - decorW
	availH := workH - decorH
	if availW <= 0 || availH <= 0 {
		return 0, 0, false
	}
	// Height-limited first (the common landscape-monitor case), then re-fit
	// by width if the 9:16 window is still too wide (very narrow work areas).
	h = evenFloor(availH)
	w = evenFloor(h * aspectW / aspectH)
	if w > availW {
		w = evenFloor(availW)
		h = evenFloor(w * aspectH / aspectW)
		if h > availH { // integer-rounding edge: never exceed the work area
			h = evenFloor(availH)
		}
	}
	if w < minFitW || h < minFitH {
		return 0, 0, false
	}
	return w, h, true
}

// FitDescription is the one-line human explanation printed by the wizard and
// shown on the dashboard for a fitted resolution.
func FitDescription(w, h, workW, workH int) string {
	return fmt.Sprintf("portrait window %dx%d — the largest 9:16 window that fits your %dx%d work area", w, h, workW, workH)
}

// evenFloor rounds v down to the nearest even number (H.264 4:2:0 needs
// mod-2 frame sizes; see config.ParseResolution).
func evenFloor(v int) int {
	return v &^ 1
}
