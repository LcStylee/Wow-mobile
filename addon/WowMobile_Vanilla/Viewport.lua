--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Viewport
-- Shrinks the 3D world (WorldFrame) to a square anchored to the top of the
-- 9:16 band (the full window in portrait mode, the centered landscape band
-- otherwise — Band.lua; band layout is the server default on 1.12) and
-- paints a black backdrop over the band region below it — the "control deck"
-- that owns all primary UI. In landscape mode the world OUTSIDE the band is
-- deliberately not rendered: WorldFrame is sized to the band-width square,
-- and Band.lua's side rails black out the rest of the window.
--
-- Publishes:
--   WM.WorldSquare — frame exactly covering the world region, used as the
--                    anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--   WM.Viewport.GetStatus() — live world-rect fractions for /wm status.
--
-- WorldFrame geometry manipulation is the classic 1.12 "viewport" technique
-- (CT_Viewport/SunnArt-style). WorldFrame does not inherit uiScale from
-- UIParent, and — field evidence v0.4.0, OctoWow 1.18 — GetEffectiveScale()
-- can outright LIE on vanilla-plus builds (the world rendered at exactly
-- uiScale 0.8 of the band width, leaving an engine-WHITE strip). So no size
-- or offset here is ever converted through an effective scale. Instead the
-- proven 1.12 idiom: re-anchor WorldFrame to span the FULL window (anchors
-- resolve in absolute screen space, so SetPoint with zero offsets is exact
-- whatever any scale claims), measure that full-window rect in WorldFrame's
-- OWN units, and place the band as FRACTIONS of it — fractions need no scale
-- conversion at all.
--------------------------------------------------------------------------------

local WM = WowMobile

local Viewport = {}
WM.Viewport = Viewport

-- Anchor/overlay for the world region. Mouse-disabled: world taps must reach
-- WorldFrame (targeting, camera) untouched. Anchored to the band frame — NOT
-- UIParent — which is what carries the square (and everything hanging off it)
-- into the centered band in landscape mode; in portrait mode the band frame
-- covers the whole window and this is identical to the pre-band layout.
local bandHost = WM.BandFrame or UIParent -- Band.lua loads first; nil-guard mirrors Core's crash-tolerance style
local square = CreateFrame("Frame", "WowMobileWorldSquare", UIParent)
square:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
square:SetPoint("TOPRIGHT", bandHost, "TOPRIGHT", 0, 0)
square:SetHeight(WM.Px(1080))
square:SetFrameStrata("BACKGROUND")
square:EnableMouse(false)
WM.WorldSquare = square

-- Black backdrop behind everything below the square, spanning the band. The
-- deck's flat 2D look is also what keeps the H.264 encoder cheap there.
local backdrop = CreateFrame("Frame", "WowMobileDeckBackdrop", UIParent)
backdrop:SetPoint("TOPLEFT", square, "BOTTOMLEFT", 0, 0)
backdrop:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
backdrop:SetFrameStrata("BACKGROUND")
backdrop:SetFrameLevel(0)
backdrop:EnableMouse(false)
local black = backdrop:CreateTexture(nil, "BACKGROUND")
black:SetAllPoints(backdrop)
black:SetTexture(0, 0, 0, 1)
WM.DeckBackdrop = backdrop

--------------------------------------------------------------------------------
-- Gap shims — NO ENGINE-WHITE ANYWHERE (field evidence v0.4.0)
-- On 1.12 a window region covered by NEITHER WorldFrame NOR an addon texture
-- renders engine-WHITE (and an unset texture renders white too — hence flat
-- SetTexture(0,0,0,1) fills everywhere). The deck backdrop above covers the
-- band below the SQUARE, and Band.lua's rails cover outside the band — but
-- both anchor to the addon's INTENDED geometry. If WorldFrame's ACTUAL rect
-- ever disagrees (the lying-scale field failure: world at 80% of the band,
-- white strip on the right), the gap between the world's real edge and the
-- band showed bare engine. These four shims anchor to WorldFrame's LIVE
-- edges on one side and the band frame on the other, so ANY future gap
-- between the real world rect and the band is black, never white — they are
-- zero-area (invisible, zero cost) whenever the world exactly fills the
-- square. BACKGROUND strata level 0: below every UI surface, above only the
-- 3D world itself, which by construction they never overlap.
--------------------------------------------------------------------------------

local function CreateShim(name)
	local shim = CreateFrame("Frame", name, UIParent)
	shim:SetFrameStrata("BACKGROUND")
	shim:SetFrameLevel(0)
	shim:EnableMouse(false)
	local tex = shim:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints(shim)
	tex:SetTexture(0, 0, 0, 1)
	return shim
