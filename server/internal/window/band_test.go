package window

import "testing"

// The contract anchors: these exact numbers are shared with the addon (which
// computes the band independently in Lua) and asserted by the e2e band
// scenario — changing any of them is a cross-component protocol change.
func TestComputeBandFrameContractAnchors(t *testing.T) {
	tests := []struct {
		name         string
		w, h         int
		banded       bool
		bandX, bandW int
		encW, encH   int
		scaled       bool
	}{
		// The e2e scenario: 720p landscape window.
		{"1280x720", 1280, 720, true, 438, 405, 404, 720, false},
		// A 1080p desktop: band 607/608? 1080*9/16 = 607.5 -> even neighbor 608.
		{"1920x1080", 1920, 1080, true, 656, 608, 608, 1080, false},
		// 4K desktop: the ARCHITECTURE.md example — band 1215x2160, encoded at
		// the 1080x1920 design cap.
		{"3840x2160", 3840, 2160, true, 1312, 1215, 1080, 1920, true},
		// 1440p desktop.
		{"2560x1440", 2560, 1440, true, 875, 810, 810, 1440, false},
		// A window exactly the design height: band == design space, unscaled.
		{"3413x1920", 3413, 1920, true, 1166, 1080, 1080, 1920, false},
		// Portrait window: full-window mode, no band.
		{"552x984", 552, 984, false, 0, 0, 552, 984, false},
		// Square counts as portrait per the contract (height >= width).
		{"800x800", 800, 800, false, 0, 0, 800, 800, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, ok := ComputeBandFrame(tc.w, tc.h)
			if !ok {
				t.Fatalf("ComputeBandFrame(%d,%d) not ok", tc.w, tc.h)
			}
			if f.Banded != tc.banded {
				t.Fatalf("Banded = %v, want %v", f.Banded, tc.banded)
			}
			if f.Banded {
				if f.Band.X != tc.bandX || f.Band.Y != 0 || f.Band.W != tc.bandW || f.Band.H != tc.h {
					t.Errorf("band = %+v, want X=%d Y=0 W=%d H=%d", f.Band, tc.bandX, tc.bandW, tc.h)
				}
			}
			if f.EncW != tc.encW || f.EncH != tc.encH || f.Scaled != tc.scaled {
				t.Errorf("enc = %dx%d scaled=%v, want %dx%d scaled=%v",
					f.EncW, f.EncH, f.Scaled, tc.encW, tc.encH, tc.scaled)
			}
		})
	}
}

// Odd client dimensions: the band keeps the exact contract values (the addon
// sees the same odd window), only the ENCODE even-floors — and the band stays
// centered to within a pixel of the true center.
func TestComputeBandFrameOddDimensions(t *testing.T) {
	f, ok := ComputeBandFrame(1281, 719)
	if !ok || !f.Banded {
		t.Fatalf("1281x719 must band: %+v ok=%v", f, ok)
	}
	// 719*9/16 = 404.4375 -> 404; (1281-404)/2 = 438.5 -> even neighbor 438.
	if f.Band.W != 404 || f.Band.H != 719 || f.Band.X != 438 {
		t.Fatalf("band = %+v, want 404x719 at X=438", f.Band)
	}
	if f.EncW != 404 || f.EncH != 718 {
		t.Fatalf("enc = %dx%d, want 404x718 (even-floored)", f.EncW, f.EncH)
	}
	// Centering: the band's center column must sit within one pixel of the
	// window's center column, for a sweep of widths including odd ones.
	for w := 900; w < 940; w++ {
		f, ok := ComputeBandFrame(w, 500)
		if !ok || !f.Banded {
			t.Fatalf("%dx500 must band", w)
		}
		bandCenter2 := 2*f.Band.X + f.Band.W // band center * 2
		winCenter2 := w                      // window center * 2
		if diff := bandCenter2 - winCenter2; diff < -2 || diff > 2 {
			t.Errorf("width %d: band center off by %d/2 px (band %+v)", w, diff, f.Band)
		}
	}
}

