package window

import (
	"math/rand"
	"testing"

	"github.com/LcStylee/Wow-mobile/server/internal/phones"
)

func TestComputePhoneFrameContractVectors(t *testing.T) {
	for _, v := range phones.ContractVectors {
		p, ok := phones.ByID(v.Phone)
		if !ok {
			t.Fatalf("vector phone %q missing", v.Phone)
		}
		f, ok := ComputePhoneFrame(v.ClientW, v.ClientH, p.StreamW, p.StreamH)
		if !ok {
			t.Fatalf("%s %dx%d: no frame", v.Phone, v.ClientW, v.ClientH)
		}
		want := Rect{X: v.X, Y: v.Y, W: v.W, H: v.H}
		if f.Band != want || f.EncW != v.EncW || f.EncH != v.EncH {
			t.Errorf("%s %dx%d: got %+v enc %dx%d, want %+v enc %dx%d",
				v.Phone, v.ClientW, v.ClientH, f.Band, f.EncW, f.EncH, want, v.EncW, v.EncH)
		}
	}
}

// Every phone at a spread of client sizes: the frame (plus its ring) fits the
// client, is centered, and keeps the phone's aspect within a pixel.
func TestComputePhoneFrameInvariants(t *testing.T) {
	sizes := [][2]int{{3840, 2160}, {1920, 1080}, {1024, 768}, {800, 1280}, {5120, 1440}, {640, 360}, {1111, 777}}
	for _, p := range phones.All {
		for _, s := range sizes {
			f, ok := ComputePhoneFrame(s[0], s[1], p.StreamW, p.StreamH)
			if !ok {
				t.Fatalf("%s %v: no frame", p.ID, s)
			}
			r := f.Band
			if r.X < phones.RingPx || r.Y < phones.RingPx || r.X+r.W > s[0]-phones.RingPx || r.Y+r.H > s[1]-phones.RingPx {
				t.Errorf("%s %v: frame %+v leaves no room for the ring", p.ID, s, r)
			}
			if d := (s[0] - r.W) - 2*r.X; d < -1 || d > 1 {
				t.Errorf("%s %v: frame %+v not centered", p.ID, s, r)
			}
			// |W/H - sw/sh| < 1px in either dimension
			if e := r.W*p.StreamH - r.H*p.StreamW; e > p.StreamH || -e > p.StreamH {
				if e2 := r.H*p.StreamW - r.W*p.StreamH; e2 > p.StreamW || -e2 > p.StreamW {
					t.Errorf("%s %v: frame %+v aspect off", p.ID, s, r)
				}
			}
			if f.EncW > phones.EncMaxW || f.EncH > phones.EncMaxH || f.EncW%2 != 0 || f.EncH%2 != 0 {
				t.Errorf("%s %v: bad encode %dx%d", p.ID, s, f.EncW, f.EncH)
			}
		}
	}
}

// paint draws the addon's ring (4 red + 2 cyan, outside rect r) into a BGRA
// image, optionally blending the outermost/innermost ring pixels with the
// background the way a fractional UI-scale edge would.
func paintRing(pix []byte, w, stride int, r Rect, blend bool) {
	set := func(x, y int, R, G, B uint8) {
		i := y*stride + 4*x
		pix[i], pix[i+1], pix[i+2], pix[i+3] = B, G, R, 255
	}
	fill := func(x0, y0, x1, y1 int, R, G, B uint8) {
		for y := y0; y < y1; y++ {
			for x := x0; x < x1; x++ {
				set(x, y, R, G, B)
			}
		}
	}
	o := phones.RingPx
	fill(r.X-o, r.Y-o, r.X+r.W+o, r.Y+r.H+o, 255, 0, 0)
	c := phones.RingInnerPx
	fill(r.X-c, r.Y-c, r.X+r.W+c, r.Y+r.H+c, 0, 255, 255)
	// interior: noisy "game UI"
	rng := rand.New(rand.NewSource(1))
	for y := r.Y; y < r.Y+r.H; y++ {
		for x := r.X; x < r.X+r.W; x++ {
			set(x, y, uint8(rng.Intn(256)), uint8(rng.Intn(256)), uint8(rng.Intn(256)))
		}
	}
	if blend {
		// Soften the outermost red row/column: half red over grey.
		for x := r.X - o; x < r.X+r.W+o; x++ {
			set(x, r.Y-o, 190, 60, 60)
		}
	}
}

func newImage(w, h int, seed int64) ([]byte, int) {
	stride := 4 * w
	pix := make([]byte, stride*h)
	rng := rand.New(rand.NewSource(seed))
	for i := 0; i < len(pix); i += 4 {
		v := uint8(rng.Intn(120)) // dark "world"
		pix[i], pix[i+1], pix[i+2], pix[i+3] = v, v, v, 255
	}
	return pix, stride
}

func TestDetectOutline(t *testing.T) {
	for _, tc := range []struct {
		w, h  int
		phone string
		blend bool
	}{
		{1280, 720, "iphone-17", false},
		{1920, 1080, "galaxy-a07", true},
		{1600, 1000, "generic-9-16", false},
		{900, 1400, "iphone-se-3", false},
	} {
		p, _ := phones.ByID(tc.phone)
		f, ok := ComputePhoneFrame(tc.w, tc.h, p.StreamW, p.StreamH)
		if !ok {
			t.Fatal("no frame")
		}
		pix, stride := newImage(tc.w, tc.h, 7)
		paintRing(pix, tc.w, stride, f.Band, tc.blend)
		got, ok := DetectOutline(pix, tc.w, tc.h, stride)
		if !ok || got != f.Band {
			t.Errorf("%dx%d %s: detected %+v ok=%v, want %+v", tc.w, tc.h, tc.phone, got, ok, f.Band)
		}
	}
}

func TestDetectOutlineRejects(t *testing.T) {
	w, h := 1280, 720
	// Nothing drawn.
	pix, stride := newImage(w, h, 3)
	if r, ok := DetectOutline(pix, w, h, stride); ok {
		t.Errorf("empty image detected %+v", r)
	}
	// A cyan-only rectangle (no red outside) is not the addon's ring.
	for y := 100; y < 600; y++ {
		for x := 400; x < 800; x++ {
			if x < 402 || x >= 798 || y < 102 || y >= 598 {
				i := y*stride + 4*x
				pix[i], pix[i+1], pix[i+2] = 255, 255, 0
			}
		}
	}
	if r, ok := DetectOutline(pix, w, h, stride); ok {
		t.Errorf("cyan-only rectangle detected %+v", r)
	}
	// A ring too small (under 30% of the height) is rejected.
	pix, stride = newImage(w, h, 4)
	paintRing(pix, w, stride, Rect{X: 600, Y: 300, W: 80, H: 150}, false)
	if r, ok := DetectOutline(pix, w, h, stride); ok {
		t.Errorf("tiny ring detected %+v", r)
	}
	// Truncated buffer.
	if _, ok := DetectOutline(pix[:100], w, h, stride); ok {
		t.Error("short buffer accepted")
	}
}

func TestEncodeCap(t *testing.T) {
	for _, tc := range []struct{ w, h, ew, eh int }{
		{598, 1068, 598, 1068},
		{599, 1069, 598, 1068},
		{1203, 2148, 1074, 1920},
		{2000, 3000, 1080, 1620},
	} {
		ew, eh, _ := EncodeCap(tc.w, tc.h)
		if ew != tc.ew || eh != tc.eh {
			t.Errorf("EncodeCap(%d,%d) = %dx%d, want %dx%d", tc.w, tc.h, ew, eh, tc.ew, tc.eh)
		}
	}
}
