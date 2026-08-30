package window

import "testing"

func TestFitPortraitClientTypicalLandscapeMonitor(t *testing.T) {
	// 1920x1080 monitor, 48 px taskbar => 1920x1032 work area; conservative
	// decorations. Height-limited: h = 1032-48 = 984, w = floor(984*9/16) =
	// 553 -> even 552.
	w, h, ok := FitPortraitClient(1920, 1032, FallbackDecorationW, FallbackDecorationH)
	if !ok {
		t.Fatal("fit failed for a normal 1080p work area")
	}
	if w != 552 || h != 984 {
		t.Fatalf("got %dx%d, want 552x984", w, h)
	}
}

func TestFitPortraitClientFitsAndIsEven(t *testing.T) {
	cases := []struct{ workW, workH, dw, dh int }{
		{1920, 1032, 16, 48},
		{2560, 1392, 16, 48},
		{3840, 2112, 22, 66}, // scaled decorations on a 4K display (capped)
		{1366, 728, 16, 48},
		{1280, 987, 17, 49}, // odd work area / odd decorations
		{800, 1280, 16, 48}, // portrait monitor: width-limited
		{601, 1281, 15, 47},
	}
	for _, c := range cases {
		w, h, ok := FitPortraitClient(c.workW, c.workH, c.dw, c.dh)
		if !ok {
			t.Errorf("fit(%d,%d,%d,%d) unexpectedly failed", c.workW, c.workH, c.dw, c.dh)
			continue
		}
		if w%2 != 0 || h%2 != 0 {
			t.Errorf("fit(%d,%d): %dx%d not even", c.workW, c.workH, w, h)
		}
		if w+c.dw > c.workW || h+c.dh > c.workH {
			t.Errorf("fit(%d,%d,%d,%d): window %dx%d + decorations does not fit",
				c.workW, c.workH, c.dw, c.dh, w, h)
		}
		if w > DesignW || h > DesignH {
			t.Errorf("fit(%d,%d): %dx%d exceeds the %dx%d design cap",
				c.workW, c.workH, w, h, DesignW, DesignH)
		}
		if w == DesignW && h == DesignH {
			continue // capped: exactly the design aspect by construction
		}
		// Below the cap the fit is maximal, so the aspect is exact to within
		// one even-rounding step: the ideal counterpart dimension differs by
		// less than 2 px on whichever axis was the binding constraint.
		idealW := h * aspectW / aspectH
		idealH := w * aspectH / aspectW
		if !(idealW-w >= 0 && idealW-w < 2) && !(idealH-h >= 0 && idealH-h < 2) {
			t.Errorf("fit(%d,%d): %dx%d strays from 9:16 (ideal w %d / ideal h %d)",
				c.workW, c.workH, w, h, idealW, idealH)
		}
	}
}

func TestFitPortraitClientCapsAtDesignResolution(t *testing.T) {
	// A 4K monitor (field report) holds 1080x1920 with room to spare: the fit
	// must be EXACTLY the design resolution — never larger, which would only
	// raise encode cost for pixels the phone downscales anyway.
	cases := []struct{ workW, workH, dw, dh int }{
		{3840, 2112, 22, 66}, // 4K, 48 px taskbar, scaled decorations
		{3840, 2160, 16, 48}, // 4K, no taskbar
		{2560, 2112, 16, 48}, // 1440p rotated-adjacent tall work area
		{1096, 1968, 16, 48}, // exactly the design size + decorations
		{10000, 10000, 0, 0}, // absurdly large: still capped
	}
	for _, c := range cases {
		w, h, ok := FitPortraitClient(c.workW, c.workH, c.dw, c.dh)
		if !ok || w != DesignW || h != DesignH {
			t.Errorf("fit(%d,%d,%d,%d) = %dx%d ok=%v, want exactly %dx%d",
				c.workW, c.workH, c.dw, c.dh, w, h, ok, DesignW, DesignH)
		}
	}
	// One pixel short of holding the design window: the fit must shrink, not
	// round up past the work area.
	w, h, ok := FitPortraitClient(DesignW+16, DesignH+48-1, 16, 48)
	if !ok {
		t.Fatal("just-under-design work area must still fit")
	}
	if w == DesignW && h == DesignH {
		t.Fatalf("got the design size from a work area that cannot hold it")
	}
	if h > DesignH-1 || w+16 > DesignW+16 {
		t.Fatalf("%dx%d does not fit the just-under-design work area", w, h)
	}
}

func TestFitPortraitClientWidthLimited(t *testing.T) {
	// Portrait 800x1280 work area: width-limited. availW=784 -> w=784,
	// h = floor(784*16/9) = 1393 -> exceeds availH? availH = 1232, so
	// h clamps back to even availH... verify both dimensions fit.
	w, h, ok := FitPortraitClient(800, 1280, FallbackDecorationW, FallbackDecorationH)
	if !ok {
		t.Fatal("portrait work area must fit")
	}
	if w+FallbackDecorationW > 800 || h+FallbackDecorationH > 1280 {
		t.Fatalf("%dx%d does not fit 800x1280 minus decorations", w, h)
	}
	// availH=1232 is the binding constraint after the width re-fit clamp is
	// checked; whichever branch wins, height may not exceed it.
	if h > 1232 {
		t.Fatalf("height %d exceeds available 1232", h)
	}
}

func TestFitPortraitClientTinyOrDegenerateMonitors(t *testing.T) {
	cases := []struct{ workW, workH int }{
		{0, 0},
		{-100, 1080},
		{320, 240},  // ancient / misreported
		{200, 2000}, // too narrow for the 270 px minimum width
		{2000, 400}, // too short for the 480 px minimum height
		{16, 48},    // exactly the decoration size: zero client area
	}
	for _, c := range cases {
		if w, h, ok := FitPortraitClient(c.workW, c.workH, FallbackDecorationW, FallbackDecorationH); ok {
			t.Errorf("fit(%d,%d) = %dx%d, want failure for an unusable work area",
				c.workW, c.workH, w, h)
		}
	}
}

func TestFitPortraitClientHugeDecorations(t *testing.T) {
	// Decorations larger than the work area must fail, not go negative.
	if _, _, ok := FitPortraitClient(1920, 1080, 2000, 2000); ok {
		t.Fatal("decorations exceeding the work area must fail the fit")
	}
	// Larger decorations shrink the result monotonically.
	w1, h1, _ := FitPortraitClient(1920, 1032, 0, 0)
	w2, h2, _ := FitPortraitClient(1920, 1032, 40, 120)
	if w2 > w1 || h2 > h1 {
		t.Fatalf("bigger decorations grew the fit: %dx%d -> %dx%d", w1, h1, w2, h2)
	}
}
