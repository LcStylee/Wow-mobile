package window

import (
	"strings"
	"testing"
)

func TestBandBasisCheck(t *testing.T) {
	tests := []struct {
		name                         string
		liveW, liveH, basisW, basisH int
		wantMsg                      bool     // any message expected?
		wantWarn                     bool     // ... and is it a warning (vs an informational note)?
		contains                     []string // substrings the message must carry
	}{
		{
			name:  "identical sizes agree",
			liveW: 3840, liveH: 2160, basisW: 3840, basisH: 2160,
			wantMsg: false,
		},
		{
			// The v0.4.0 field case: wizard wrote the 4K desktop into
			// gxResolution, the window is maximized above the taskbar — a
			// different ASPECT. An up-to-date addon detects exactly this
			// (Band.lua ClientPixels' 0.4% aspect gate) and derives its basis
			// from the live aspect instead, landing its band 1164@1338 — the
			// same rect the server crops — so the user who runs the primary
			// field configuration must NOT stare at a scary warning on a
			// pixel-perfect stream. The stale CVar is still worth an
			// informational note (it names the pre-band-layout addon as the
			// only case that needs action).
			name:  "4K desktop basis vs maximized-with-taskbar live is an informational note",
			liveW: 3840, liveH: 2069, basisW: 3840, basisH: 2160,
			wantMsg: true, wantWarn: false,
			contains: []string{
				"gxResolution is stale", "3840x2160", "3840x2069",
				"no action is needed", "pre-v0.4.x", "re-run the wizard",
			},
		},
		{
			// A couple of rows of height difference moves the band ≤ tolerance:
			// basis band 1214 wide at x=1313 vs live 1215 at x=1312 — no alarm.
			name:  "sub-tolerance disagreement stays quiet",
			liveW: 3840, liveH: 2160, basisW: 3840, basisH: 2158,
			wantMsg: false,
		},
		{
			// Same aspect within the addon's 0.4% gate (rel = 3855/3840 ≈
			// 1.0039), so the addon trusts the CVar verbatim — and its
			// fraction-mapped band (1210 wide at x=1315) really sits 5 px off
			// the live crop (1215 at x=1312): the one genuine warning left.
			name:  "same-aspect basis past the pixel tolerance warns",
			liveW: 3840, liveH: 2160, basisW: 3855, basisH: 2160,
			wantMsg: true, wantWarn: true,
			contains: []string{
				"band basis mismatch", "gxResolution 3855x2160",
				"band 1215x2160 at x=1312", "re-run the wizard",
			},
		},
		{
			name:  "portrait live window is full-window mode, no basis check",
			liveW: 1080, liveH: 1920, basisW: 3840, basisH: 2160,
			wantMsg: false,
		},
		{
			// A portrait basis against a landscape live rect diverges in
			// aspect by construction, so the up-to-date addon gx-derives a
			// landscape basis and matches the crop — informational only.
			name:  "portrait basis vs landscape live is an informational note",
			liveW: 1920, liveH: 1080, basisW: 1080, basisH: 1920,
			wantMsg: true, wantWarn: false,
			contains: []string{"gxResolution is stale", "1080x1920", "1920x1080"},
		},
		{
			// Near-square corner: a portrait basis whose aspect still passes
			// the 0.4% gate (rel ≈ 0.998) — the addon uses the CVar verbatim
			// and lays out FULL-window while the stream crops a band, a real
			// mis-frame.
			name:  "near-square portrait basis inside the aspect gate warns",
			liveW: 1000, liveH: 999, basisW: 999, basisH: 1000,
			wantMsg: true, wantWarn: true,
			contains: []string{
				"gxResolution is 999x1000 (portrait", "1000x999",
				"562x999 band at x=219",
			},
		},
		{
			name:  "degenerate basis stays quiet",
			liveW: 1920, liveH: 1080, basisW: 0, basisH: 0,
			wantMsg: false,
		},
		{
			name:  "degenerate live rect stays quiet",
			liveW: 0, liveH: 0, basisW: 3840, basisH: 2160,
			wantMsg: false,
		},
		{
			// Same aspect, different size: the band scales with the window and
			// its client-local placement genuinely differs (960x540 band
			// 304@328 vs 1920x1080 band 608@656) — the addon's fractional
			// layout survives a uniform rescale of the SAME aspect, so no
			// user-visible cut exists and pure scaling must not report at all.
			name:  "uniform rescale of the same aspect stays quiet",
			liveW: 1920, liveH: 1080, basisW: 960, basisH: 540,
			wantMsg: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg, warn := BandBasisCheck(tt.liveW, tt.liveH, tt.basisW, tt.basisH)
			if (msg != "") != tt.wantMsg {
				t.Fatalf("BandBasisCheck(%d,%d, %d,%d) = %q; want message=%v",
					tt.liveW, tt.liveH, tt.basisW, tt.basisH, msg, tt.wantMsg)
			}
			if warn != tt.wantWarn {
				t.Fatalf("BandBasisCheck(%d,%d, %d,%d) warn = %v (msg %q); want %v",
					tt.liveW, tt.liveH, tt.basisW, tt.basisH, warn, msg, tt.wantWarn)
			}
			for _, sub := range tt.contains {
				if !strings.Contains(msg, sub) {
					t.Errorf("message %q missing %q", msg, sub)
				}
			}
		})
	}
}
