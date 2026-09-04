// Band-BASIS diagnostics (band layout). The server crops the band from the
// LIVE client rect, but the addon computes ITS copy of the band from the
// physical client size the game exposes to Lua — on a 1.12-engine client that
// starts from the gxResolution CVar (Config.wtf), the only physical-size
// source the engine offers. The CVar is the CONFIGURED video mode, not the
// live client area: the classic divergence is a wizard-written desktop-sized
// gxResolution (3840x2160) with the window maximized above the taskbar
// (client area 3840x~2069) — a different aspect (v0.4.0 field report: the
// unit frame name "Wowmobile" reading "bile").
//
// The addon defends itself (Band.lua ClientPixels, the CHOSEN BASIS): it
// cross-checks the CVar's aspect against the live window's (UIParent is
// aspect-exact) within 0.4%. On a match it uses the CVar verbatim; on a
// divergence it falls back to a "gx-derived" basis — the CVar's width with
// the height re-derived from the live aspect — whose band FRACTIONS of the
// window match the server's crop of the live rect by construction. So a
// stale gxResolution alone no longer mis-places an up-to-date addon's UI;
// BandBasisCheck mirrors the addon's choice and reports accordingly: an
// informational stale-CVar note for the aspect-divergence case (auto-
// compensated; only a pre-band-layout addon would still sit shifted), and a
// genuine warning only when even the chosen basis lands the band off the
// live crop. The comparison is pure math over the two sizes so it tests
// everywhere; callers supply the live rect and the Config.wtf value and
// surface the result once per capture (re)launch.
package window

import "fmt"

// BandBasisTolerancePx is the band displacement (x or width, client pixels)
// below which a live-rect/gxResolution disagreement is not worth a warning:
// a shift this small cannot visibly cut addon UI, and rounding differences
// between near-identical sizes must not raise a permanent false alarm.
const BandBasisTolerancePx = 4

// bandBasisAspectTolerance mirrors Band.lua ClientPixels' aspect gate
// VERBATIM (rel strictly inside (1-tol, 1+tol) selects the CVar): the addon
// trusts gxResolution as-is only when its aspect is within 0.4% of the live
// window's, and otherwise derives its basis from the live aspect. Changing
// either side alone would desynchronize this diagnostic from the addon's
// actual layout choice.
const bandBasisAspectTolerance = 0.004

// BandBasisCheck compares the band the stream crops (from the live client
// area liveW x liveH) against the band an up-to-date addon lays out from the
// gxResolution basis basisW x basisH, mirroring the addon's chosen-basis
// logic (Band.lua ClientPixels — see the package comment). It returns
// msg == "" when there is nothing to report — the sizes agree, the live
// window is not banded, or either size is degenerate. A non-empty msg with
// warn == false is an informational stale-gxResolution note: the CVar
// disagrees with the live window but the addon compensates automatically, so
// the stream still lines up (only an addon predating the band layout would
// not — the note says so). warn == true marks the rare genuine mismatch:
// the addon's chosen basis still places the band beyond
// BandBasisTolerancePx of the live crop, so its UI really sits shifted/cut
// at the stream's band edges; msg is one dashboard-ready line naming both
// placements and the fix.
func BandBasisCheck(liveW, liveH, basisW, basisH int) (msg string, warn bool) {
	live, ok := ComputeBandFrame(liveW, liveH)
	if !ok || !live.Banded {
		// Portrait or degenerate live window: full-window mode — the band
		// layout reporter already calls that out; no basis to compare.
		return "", false
	}
	if liveW == basisW && liveH == basisH {
		return "", false
	}
	basis, ok := ComputeBandFrame(basisW, basisH)
	if !ok {
		return "", false // no credible basis (absent/garbage gxResolution): stay quiet
	}
	// The addon's aspect gate, mirrored: outside it the addon discards the
	// CVar's height and derives its basis from the live aspect
	// ("gx-derived"), so its band fractions — and hence its on-screen band —
	// match the server's crop of the live rect by construction. Not a
	// mis-frame, just a stale CVar worth an informational note.
	rel := (float64(basisW) * float64(liveH)) / (float64(basisH) * float64(liveW))
	if !(rel > 1-bandBasisAspectTolerance && rel < 1+bandBasisAspectTolerance) {
		return fmt.Sprintf(
			"gxResolution is stale: Config.wtf says %dx%d but the live client area is %dx%d — a different aspect "+
				"(typically the window is maximized above the taskbar). An up-to-date WowMobile addon detects this and "+
				"lays its band out from the live window, so the stream and the addon UI still line up and no action is "+
				"needed. Only an addon predating the band layout (pre-v0.4.x) mis-places its UI here — if the addon UI "+
				"looks cut at the stream's left/right edges, re-run the wizard and /reload. To refresh the CVar itself, "+
				"close WoW fully, re-run the wizard, and restart WoW (a maximized window keeps its own size).",
			basisW, basisH, liveW, liveH), false
	}
	fix := "close WoW fully and re-run the wizard, restart WoW so gxResolution applies " +
		"(a maximized window keeps its own size — un-maximize it first), or resize the game window to match gxResolution"
	if !basis.Banded {
		// Reachable only for near-square windows (a portrait basis whose
		// aspect still passes the 0.4% gate against a landscape live rect):
		// the addon trusts the CVar verbatim and lays out FULL-window while
		// the stream crops a band.
		return fmt.Sprintf(
			"band basis mismatch: Config.wtf gxResolution is %dx%d (portrait — the addon lays its UI out full-window), "+
				"but the live client area is %dx%d and the stream crops its centered %dx%d band at x=%d, "+
				"so the addon UI will not line up with the stream. Fix: %s.",
			basisW, basisH, liveW, liveH, live.Band.W, live.Band.H, live.Band.X, fix), true
	}
	// Same aspect (within the gate): the addon uses the CVar verbatim and
	// positions UI as FRACTIONS of the window (UIParent spans the client area
	// whatever gxResolution claims), so map its band into the live window's
	// pixel space before comparing. A basis that is a pure uniform rescale of
	// the live size predicts the SAME on-screen band and stays quiet; only a
	// residual sub-0.4%-aspect skew large enough to move the band past the
	// pixel tolerance warns.
	predX := roundHalfToEven(basis.Band.X*liveW, basisW)
	predW := roundHalfToEven(basis.Band.W*liveW, basisW)
	if absInt(live.Band.X-predX) <= BandBasisTolerancePx && absInt(live.Band.W-predW) <= BandBasisTolerancePx {
		return "", false
	}
	return fmt.Sprintf(
		"band basis mismatch: the addon likely laid its UI out for gxResolution %dx%d (band %dx%d at x=%d), "+
			"but the live client area is %dx%d, so the stream crops band %dx%d at x=%d — "+
			"the addon UI will look shifted or cut at the stream's left/right edges. Fix: %s.",
		basisW, basisH, basis.Band.W, basis.Band.H, basis.Band.X,
		liveW, liveH, live.Band.W, live.Band.H, live.Band.X, fix), true
}

// absInt is |x| for the small band deltas above (never near MinInt).
func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
