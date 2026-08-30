// Monitor-fit math for --resolution fit: the largest 9:16 portrait client
// area that fits the primary monitor's work area once window decorations are
// accounted for. Pure and portable — the Windows-only measurements (work
// area, decoration extents) are taken by the caller (install.System) and fed
// in as plain integers, so this file is unit-testable everywhere.
package window

import "fmt"

// Conservative window-decoration extents, used when the exact
// AdjustWindowRectExForDpi (or AdjustWindowRectEx) measurement is
// unavailable: 8 px resize borders left and right (16 total), plus a 32 px
// title bar and the top/bottom borders vertically (48 total). These match a
// standard WS_OVERLAPPEDWINDOW at 100% scaling and only ever err a few pixels
// large there — a slightly smaller window beats one that does not fit.
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

// DesignW/DesignH are the 1080x1920 design resolution — the fit CAP, not just
// prose: the phone renders 1080x1920 pixel-for-pixel, so a window larger than
// the design size (a 1440p/4K monitor could hold one) would only raise encode
// cost and bandwidth with zero phone-side benefit. The fit shrinks below the
// design size only when the monitor genuinely cannot hold it.
const (
	DesignW = 1080
	DesignH = 1920
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
// decorW x decorH for the window frame (borders + title bar), CAPPED at the
// 1080x1920 design resolution (DesignW/DesignH): a monitor that can hold the
// design window gets exactly it — never larger. Both returned dimensions are
// even (every supported H.264 encoder needs mod-2 sizes for 4:2:0) and
// rounded DOWN, so the window always genuinely fits; below the cap the aspect
// is therefore exact to within one even-rounding step (< 2 px). ok is false
// when the work area cannot hold even a minimal (270x480) window —
// degenerate or misreported monitors — and the caller should keep a default
// instead.
func FitPortraitClient(workW, workH, decorW, decorH int) (w, h int, ok bool) {
	availW := workW - decorW
	availH := workH - decorH
	if availW <= 0 || availH <= 0 {
		return 0, 0, false
	}
	// The cap first: when the full design window fits (4K, portrait 1440p),
	// take it exactly — the maximal-fit math below would only produce a
	// larger window that costs encode time for pixels the phone downscales.
	if availW >= DesignW && availH >= DesignH {
		return DesignW, DesignH, true
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
// shown on the dashboard for a fitted resolution. A capped fit reads
// differently from a shrunk one: "fits with room to spare" tells a 4K user
// the small-looking window is deliberate, not a sizing bug.
func FitDescription(w, h, workW, workH int) string {
	if w == DesignW && h == DesignH {
		return fmt.Sprintf("portrait window %dx%d (the design resolution — fits your %dx%d work area with room to spare)", w, h, workW, workH)
	}
	return fmt.Sprintf("portrait window %dx%d — the largest 9:16 window that fits your %dx%d work area", w, h, workW, workH)
}

// evenFloor rounds v down to the nearest even number (H.264 4:2:0 needs
// mod-2 frame sizes; see config.ParseResolution).
func evenFloor(v int) int {
	return v &^ 1
}
