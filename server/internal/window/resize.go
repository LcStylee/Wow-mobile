// Direct game-window resizing — the portable decision/verification core.
//
// Why this exists (field-verified): CVars are the wrong tool for sizing a
// windowed 1.12 client. On that client generation gxResolution governs
// FULLSCREEN mode only; a windowed 1.12 opens at its own remembered/default
// size (800x600 out of the box) and ignores the CVar entirely. So after the
// game window is found, the host resizes it DIRECTLY via SetWindowPos —
// which works on every windowed client (1.12, Era, custom) independent of
// any CVar. The Win32 half lives in resize_windows.go; everything here is
// pure logic under portable tests.
package window

// Win32 window style bits consulted by the resize decision (winuser.h).
// Portable copies so the decision logic tests run on any OS.
const (
	StyleCaption  uint32 = 0x00C00000 // WS_CAPTION: a titled, windowed window
	StylePopup    uint32 = 0x80000000 // WS_POPUP: fullscreen/borderless surfaces
	StyleMaximize uint32 = 0x01000000 // WS_MAXIMIZE
	StyleMinimize uint32 = 0x20000000 // WS_MINIMIZE
)

// ResizeTolerancePx is the mismatch threshold: client-area differences at or
// under this many pixels per axis are left alone. DPI/frame rounding can
// leave a window a pixel or two off its requested size, and "fixing" that
// would loop forever against a client that re-asserts its own rounding; a
// ≤2 px difference is also visually and touch-mapping irrelevant (EncodeSize
// already even-floors odd rects).
const ResizeTolerancePx = 2

// EnforceOutcome classifies one EnforceClientSizeWith run.
type EnforceOutcome int

const (
	// EnforceResized: the window now has (within tolerance) the wanted client
	// area — possibly after the one retry.
	EnforceResized EnforceOutcome = iota
	// EnforceAlready: the client area already matched within tolerance;
	// nothing was touched.
	EnforceAlready
	// EnforceSkipFullscreen: the window is a fullscreen/borderless surface
	// (WS_POPUP without WS_CAPTION) — never resized; the user must switch the
	// game to windowed mode instead.
	EnforceSkipFullscreen
	// EnforceSkipMaximized: the window is maximized — never resized (restoring
	// it behind the user's back is not this tool's call).
	EnforceSkipMaximized
	// EnforceSkipMinimized: the window is minimized; its rect is meaningless.
	EnforceSkipMinimized
	// EnforceReverted: SetWindowPos was applied (twice — the retry included)
	// but the game re-asserted a different size both times. The caller reports
	// this honestly and streams the actual size (adapt-to-actual).
	EnforceReverted
	// EnforceFailed: a Win32 call failed outright.
	EnforceFailed
)

// String renders the outcome for logs.
func (o EnforceOutcome) String() string {
	switch o {
	case EnforceResized:
		return "resized"
	case EnforceAlready:
		return "already-sized"
	case EnforceSkipFullscreen:
		return "skipped-fullscreen"
	case EnforceSkipMaximized:
		return "skipped-maximized"
	case EnforceSkipMinimized:
		return "skipped-minimized"
	case EnforceReverted:
		return "reverted-by-game"
	case EnforceFailed:
		return "failed"
	}
	return "unknown"
}

// SizeMatches reports whether a client area matches the wanted one within
// ResizeTolerancePx per axis.
func SizeMatches(gotW, gotH, wantW, wantH int) bool {
	return abs(gotW-wantW) <= ResizeTolerancePx && abs(gotH-wantH) <= ResizeTolerancePx
}

// classifyStyle maps window style bits to a skip outcome, or ok=true for a
// plain windowed (resizable-by-us) window. WS_CAPTION wins over WS_POPUP:
// some frameworks set both, and a captioned window behaves windowed.
func classifyStyle(style uint32) (outcome EnforceOutcome, ok bool) {
	switch {
	case style&StyleMinimize != 0:
		return EnforceSkipMinimized, false
	case style&StyleMaximize != 0:
		return EnforceSkipMaximized, false
	case style&StyleCaption != StyleCaption && style&StylePopup != 0:
		return EnforceSkipFullscreen, false
	}
	return 0, true
}

// ClampOrigin keeps a window's outer rect on the work area: the origin is
// shifted so the window ends inside work where it fits, and pinned to the
// work area's top-left where it does not (a top-left-pinned oversized window
// keeps its title bar and close button reachable).
func ClampOrigin(x, y, outerW, outerH int, work Rect) (int, int) {
	maxX := work.X + work.W - outerW
	maxY := work.Y + work.H - outerH
	x = min(x, maxX)
	y = min(y, maxY)
	// Lower bound LAST so it wins when the window is larger than the work
	// area: origin stays at the work area's top-left, never off-screen.
	x = max(x, work.X)
	y = max(y, work.Y)
	return x, y
}

// EnforceClientSizeWith is the portable resize orchestrator: decide from the
// style bits and current client size, then drive apply/measure with exactly
// one retry (clients like 1.12 are known to re-assert their own size once —
// a second SetWindowPos usually sticks; endless fighting never helps).
//
//	apply(attempt)  — perform one SetWindowPos round (attempt is 0 or 1)
//	measure()       — read the live client size after an apply
//
// The Win32 caller (Tracker.EnforceClientSize) supplies the primitives; tests
// supply fakes, which is what keeps windowed-vs-not, threshold, retry-once,
// and revert handling under portable tests.
func EnforceClientSizeWith(
	style uint32,
	actualW, actualH, wantW, wantH int,
	apply func(attempt int) error,
	measure func() (w, h int, ok bool),
) EnforceOutcome {
	if outcome, ok := classifyStyle(style); !ok {
		return outcome
	}
	if SizeMatches(actualW, actualH, wantW, wantH) {
		return EnforceAlready
	}
	for attempt := 0; attempt < 2; attempt++ {
		if err := apply(attempt); err != nil {
			return EnforceFailed
		}
		w, h, ok := measure()
		if !ok {
			return EnforceFailed
		}
		if SizeMatches(w, h, wantW, wantH) {
			return EnforceResized
		}
	}
	return EnforceReverted
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
