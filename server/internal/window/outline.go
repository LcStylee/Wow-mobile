package window

// Outline detection (PHONE_FRAME.md §5). The addon draws a ring OUTSIDE the
// phone frame: outer 4 px pure red #FF0000, inner 2 px pure cyan #00FFFF.
// The cyan band is the machine tag — the crop is the interior of the cyan
// ring. The detector is deliberately tolerant of what a real screenshot does
// to thin lines (UI-scale rounding can blend an edge pixel, or widen/narrow
// a band by one pixel), and deliberately strict about shape: all four cyan
// edges with red immediately outside them, spanning at least 30% of the
// client height, is not something the game world or the default UI draws.

// Colour classifiers. The addon draws exact colours; the slack absorbs
// dithering, gamma/HDR tone mapping and edge blending.
func isCyan(r, g, b uint8) bool { return r < 90 && g > 170 && b > 170 }
func isRed(r, g, b uint8) bool  { return r > 170 && g < 90 && b < 90 }

// minOutlineFraction is the smallest frame height (fraction of the client
// height) accepted as an outline.
const minOutlineFraction = 0.30

// DetectOutline finds the phone-frame outline in a BGRA (Windows DIB order)
// top-down image of the client area and returns the interior rect in
// client pixels. stride is the row pitch in bytes.
func DetectOutline(pix []byte, w, h, stride int) (Rect, bool) {
	if w < 32 || h < 32 || stride < 4*w || len(pix) < stride*(h-1)+4*w {
		return Rect{}, false
	}
	at := func(x, y int) (r, g, b uint8) {
		i := y*stride + 4*x
		return pix[i+2], pix[i+1], pix[i]
	}
	cyanAt := func(x, y int) bool { r, g, b := at(x, y); return isCyan(r, g, b) }
	redAt := func(x, y int) bool { r, g, b := at(x, y); return isRed(r, g, b) }

	minLen := int(float64(h) * minOutlineFraction)
	// Column/row cyan counts. The vertical edges are the only columns with a
	// long cyan run; counting (not requiring contiguity) tolerates the odd
	// blended pixel.
	colCount := make([]int, w)
	rowCount := make([]int, h)
	for y := 0; y < h; y++ {
		base := y * stride
		for x := 0; x < w; x++ {
			i := base + 4*x
			if isCyan(pix[i+2], pix[i+1], pix[i]) {
				colCount[x]++
				rowCount[y]++
			}
		}
	}
	// Left edge group: first column with a long run; the interior starts
	// after the last consecutive such column. Right edge mirrors it.
	left := -1
	for x := 0; x < w; x++ {
		if colCount[x] >= minLen {
			left = x
			break
		}
	}
	if left < 0 {
		return Rect{}, false
	}
	for left+1 < w && colCount[left+1] >= minLen {
		left++
	}
	right := -1
	for x := w - 1; x > left; x-- {
		if colCount[x] >= minLen {
			right = x
			break
		}
	}
	if right < 0 {
		return Rect{}, false
	}
	for right-1 > left && colCount[right-1] >= minLen {
		right--
	}
	innerW := right - left - 1
	if innerW < minBandDim {
		return Rect{}, false
	}
	// Horizontal edges: rows with cyan spanning most of the frame width.
	minRow := innerW * 3 / 4
	top := -1
	for y := 0; y < h; y++ {
		if rowCount[y] >= minRow {
			top = y
			break
		}
	}
	if top < 0 {
		return Rect{}, false
	}
	for top+1 < h && rowCount[top+1] >= minRow {
		top++
	}
	bottom := -1
	for y := h - 1; y > top; y-- {
		if rowCount[y] >= minRow {
			bottom = y
			break
		}
	}
	if bottom < 0 {
		return Rect{}, false
	}
	for bottom-1 > top && rowCount[bottom-1] >= minRow {
		bottom--
	}
	innerH := bottom - top - 1
	if innerH < minLen {
		return Rect{}, false
	}
	// Shape check: the cyan columns must actually run along the found rows
	// (not two unrelated cyan things), and red must sit right outside each
	// edge at its midpoint (within 3 px, allowing a blended pixel).
	midY := top + (bottom-top)/2
	midX := left + (right-left)/2
	if !cyanAt(left, midY) || !cyanAt(right, midY) || !cyanAt(midX, top) || !cyanAt(midX, bottom) {
		return Rect{}, false
	}
	redNear := func(x, y, dx, dy int) bool {
		for k := 1; k <= 5; k++ {
			xx, yy := x+dx*k, y+dy*k
			if xx < 0 || yy < 0 || xx >= w || yy >= h {
				return false
			}
			if redAt(xx, yy) {
				return true
			}
		}
		return false
	}
	if !redNear(left, midY, -1, 0) || !redNear(right, midY, 1, 0) ||
		!redNear(midX, top, 0, -1) || !redNear(midX, bottom, 0, 1) {
		return Rect{}, false
	}
	return Rect{X: left + 1, Y: top + 1, W: innerW, H: innerH}, true
}