end

-- Right of the world's real right edge, down the full band height.
local shimRight = CreateShim("WowMobileWorldShimRight")
shimRight:SetPoint("TOPLEFT", WorldFrame, "TOPRIGHT", 0, 0)
shimRight:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
-- Left of the world's real left edge (a band whose left edge the world
-- misses), down the FULL band height — mirroring shimRight, so the corner
-- below a world that is both narrower than the band and shifted right of its
-- left edge is covered too (the overlap with shimBelow/deck backdrop is
-- harmless: all opaque black).
local shimLeft = CreateShim("WowMobileWorldShimLeft")
shimLeft:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
shimLeft:SetPoint("BOTTOMLEFT", bandHost, "BOTTOMLEFT", 0, 0)
shimLeft:SetPoint("RIGHT", WorldFrame, "LEFT", 0, 0)
-- Between the world's real bottom edge and the band bottom (overlaps the
-- deck backdrop harmlessly — both opaque black).
local shimBelow = CreateShim("WowMobileWorldShimBelow")
shimBelow:SetPoint("TOPLEFT", WorldFrame, "BOTTOMLEFT", 0, 0)
shimBelow:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
-- Above the world's real top edge (should never exist — world anchors to the
-- window top — but belt and braces).
local shimTop = CreateShim("WowMobileWorldShimTop")
shimTop:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
shimTop:SetPoint("BOTTOMRIGHT", WorldFrame, "TOPRIGHT", 0, 0)

-- viewport.height is design px of the 1080-wide window (default 1080); as a
-- fraction of the design width it scales to any real capture resolution.
function Viewport.HeightPx()
	return (WM.db and WM.db.viewport and WM.db.viewport.height) or 1080
end

-- World-square overlays whose layout depends on the configurable square
-- height register here; callbacks receive the square height in design px and
-- must be idempotent (Apply re-runs on login, /wm viewport, world entry).
local reflowers = {}

function Viewport.OnApply(fn)
	table.insert(reflowers, fn)
end

-- The BAND rect in UI units at call time: left offset from UIParent's left
-- edge, and width. Full window when Band.lua is unavailable (its failure is
-- already bannered by the crash guard) — exactly the pre-band behavior.
local function BandRect()
	local band = WM.Band
	if band and band.width then
		return band.left or 0, band.width
	end
	return 0, UIParent:GetWidth()
end

-- The intended square height in UI units, derived ONLY from live
-- measurements taken at call time: the BAND's width (scale-free — a design
-- ratio of 1.0 means "square = band width", true at any resolution and any
-- effective scale; the full window width in portrait mode) capped so the
-- fixed deck stack still fits below it. Because a landscape band is 9:16 by
-- construction, the cap only engages on a portrait window too short for the
-- deck, or on a stale over-tall configured height (a landscape window
-- without the cap was the "world stretched across the whole screen" field
-- failure — Band.lua now owns that case); the caller reports a real clamp.
-- Returns heightUI, clamped(boolean), exact(boolean); clamped is true only
-- for a MEANINGFUL overshoot: Config.HeightBounds advertises whole design px
-- (and float math adds noise), so a height configured exactly at the
-- advertised bound can exceed the true geometric max by a sub-pixel amount on
-- a fully legitimate window — that is shaved silently, never reported. exact
-- is true when the clamp did not engage at all, i.e. heightUI is precisely
-- the configured height (lets Apply hand reflowers the configured integer
-- verbatim instead of a float roundtrip).
local function ComputeHeightUI()
	local _, bandW = BandRect()
	local ratio = Viewport.HeightPx() / 1080
	local heightUI = bandW * ratio
	local deckFixed = (WM.Config and WM.Config.DECK_FIXED_PX) or 790
	-- The deck budget as a PURE measurement — design px resolved as fractions
	-- of the MEASURED band width, never via WM.Px: its cached pxFactor is
	-- deliberately not refreshed on drift, and this function must clamp
	-- correctly whatever that factor holds (CheckLayoutFresh's emergency
	-- re-apply runs exactly when the factor is stale). The band spans the
	-- full window height in both modes, so UIParent's height is the budget.
	local maxUI = UIParent:GetHeight() - bandW * (deckFixed / 1080)
	if maxUI < UIParent:GetHeight() * 0.25 then
		maxUI = UIParent:GetHeight() * 0.25 -- degenerate window: keep SOME world
	end
	if heightUI > maxUI then
		if heightUI > maxUI + bandW * (2 / 1080) then
			return maxUI, true, false -- real shape mismatch: caller raises the banner
		end
		return maxUI, false, false -- rounding/float overshoot (< 2 design px): silent
	end
	return heightUI, false, true
