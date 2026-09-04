// The BAND CONTRACT (docs/ARCHITECTURE.md): when the game window's client
// area is LANDSCAPE, the touch experience lives in a CENTERED 9:16 PORTRAIT
// BAND of the window — the window itself is never forced portrait. The addon
// and the server compute the band INDEPENDENTLY from the same window
// dimensions, so the formula here is normative and deterministic:
//
//	bandHeight = clientHeight
//	bandWidth  = roundHalfToEven(clientHeight * 9 / 16)
//	bandX      = roundHalfToEven((clientWidth - bandWidth) / 2)
//	bandY      = 0
//
// (round-half-to-even: exact .5 results round to the even neighbor — banker's
// rounding — so both sides land on the same integers without floating point.)
// Inside the band, the 1080x1920 design space maps as fractions of the band:
// the band IS the design space, scaled. When the window is PORTRAIT
// (height >= width), behavior is exactly the full-window mode — no band.
//
// Everything in this file is portable and pure; the live client rect is
// measured by the callers (capture argv building, input injection).
package window

import "fmt"

// minBandDim mirrors capture's minimum encodable dimension: a band or window
// under 16 px per axis is a degenerate rect (mid-resize, minimized race), not
// a real frame worth encoding.
const minBandDim = 16

// BandFrame is one resolved framing decision for a live client area.
type BandFrame struct {
	// Banded reports that the window is landscape and the centered 9:16 band
	// is being cropped. False for a portrait window: full-window mode, Band
	// is zero and EncW/EncH frame the whole client area.
	Banded bool
	// Band is the band rect in CLIENT-LOCAL pixels (X centered, Y always 0,
	// H the full client height). Only meaningful when Banded.
	Band Rect
	// EncW/EncH are the dimensions the encoder must produce: the band (or
	// full window) even-floored for H.264 4:2:0, downscaled to the 1080x1920
	// design cap when the band is taller than the design space (a 4K desktop
	// gives a 1215x2160 band; encoding more than 1080x1920 would only cost
	// bitrate for pixels the phone downscales).
	EncW, EncH int
	// Scaled reports that EncW/EncH are a downscale of the band, not its
	// even-floored identity (the design cap applied).
	Scaled bool
}

// ComputeBandFrame resolves the band contract for a live client area. ok is
// false for a degenerate rect (unreadable, or too small to encode) — the
// caller then keeps its configured fallback frame.
func ComputeBandFrame(clientW, clientH int) (BandFrame, bool) {
	if clientW < minBandDim || clientH < minBandDim {
		return BandFrame{}, false
	}
	if clientH >= clientW {
		// Portrait (or square) window: exactly today's full-window mode.
		encW, encH := clientW&^1, clientH&^1
		if encW < minBandDim || encH < minBandDim {
			return BandFrame{}, false
		}
		return BandFrame{EncW: encW, EncH: encH}, true
	}
	bandW := roundHalfToEven(clientH*9, 16)
	bandX := roundHalfToEven(clientW-bandW, 2)
	if bandW < minBandDim {
		return BandFrame{}, false
	}
	f := BandFrame{
		Banded: true,
		Band:   Rect{X: bandX, Y: 0, W: bandW, H: clientH},
		EncW:   bandW &^ 1,
		EncH:   clientH &^ 1,
	}
	if f.EncH > DesignH {
		// The band exceeds the design space: encode the design resolution.
		// The band is 9:16 to within a pixel by construction, so the scale
		// is uniform to sub-pixel accuracy.
		f.EncW, f.EncH = DesignW, DesignH
		f.Scaled = true
	}
	return f, true
}

// BandLayoutDescription renders the live layout line for the log and the host
// dashboard, e.g. "center band 1215x2160 of 3840x2160 (encoded at 1080x1920)"
// or, for a portrait window under band layout, an honest full-window notice.
func BandLayoutDescription(clientW, clientH int, f BandFrame) string {
	if !f.Banded {
		return fmt.Sprintf("full window %dx%d (window is portrait — no band)", clientW, clientH)
	}
	desc := fmt.Sprintf("center band %dx%d of %dx%d", f.Band.W, f.Band.H, clientW, clientH)
	if f.Scaled || f.EncW != f.Band.W || f.EncH != f.Band.H {
		desc += fmt.Sprintf(" (encoded at %dx%d)", f.EncW, f.EncH)
	}
	return desc
}

// roundHalfToEven divides num by den, rounding to the nearest integer with
// exact halves to the even neighbor (banker's rounding). Integer arithmetic
// throughout so the addon's Lua port (addon/WowMobile/Band.lua,
// RoundHalfToEven) and this agree bit-for-bit on every input.
//
// CONTRACT: num >= 0 and den > 0. Band inputs provably satisfy it
// (bandW <= clientH < clientW, so the centering term is positive), and the
// restriction is load-bearing: for negative num, Go's truncating / and % and
// Lua's floor division disagree — and neither would be banker's rounding —
// so a future variant that could go negative must extend BOTH ports and this
// guard together, not rely on the current arithmetic.
func roundHalfToEven(num, den int) int {
	if num < 0 || den <= 0 {
		panic(fmt.Sprintf("roundHalfToEven(%d, %d): out of contract (num >= 0, den > 0 required — see the Lua port's identical restriction)", num, den))
	}
	q, r := num/den, num%den
	switch {
	case 2*r > den:
		return q + 1
	case 2*r < den:
		return q
	default: // exact half: round to even
		return q + (q & 1)
	}
}
