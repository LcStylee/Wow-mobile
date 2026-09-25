package window

import "testing"

// The shared snap of the frame contract (the Lua, JS and generator ports
// must agree on every exact half).
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
// parity trap. ComputePhoneFrame's degenerate-rect guard keeps such inputs
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
