// Portable coordinate mapping: normalized protocol coordinates onto the live
// game window — or, under the band contract (docs/ARCHITECTURE.md), onto the
// centered 9:16 band inside a landscape window. Pure functions with no Win32
// dependency, so the mapping — including the band-vs-portrait split and the
// crop/scale chain consistency with capture — is unit-tested on every OS and
// shared by the --capture test log injector.

package wininput

import "github.com/LcStylee/Wow-mobile/server/internal/window"

// TargetRect resolves the screen rect that normalized coordinates map onto
// for a live client rect. In band layout a landscape window contributes only
// its centered 9:16 band — the exact rect the capture crops — so a tap at the
// phone's center lands on the window's center column; a portrait window (or
// portrait layout) maps onto the whole client area, matching the full-window
// stream.
func TargetRect(client window.Rect, band bool) window.Rect {
	if !band {
		return client
	}
	f, ok := window.ComputeBandFrame(client.W, client.H)
	if !ok || !f.Banded {
		return client
	}
	return window.Rect{X: client.X + f.Band.X, Y: client.Y + f.Band.Y, W: f.Band.W, H: f.Band.H}
}

// MapNormalized converts one normalized coordinate pair (0..65535 per
// PROTOCOL.md) to screen pixels inside target, using the spec's pixel-index
// convention px = round(x/65535*(W-1)). The client sends continuous
// fractions; the difference is sub-pixel.
func MapNormalized(nx, ny uint16, target window.Rect) (px, py int) {
	px = target.X + int(uint32(nx)*uint32(target.W-1)+32767)/65535
	py = target.Y + int(uint32(ny)*uint32(target.H-1)+32767)/65535
	return px, py
}
