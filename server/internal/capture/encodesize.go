package capture

import "fmt"

// minEncodeDim is the smallest frame dimension worth encoding — matching the
// --resolution flag's lower bound (config.ParseResolution). A window client
// area under this is a degenerate rect (mid-resize, minimized race), not a
// real game window.
const minEncodeDim = 16

// EncodeSize decides the encoded frame geometry for one ffmpeg launch from
// the game window's ACTUAL client area versus the configured resolution.
//
// The rule, load-bearing for the black-video failure class: the capture must
// always frame the real window — a fixed crop of the *assumed* size either
// grabs desktop pixels around a smaller window or runs past the monitor edge
// and fails outright, producing exactly "black frames while clicks still
// work" (input injection follows the live rect independently). So on a
// mismatch the encode adopts the actual client area, even-floored (every
// supported H.264 encoder needs mod-2 dimensions for 4:2:0; the sub-pixel
// scale from an odd rect is invisible), and the caller advertises the same
// geometry in the hello so the phone letterboxes correctly. Degraded but
// visible beats black.
//
// mismatch reports that the window does not match the configured resolution —
// the caller surfaces it loudly (log + dashboard) because it means WoW did
// not apply the configured resolution (Config.wtf overwritten because the
// game was running during setup, DPI virtualization, or the client restoring
// its own window rect).
//
// An unreadable or degenerate actual rect (zero, negative, or under
// minEncodeDim after even-flooring) falls back to the configured geometry:
// with no trustworthy window size the configured one is the best available
// frame, and gdigrab's scale filter normalizes whatever it grabs to it.
func EncodeSize(actualW, actualH, cfgW, cfgH int) (w, h int, mismatch bool) {
	if actualW <= 0 || actualH <= 0 {
		return cfgW, cfgH, false // window unreadable: nothing to compare against
	}
	ew, eh := actualW&^1, actualH&^1
	if ew < minEncodeDim || eh < minEncodeDim {
		// Real rect, but unencodably small (window mid-collapse): keep the
		// configured frame and still flag it — this IS a misconfiguration.
		return cfgW, cfgH, true
	}
	return ew, eh, ew != cfgW || eh != cfgH
}

// MismatchWarning is the one loud, plain-language explanation for a window
// that does not match the configured resolution, shown in the log and on the
// host dashboard's warning row. It names both sizes and the probable causes
// so the fix is actionable without reading source. encW/encH are what
// EncodeSize decided to stream (the actual window, or the configured frame
// when the actual rect was degenerate) so the message never overpromises.
func MismatchWarning(actualW, actualH, cfgW, cfgH, encW, encH int) string {
	return fmt.Sprintf(
		"WoW window is %dx%d but %dx%d is configured — the game may have been running when setup wrote Config.wtf, or it restored its own size; close WoW fully and restart it, or re-run setup. Streaming %dx%d meanwhile.",
		actualW, actualH, cfgW, cfgH, encW, encH)
}