end

--------------------------------------------------------------------------------
-- Full-window measurement — the scale-proof basis of every WorldFrame number
--------------------------------------------------------------------------------

-- WorldFrame's full-window rect in ITS OWN coordinate units, (re)measured by
-- anchoring it edge-to-edge to UIParent first: anchor points resolve in
-- absolute screen space (zero offsets involve no unit conversion), so after
-- SetPoint TOPLEFT+BOTTOMRIGHT the frame spans the client area EXACTLY —
-- whatever either GetEffectiveScale() claims. GetLeft/GetRight then read that
-- rect back in WF units, which is the ground-truth "how many WF units are
-- the full window" ratio the band fractions multiply. Re-measured on every
-- Apply (scale/resolution changes alter the ratio) — the reset+measure+apply
-- sequence runs inside one frame, so nothing white ever reaches the screen.
-- .ok is false only when the rect did not resolve synchronously; then the
-- last resort is the old effective-scale conversion (the exact API this
-- module exists to distrust) and Verify reports that it cannot vouch.
local wfFull = { ok = false }
local measureRetries = 0
-- The band width Apply last handed SetWidth, in WF units: the second,
-- shape-independent stale-rect check below compares fresh measurements
-- against it.
local lastAppliedWF = nil

local function MeasureFullWorldFrame()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
	local l, r = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local t, b = WorldFrame:GetTop(), WorldFrame:GetBottom()
	if l and r and t and b and r > l and t > b then
		-- Guard against a STALE rect read: a client that resolves anchor
		-- changes lazily could hand back the PREVIOUS (band-sized) rect,
		-- which would poison the fraction basis as silently as the lying
		-- scale did. Two independent checks:
		-- 1. Aspect: the full-window rect's aspect must match UIParent's
		--    live aspect (same window, uniform scale). A stale SQUARE rect
		--    is ~1:1 and fails this in BOTH modes (portrait windows are
		--    taller than square, landscape wider), routing to the bounded
		--    retry + reported fallback below — the intended safe degradation.
		-- 2. Width: in landscape the band is strictly narrower than the
		--    window, so a genuine full-window rect must be meaningfully
		--    wider than the band rect last applied; this rejects every
		--    stale-band shape even on a near-square landscape window the
		--    aspect gate alone could miss. (Portrait band == full window:
		--    skipped, equality is right there.)
		local rel = ((r - l) / (t - b)) / (UIParent:GetWidth() / UIParent:GetHeight())
		if rel > 0.995 and rel < 1.005 then
			local _, bandW = BandRect()
			local narrowBand = bandW < UIParent:GetWidth() * 0.995
			if not (narrowBand and lastAppliedWF and (r - l) <= lastAppliedWF * 1.001) then
				wfFull.left, wfFull.top = l, t
				wfFull.width, wfFull.height = r - l, t - b
				wfFull.ok = true
				return
			end
		end
	end
	-- Rect unresolved or stale: last resort is the effective-scale
	-- conversion (the exact API the fraction path exists to distrust).
	-- Apply schedules a bounded retry, and Verify reports if this sticks.
	local toWF = UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
	wfFull.left, wfFull.top = nil, nil
	wfFull.width = UIParent:GetWidth() * toWF
	wfFull.height = UIParent:GetHeight() * toWF
	wfFull.ok = false
end

local badShapeReported = false
local lastClamped = false
local verifyQueued = false