// Every landscape band must produce an encodable (even, in-cap) frame whose
// aspect is 9:16 to within a pixel, across a dense sweep of window sizes.
func TestComputeBandFrameSweep(t *testing.T) {
	for h := 100; h <= 2400; h += 7 {
		for _, w := range []int{h + 1, h * 4 / 3, h * 16 / 9, h*16/9 + 1, h * 21 / 9} {
			f, ok := ComputeBandFrame(w, h)
			if !ok {
				t.Fatalf("ComputeBandFrame(%d,%d) not ok", w, h)
			}
			if !f.Banded {
				t.Fatalf("%dx%d is landscape but not banded", w, h)
			}
			if f.EncW%2 != 0 || f.EncH%2 != 0 {
				t.Fatalf("%dx%d: odd encode %dx%d", w, h, f.EncW, f.EncH)
			}
			if f.EncW > DesignW || f.EncH > DesignH {
				t.Fatalf("%dx%d: encode %dx%d exceeds the design cap", w, h, f.EncW, f.EncH)
			}
			if f.Band.X < 0 || f.Band.X+f.Band.W > w {
				t.Fatalf("%dx%d: band %+v leaves the window", w, h, f.Band)
			}
			// Aspect: bandW must be the nearest integer (either neighbor of a
			// tie) to h*9/16.
			lo, hi := (h*9)/16-1, (h*9)/16+1
			if f.Band.W < lo || f.Band.W > hi {
				t.Fatalf("%dx%d: band width %d not ~%d", w, h, f.Band.W, h*9/16)
			}
		}
	}
}

func TestComputeBandFrameDegenerate(t *testing.T) {
	for _, tc := range [][2]int{{0, 0}, {-4, 100}, {100, -4}, {8, 8}, {30, 15}, {15, 500}} {
		if _, ok := ComputeBandFrame(tc[0], tc[1]); ok {
			t.Errorf("ComputeBandFrame(%d,%d) must reject a degenerate rect", tc[0], tc[1])
		}
	}
	// A landscape window whose band would be under the minimum is rejected
	// even though the window itself is measurable.
	if _, ok := ComputeBandFrame(100, 20); ok {
		t.Errorf("100x20 band (11 px wide) must be rejected")
	}
}

func TestBandLayoutDescription(t *testing.T) {
	f, _ := ComputeBandFrame(3840, 2160)
	if got, want := BandLayoutDescription(3840, 2160, f), "center band 1215x2160 of 3840x2160 (encoded at 1080x1920)"; got != want {
		t.Errorf("4K description = %q, want %q", got, want)
	}
	f, _ = ComputeBandFrame(1280, 720)
	if got, want := BandLayoutDescription(1280, 720, f), "center band 405x720 of 1280x720 (encoded at 404x720)"; got != want {
		t.Errorf("720p description = %q, want %q", got, want)
	}
	f, _ = ComputeBandFrame(552, 984)
	if got, want := BandLayoutDescription(552, 984, f), "full window 552x984 (window is portrait — no band)"; got != want {
		t.Errorf("portrait description = %q, want %q", got, want)
	}
}

func TestRoundHalfToEven(t *testing.T) {
	tests := []struct{ num, den, want int }{
		{6480, 16, 405}, // exact
		{875, 2, 438},   // 437.5 -> 438 (even)
		{2625, 2, 1312}, // 1312.5 -> 1312 (even)
		{19440, 16, 1215},
		{7, 2, 4},  // 3.5 -> 4
		{5, 2, 2},  // 2.5 -> 2
		{9, 4, 2},  // 2.25 -> 2
		{11, 4, 3}, // 2.75 -> 3
		{0, 2, 0},
	}
	for _, tc := range tests {
		if got := roundHalfToEven(tc.num, tc.den); got != tc.want {
			t.Errorf("roundHalfToEven(%d,%d) = %d, want %d", tc.num, tc.den, got, tc.want)
		}
	}
}

// Out-of-contract inputs must panic loudly: on negative num, Go's truncating
// division and the Lua port's floor division diverge (and neither is banker's
// rounding), so silently returning a number would be a latent cross-component
// parity trap. ComputeBandFrame's degenerate-rect guard keeps such inputs
// unreachable in production.
func TestRoundHalfToEvenContractGuard(t *testing.T) {
	for _, tc := range [][2]int{{-24, 16}, {-1, 2}, {5, 0}, {5, -2}} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("roundHalfToEven(%d,%d) must panic (num >= 0, den > 0 contract)", tc[0], tc[1])
				}
			}()
			roundHalfToEven(tc[0], tc[1])
		}()
	}
}
