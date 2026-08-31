package window

import "testing"

// Style fixtures: a plain windowed WoW (WS_OVERLAPPEDWINDOW), a fullscreen
// surface (WS_POPUP, no caption), and modifier bits.
const (
	styleWindowed   = uint32(0x00CF0000) // WS_OVERLAPPEDWINDOW: caption + thickframe + sysmenu
	styleFullscreen = StylePopup
)

func TestEnforceDecisionWindowedVsNot(t *testing.T) {
	noApply := func(int) error { t.Fatal("apply must not run for skips"); return nil }
	noMeasure := func() (int, int, bool) { t.Fatal("measure must not run for skips"); return 0, 0, false }

	cases := []struct {
		name  string
		style uint32
		want  EnforceOutcome
	}{
		{"fullscreen popup is never resized", styleFullscreen, EnforceSkipFullscreen},
		{"maximized is never resized", styleWindowed | StyleMaximize, EnforceSkipMaximized},
		{"minimized has no meaningful rect", styleWindowed | StyleMinimize, EnforceSkipMinimized},
		// A popup that still carries a full caption behaves windowed; it must
		// NOT be classified fullscreen (some frameworks set both).
		{"captioned popup counts as windowed", styleWindowed | StylePopup, EnforceResized},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			apply, measure := noApply, noMeasure
			if tc.want == EnforceResized {
				apply = func(int) error { return nil }
				measure = func() (int, int, bool) { return 540, 960, true }
			}
			got := EnforceClientSizeWith(tc.style, 800, 600, 540, 960, apply, measure)
			if got != tc.want {
				t.Errorf("style %#x: outcome = %v, want %v", tc.style, got, tc.want)
			}
		})
	}
}

func TestEnforceMismatchThreshold(t *testing.T) {
	// Differences within the tolerance are left alone — DPI/frame rounding
	// must never start a resize fight the client re-rounds right back.
	applied := false
	apply := func(int) error { applied = true; return nil }
	measure := func() (int, int, bool) { return 0, 0, true }
	got := EnforceClientSizeWith(styleWindowed, 540+ResizeTolerancePx, 960-ResizeTolerancePx, 540, 960, apply, measure)
	if got != EnforceAlready || applied {
		t.Errorf("within-tolerance mismatch: outcome=%v applied=%v, want already-sized and no apply", got, applied)
	}
	// One pixel beyond tolerance IS a mismatch.
	measure = func() (int, int, bool) { return 540, 960, true }
	if got := EnforceClientSizeWith(styleWindowed, 540+ResizeTolerancePx+1, 960, 540, 960, apply, measure); got != EnforceResized {
		t.Errorf("beyond-tolerance mismatch: outcome=%v, want resized", got)
	}
}

func TestEnforceRetryOnce(t *testing.T) {
	// The client re-asserts its own size after the first SetWindowPos (known
	// 1.12 behavior); the second attempt sticks.
	applies := 0
	apply := func(attempt int) error {
		if attempt != applies {
			t.Errorf("attempt = %d, want %d", attempt, applies)
		}
		applies++
		return nil
	}
	sizes := [][2]int{{800, 600}, {540, 960}} // after 1st apply: reverted; after 2nd: ok
	measures := 0
	measure := func() (int, int, bool) {
		s := sizes[measures]
		measures++
		return s[0], s[1], true
	}
	if got := EnforceClientSizeWith(styleWindowed, 800, 600, 540, 960, apply, measure); got != EnforceResized {
		t.Errorf("outcome = %v, want resized after the retry", got)
	}
	if applies != 2 || measures != 2 {
		t.Errorf("applies=%d measures=%d, want 2 and 2 (exactly one retry)", applies, measures)
	}

	// The game wins both rounds: report reverted, never keep fighting.
	applies = 0
	apply2 := func(int) error { applies++; return nil }
	measure2 := func() (int, int, bool) { return 800, 600, true }
	if got := EnforceClientSizeWith(styleWindowed, 800, 600, 540, 960, apply2, measure2); got != EnforceReverted {
		t.Errorf("outcome = %v, want reverted", got)
	}
	if applies != 2 {
		t.Errorf("applies = %d, want exactly 2 (one retry, then give up)", applies)
	}
}

func TestEnforceFailurePaths(t *testing.T) {
	boom := func(int) error { return errTest }
	measure := func() (int, int, bool) { return 0, 0, true }
	if got := EnforceClientSizeWith(styleWindowed, 800, 600, 540, 960, boom, measure); got != EnforceFailed {
		t.Errorf("apply error: outcome = %v, want failed", got)
	}
	apply := func(int) error { return nil }
	badMeasure := func() (int, int, bool) { return 0, 0, false }
	if got := EnforceClientSizeWith(styleWindowed, 800, 600, 540, 960, apply, badMeasure); got != EnforceFailed {
		t.Errorf("measure failure: outcome = %v, want failed", got)
	}
}

var errTest = errFixed("boom")

type errFixed string

func (e errFixed) Error() string { return string(e) }

func TestClampOrigin(t *testing.T) {
	work := Rect{X: 0, Y: 0, W: 1920, H: 1040} // 1080p minus a 40 px taskbar
	cases := []struct {
		name         string
		x, y, ow, oh int
		wantX, wantY int
	}{
		{"fits where it is", 100, 30, 560, 1000, 100, 30},
		{"pushed past the right/bottom edge", 1800, 900, 560, 1000, 1920 - 560, 1040 - 1000},
		{"off the left/top", -50, -20, 560, 1000, 0, 0},
		{"taller than the work area pins to top", 300, 200, 560, 1200, 300, 0},
		{"wider than the work area pins to left", 300, 20, 2200, 800, 0, 20},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			x, y := ClampOrigin(tc.x, tc.y, tc.ow, tc.oh, work)
			if x != tc.wantX || y != tc.wantY {
				t.Errorf("ClampOrigin = (%d,%d), want (%d,%d)", x, y, tc.wantX, tc.wantY)
			}
		})
	}

	// Secondary monitor: the work area's own origin (not 0,0) is the floor.
	work2 := Rect{X: 1920, Y: 100, W: 1080, H: 1820}
	if x, y := ClampOrigin(0, 0, 560, 1000, work2); x != 1920 || y != 100 {
		t.Errorf("secondary-monitor clamp = (%d,%d), want (1920,100)", x, y)
	}
}

func TestSizeMatches(t *testing.T) {
	if !SizeMatches(540, 960, 540, 960) || !SizeMatches(542, 958, 540, 960) {
		t.Error("exact and within-tolerance sizes must match")
	}
	if SizeMatches(543, 960, 540, 960) || SizeMatches(540, 963, 540, 960) {
		t.Error("beyond-tolerance sizes must not match")
	}
}