function Viewport.Apply()
	local heightUI, clamped, exact = ComputeHeightUI()
	-- What the overlays must lay out against: the square that actually
	-- applied, expressed in design px. When the clamp did not engage this is
	-- the configured height passed through VERBATIM — the float roundtrip
	-- heightUI * 1080 / width can land 1 ulp low, and integer-sensitive
	-- reflowers (QuickBar's floor((h - 328) / 104)) would silently drop a
	-- slot at exact-fit heights (744/848/952/1056). Only a clamped/shaved
	-- square back-computes from what actually applied.
	local bandLeft, bandW = BandRect()
	local heightPx
	if exact then
		heightPx = Viewport.HeightPx()
	else
		heightPx = heightUI * 1080 / bandW
	end
	-- Band rect as FRACTIONS of the window (UI units over UI units — the
	-- scale cancels), multiplied onto the freshly measured full-window rect
	-- in WorldFrame's OWN units. No effective scale anywhere: the same WF
	-- unit that measured the full window expresses the offsets/sizes below,
	-- so a client that misreports its scale chain cannot shrink the world
	-- (the v0.4.0 white-strip failure: toWF poisoned by a lying
	-- GetEffectiveScale left the world at uiScale-sized 80% of the band).
	-- In landscape mode WorldFrame covers only the band (width set
	-- explicitly, no TOPRIGHT anchor); shims + side rails black out the rest.
	local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
	MeasureFullWorldFrame()
	local leftWF = wfFull.width * (bandLeft / uiW)
	local widthWF = wfFull.width * (bandW / uiW)
	local heightWF = wfFull.height * (heightUI / uiH)
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", leftWF, 0)
	WorldFrame:SetWidth(widthWF)
	WorldFrame:SetHeight(heightWF)
	lastAppliedWF = widthWF
	square:SetHeight(heightUI)
	lastClamped = clamped
	if clamped and not badShapeReported then
		badShapeReported = true
		-- The advice must match what the wizard actually ships: landscape
		-- windows are the band-layout DEFAULT on 1.12 (never a shape error —
		-- Band.lua crops them), so a real clamp means one of the cases below.
		local hint
		local band = WM.Band
		if band and band.mode == "band" then
			hint = "the 9:16 band cannot fit a world square this tall above the deck"
				.. " — lower /wm viewport (or /wm reset), then reload"
		elseif band then
			hint = "landscape windows are handled by the 9:16 band automatically, so this"
				.. " portrait window is too short for the deck — re-run the server wizard"
				.. " to restore a supported window size, then reload"
		else
			hint = "the band module is unavailable (see /wm errors), so a landscape window"
				.. " cannot be cropped — re-run the server wizard, then reload"
		end
		WM.ReportError(string.format(
			"Viewport.lua: window shape cannot fit the configured world square"
				.. " (%.0fx%.0f UI units) — square clamped; %s",
			UIParent:GetWidth(), UIParent:GetHeight(), hint))
		WM.ShowSetupBanner("The WoW window cannot fit the WoW Mobile layout at full size.", "shape")
	end
	for i = 1, table.getn(reflowers) do
		reflowers[i](heightPx)
	end
	-- Self-heal: a failed full-window measurement placed the world via the
	-- untrusted scale fallback — re-run Apply once the client has settled a
	-- layout pass (bounded, so an ever-failing client cannot loop forever;
	-- Verify then reports the standing fallback).
	if not wfFull.ok and measureRetries < 3 then
		measureRetries = measureRetries + 1
		WM.After(0.2, Viewport.Apply)
	elseif wfFull.ok then
		measureRetries = 0
	end
	-- Self-verification: measure what actually ended up on screen shortly
	-- after (geometry settles within a frame or two). One pending check at a
	-- time — Apply re-runs on login/world-entry/setting changes.
	if not verifyQueued then
		verifyQueued = true
		WM.After(0.5, function()
			verifyQueued = false
			Viewport.Verify()
		end)
	end
end

-- Measure WorldFrame's ACTUAL rect against the intended band fractions — in
-- WorldFrame's OWN units against the cached full-window measurement, the
-- SAME scale-free basis Apply placed it with. The old check converted both
-- sides through GetEffectiveScale(), so a client whose scale chain lies
-- (v0.4.0) poisoned Apply and Verify IDENTICALLY and the check false-passed
-- a world at 80% width. Any mismatch now — a client that reset WorldFrame
-- behind our back, SetWidth silently refused, anchors dropped — is recorded
-- like a crash (/wm errors lists it) and raises the reload banner.
local verifyReported = false

function Viewport.Verify()
	local wfL, wfR = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local wfT, wfB = WorldFrame:GetTop(), WorldFrame:GetBottom()
	if not wfL or not wfR or not wfT or not wfB then return end
	if not wfFull.ok then
		-- The full-window measurement never resolved: Apply fell back to the
		-- untrusted scale conversion and there is no honest basis to verify
		-- against — say so once rather than false-passing.
		if not verifyReported then
			verifyReported = true
			WM.ReportError("Viewport.lua: full-window measurement unavailable —"
				.. " world geometry applied via the untrusted scale fallback and cannot be verified")
		end
		return
	end
	-- Intended rect, re-computed NOW from the live band metrics, as fractions
	-- of the cached full-window rect (all four comparisons in WF units).
	local bandLeft, bandW = BandRect()
	local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
	local wantL = wfFull.left + wfFull.width * (bandLeft / uiW)
	local wantW = wfFull.width * (bandW / uiW)
	local wantH = wfFull.height * (ComputeHeightUI() / uiH)
	-- Slack scales with the BAND width (what is being verified), not the full
	-- window: on a wide window full-width slack would triple the tolerance
	-- and let small genuine drifts pass.
	local tol = wantW * 0.005 + 2 -- rounding slack: 0.5% + 2 WF units
	local badTop = math.abs(wfT - wfFull.top) > tol
	local badL = math.abs(wfL - wantL) > tol
	local badW = math.abs((wfR - wfL) - wantW) > tol
	local badH = math.abs((wfT - wfB) - wantH) > tol
	if not (badTop or badL or badW or badH) then
		-- Geometry checks out, but a CLAMPED square is still a standing
		-- config/window mismatch the user must see. badShapeReported raises it
		-- only once, and the single setup banner's reason can be overwritten by
		-- a later "drift" raiser and then hidden by Core's flap-back path — so
		-- if the last Apply clamped and no banner stands now, re-raise the
		-- shape banner here (Verify runs 0.5s AFTER any Apply, i.e. after the
		-- flap-back hide, so ordering cannot swallow it again).
		if lastClamped and not WM.SetupBannerReason() then
			WM.ShowSetupBanner("The WoW window cannot fit the WoW Mobile layout at full size.", "shape")
		end
		return
	end
	if not verifyReported then
		verifyReported = true
		WM.ReportError(string.format(
			"Viewport.lua: world square did not apply — WorldFrame is %.0fx%.0f WF units at (%.0f, top %.0f),"
				.. " wanted %.0fx%.0f at (%.0f, top %.0f), full window %.0fx%.0f"
				.. " (world looks stretched or leaves a gap); reload to reapply",
			wfR - wfL, wfT - wfB, wfL, wfT,
			wantW, wantH, wantL, wfFull.top, wfFull.width, wfFull.height))
	end
	WM.ShowSetupBanner("The 3D world viewport did not apply — the world looks stretched.", "verify")
end

-- Live geometry dump for /wm status (Config.lua): the measured full-window
-- rect and WorldFrame's current rect as FRACTIONS of it — multiplied by the
-- chosen physical basis (Band.client) they yield the physical world rect a
-- field report can compare against the server's crop in one paste.
function Viewport.GetStatus()
	local s = {
		fullOk = wfFull.ok,
		fullW = wfFull.width,
		fullH = wfFull.height,
	}
	local l, r = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local t, b = WorldFrame:GetTop(), WorldFrame:GetBottom()
	if l and r and t and b and wfFull.ok and wfFull.width > 0 and wfFull.height > 0 then
		s.leftFrac = (l - wfFull.left) / wfFull.width
		s.topFrac = (wfFull.top - t) / wfFull.height
		s.widthFrac = (r - l) / wfFull.width
		s.heightFrac = (t - b) / wfFull.height
	end
	return s
end

WM.OnInit(function()
	Viewport.Apply()

	-- Error/info text ("Out of range", quest progress lines): top-center of
	-- the world square, below the aura rows AND their duration texts — the
	-- debuff cells end at y=208 and their cell.remain texts hang to ~232
	-- (Auras.lua) — so y=240, the same clearance lane as the quest tracker
	-- (QuestLog.lua), well away from resting thumbs.
	UIErrorsFrame:ClearAllPoints()
	UIErrorsFrame:SetPoint("TOP", square, "TOP", 0, -WM.Px(240))
	UIErrorsFrame:SetWidth(WM.Px(1000))
	if UIErrorsFrame.SetFont then
		UIErrorsFrame:SetFont(WM.FONT, WM.Px(32), "OUTLINE")
	end
end)

-- Loading screens don't reset WorldFrame geometry, but scale/resolution
-- changes invalidate both the px factor and the square; re-apply cheaply.
-- (UI_SCALE_CHANGED / DISPLAY_SIZE_CHANGED are later-client events — TryOn
-- drops them silently if this 1.12 build lacks them.)
WM.On("PLAYER_ENTERING_WORLD", function() Viewport.Apply() end)
-- The freshness check also compares the LIVE window against the size the
-- deck's frames were laid out with; a change here means those frames are
-- stale — the check raises the reload banner (the square itself re-applies
-- correctly either way).
WM.TryOn("UI_SCALE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
	WM.CheckLayoutFresh()
end)
WM.TryOn("DISPLAY_SIZE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
	WM.CheckLayoutFresh()
end)
