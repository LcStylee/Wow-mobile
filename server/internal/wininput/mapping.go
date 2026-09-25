// Portable coordinate mapping: normalized protocol coordinates onto the live
// game window — or, under the band contract (docs/ARCHITECTURE.md), onto the
// centered 9:16 band inside a landscape window. Pure functions with no Win32
// dependency, so the mapping — including the band-vs-portrait split and the
// crop/scale chain consistency with capture — is unit-tested on every OS and
// shared by the --capture test log injector.

package wininput

import "github.com/LcStylee/Wow-mobile/server/internal/window"

// CropFunc returns the CLIENT-LOCAL rect the stream crops out of a
// clientW x clientH client area (the phone frame, docs/PHONE_FRAME.md), ok
// false when the whole client area is streamed. It must return the exact
// crop the running capture uses, so touch stays aligned with the video.
type CropFunc func(clientW, clientH int) (window.Rect, bool)

// TargetRect resolves the screen rect that normalized coordinates map onto
// for a live client rect: the crop (offset by the client origin) under frame
// layout, the whole client area otherwise (nil crop, or no crop decided).
func TargetRect(client window.Rect, crop CropFunc) window.Rect {
	if crop == nil {
		return client
	}
	r, ok := crop(client.W, client.H)
	if !ok || r.W < 2 || r.H < 2 {
		return client
	}
	return window.Rect{X: client.X + r.X, Y: client.Y + r.Y, W: r.W, H: r.H}
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
