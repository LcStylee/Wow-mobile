// Shared frame types and the contract's integer rounding. The v0.4.x
// centered 9:16 "band" is now one phone of the PHONE FRAME contract
// (phoneframe.go, docs/PHONE_FRAME.md): BandFrame keeps its name as the
// resolved crop/encode decision for a live client area.
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
	// Banded reports that a crop is set (always true for a valid phone
	// frame).
	Banded bool
	// Band is the crop rect in CLIENT-LOCAL pixels.
	Band Rect
	// EncW/EncH are the dimensions the encoder must produce: the crop
	// even-floored for H.264 4:2:0, downscaled with its aspect to fit the
	// 1080x1920 design cap (EncodeCap) — encoding more would only cost
	// bitrate for pixels the phone downscales.
	EncW, EncH int
	// Scaled reports that EncW/EncH are a downscale of the crop, not its
	// even-floored identity (the design cap applied).
	Scaled bool
}

// roundHalfToEven divides num by den, rounding to the nearest integer with
// exact halves to the even neighbor (banker's rounding). Integer arithmetic
// throughout so the ports (tools/genphones.js, both addons' Band.lua, the
// client tests) and this agree bit-for-bit on every input.
//
// CONTRACT: num >= 0 and den > 0. Frame inputs provably satisfy it (the
// frame fits inside the client area, so the centering term is non-negative),
// and the restriction is load-bearing: for negative num, Go's truncating / and % and
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
