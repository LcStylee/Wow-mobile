// The PHONE FRAME contract (docs/PHONE_FRAME.md): the game keeps a normal
// widescreen window, the addon confines the phone UI to a centered portrait
// frame with the aspect of the phone model picked in-game, and outlines it
// with a red ring OUTSIDE the frame. This file holds the pure half of the
// server side: the placement math (a port of tools/genphones.js frameRect,
// pinned by phones.ContractVectors) and the outline detector that reads the
// frame the addon actually drew off a screenshot of the client area.
package window

import (
	"fmt"

	"github.com/LcStylee/Wow-mobile/server/internal/phones"
)

// ComputePhoneFrame places the frame for a phone whose stream aspect is
// streamW:streamH inside a clientW x clientH client area (PHONE_FRAME.md §4).
// The result reuses BandFrame: Banded is always true for a valid frame (the
// crop is the frame, even in a portrait window, since the ring margin always
// sits around it), EncW/EncH are the encode size capped to 1080x1920 with
// the frame's aspect.
func ComputePhoneFrame(clientW, clientH, streamW, streamH int) (BandFrame, bool) {
	if streamW <= 0 || streamH <= 0 {
		return BandFrame{}, false
	}
	availW := clientW - 2*phones.RingPx
	availH := clientH - 2*phones.RingPx
	if availW < minBandDim || availH < minBandDim {
		return BandFrame{}, false
	}
	h := availH
	w := roundHalfToEven(availH*streamW, streamH)
	if w > availW {
		w = availW
		h = roundHalfToEven(availW*streamH, streamW)
	}
	if w < minBandDim || h < minBandDim {
		return BandFrame{}, false
	}
	r := Rect{X: roundHalfToEven(clientW-w, 2), Y: roundHalfToEven(clientH-h, 2), W: w, H: h}
	return FrameForCrop(r)
}

// FrameForCrop turns a crop rect (computed, or detected from the outline)
// into the frame decision: the crop itself plus the capped encode size.
func FrameForCrop(r Rect) (BandFrame, bool) {
	if r.W < minBandDim || r.H < minBandDim {
		return BandFrame{}, false
	}
	encW, encH, scaled := EncodeCap(r.W, r.H)
	if encW < minBandDim || encH < minBandDim {
		return BandFrame{}, false
	}
	return BandFrame{Banded: true, Band: r, EncW: encW, EncH: encH, Scaled: scaled}, true
}

// EncodeCap fits w x h into the 1080x1920 design cap preserving aspect with
// even dimensions (H.264 4:2:0). scaled reports a real downscale.
func EncodeCap(w, h int) (encW, encH int, scaled bool) {
	if w <= phones.EncMaxW && h <= phones.EncMaxH {
		return w &^ 1, h &^ 1, false
	}
	if w*phones.EncMaxH >= h*phones.EncMaxW {
		return phones.EncMaxW, roundHalfToEven(h*phones.EncMaxW, w) &^ 1, true
	}
	return roundHalfToEven(w*phones.EncMaxH, h) &^ 1, phones.EncMaxH, true
}

// FrameSource names where the live frame came from (dashboard Layout line).
type FrameSource string

const (
	SourceOutline   FrameSource = "addon outline"
	SourceDashboard FrameSource = "dashboard phone"
	SourceLast      FrameSource = "last detected outline"
	SourceDefault   FrameSource = "default phone"
)

// PhoneFrameDescription renders the layout line, e.g.
// "phone frame 1203x2148 of 3840x2160 (encoded at 1074x1920) — frame: addon outline".
func PhoneFrameDescription(clientW, clientH int, f BandFrame, src FrameSource, phoneName string) string {
	desc := fmt.Sprintf("phone frame %dx%d of %dx%d", f.Band.W, f.Band.H, clientW, clientH)
	if f.Scaled || f.EncW != f.Band.W || f.EncH != f.Band.H {
		desc += fmt.Sprintf(" (encoded at %dx%d)", f.EncW, f.EncH)
	}
	desc += " — frame: " + string(src)
	if phoneName != "" && src != SourceOutline && src != SourceLast {
		desc += " (" + phoneName + ")"
	}
	return desc
}
