--------------------------------------------------------------------------------
-- WowMobile · Viewport
-- Shrinks the 3D world (WorldFrame) to a square anchored to the top of the
-- 9:16 band (the full window in portrait mode, the centered landscape band
-- otherwise — Band.lua) and paints a black backdrop over the band region
-- below it — the "control deck" that owns all primary UI (see
-- docs/ARCHITECTURE.md §1). In landscape mode the world OUTSIDE the band is
-- deliberately not rendered: WorldFrame is sized to the band-width square,
-- and Band.lua's side rails black out the rest of the window.
--
-- Publishes:
--   WM.WorldSquare — insecure frame exactly covering the world region, used as
--                    the anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--   WM.Viewport.GetStatus() — live world-rect fractions for /wm status.
--
-- WorldFrame geometry is placed WITHOUT any effective-scale conversion: the
-- 1.12 field client (vanilla port of this file) proved GetEffectiveScale()
-- can lie, shrinking the world to uiScale-sized 80% of the band with an
-- engine-white strip beside it. The scale-proof idiom is mirrored here too:
-- re-anchor WorldFrame to span the FULL window (anchors resolve in absolute
-- screen space, so zero-offset SetPoints are exact whatever any scale
-- claims), measure that rect in WorldFrame's OWN units, and place the band
-- as FRACTIONS of it — fractions need no scale conversion at all.
--------------------------------------------------------------------------------

local _, WM = ...

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
black:SetAllPoints()
black:SetColorTexture(0, 0, 0, 1)
WM.DeckBackdrop = backdrop

--------------------------------------------------------------------------------
-- Gap shims — no bare engine pixels anywhere in the band
-- The deck backdrop covers the band below the SQUARE and Band.lua's rails
-- cover outside the band, but both anchor to the addon's INTENDED geometry.
-- If WorldFrame's ACTUAL rect ever disagrees (the vanilla field failure: a
-- lying scale left the world at 80% of the band, engine-painted strip
-- beside it), the gap between the world's real edge and the band showed
-- bare engine. These four shims anchor to WorldFrame's LIVE edges on one
-- side and the band frame on the other, so ANY future gap is black — they
-- are zero-area (invisible, zero cost) whenever the world exactly fills the
-- square. BACKGROUND strata level 0: below every UI surface, above only the
-- 3D world itself, which by construction they never overlap.
--------------------------------------------------------------------------------

local function CreateShim(name)
	local shim = CreateFrame("Frame", name, UIParent)
	shim:SetFrameStrata("BACKGROUND")
	shim:SetFrameLevel(0)
	shim:EnableMouse(false)
	local tex = shim:CreateTexture(nil, "BACKGROUND")
	tex:SetAllPoints()
	tex:SetColorTexture(0, 0, 0, 1)
	return shim
end

-- Right of the world's real right edge, down the full band height.
local shimRight = CreateShim("WowMobileWorldShimRight")
shimRight:SetPoint("TOPLEFT", WorldFrame, "TOPRIGHT", 0, 0)
shimRight:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
-- Left of the world's real left edge, down the FULL band height — mirroring
-- shimRight, so the corner below a world that is both narrower than the band
-- and shifted right of its left edge is covered too (the overlap with
-- shimBelow/deck backdrop is harmless: all opaque black).
local shimLeft = CreateShim("WowMobileWorldShimLeft")
shimLeft:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
shimLeft:SetPoint("BOTTOMLEFT", bandHost, "BOTTOMLEFT", 0, 0)
shimLeft:SetPoint("RIGHT", WorldFrame, "LEFT", 0, 0)
-- Between the world's real bottom edge and the band bottom (overlaps the
-- deck backdrop harmlessly — both opaque black).
local shimBelow = CreateShim("WowMobileWorldShimBelow")
shimBelow:SetPoint("TOPLEFT", WorldFrame, "BOTTOMLEFT", 0, 0)
shimBelow:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
-- Above the world's real top edge (should never exist — belt and braces).
local shimTop = CreateShim("WowMobileWorldShimTop")
shimTop:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
shimTop:SetPoint("BOTTOMRIGHT", WorldFrame, "TOPRIGHT", 0, 0)

-- viewport.height is design px of the 1080-wide window (the saved variable
-- ARCHITECTURE §1 documents, default 1080); as a fraction of the design width
-- it scales to any real capture resolution.
function Viewport.HeightPx()
	return (WM.db and WM.db.viewport.height) or 1080
end

-- World-square overlays whose layout depends on the configurable square
-- height (quick-bar column, party-frame re-home) register here. Callbacks run
-- inside Apply's out-of-combat closure — secure Show/Hide and SetScale are
-- legal there — receiving the square height in design px, and must be
-- idempotent (Apply re-runs on login, /wm viewport, and scale/size changes).
local reflowers = {}

function Viewport.OnApply(fn)
	reflowers[#reflowers + 1] = fn
end

-- WorldFrame's full-window rect in ITS OWN coordinate units, (re)measured by
-- anchoring it edge-to-edge to UIParent first: anchors resolve in absolute
-- screen space, so after the two zero-offset SetPoints the frame spans the
-- client area EXACTLY — whatever either GetEffectiveScale() claims. The
-- rect read back in WF units is the ground-truth basis the band fractions
-- multiply. Re-measured on every Apply (scale/resolution changes alter the
-- ratio); the reset+measure+apply sequence runs inside one frame, so no
-- transient geometry ever reaches the screen. .ok false = the rect did not
-- resolve synchronously; then the last resort is the old effective-scale
-- conversion.
local wfFull = { ok = false }
local measureRetries = 0
-- The band width Apply last handed SetSize, in WF units: the second,
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
		-- which would poison the fraction basis. Two independent checks:
		-- 1. Aspect: the full-window rect's aspect must match UIParent's
		--    live aspect (same window, uniform scale). A stale SQUARE rect
		--    is ~1:1 and fails this in BOTH modes (portrait windows are
		--    taller than square, landscape wider), routing to the bounded
		--    retry + fallback below — the intended safe degradation.
		-- 2. Width: in landscape the band is strictly narrower than the
		--    window, so a genuine full-window rect must be meaningfully
		--    wider than the band rect last applied; this rejects every
		--    stale-band shape even on a near-square landscape window the
		--    aspect gate alone could miss. (Portrait band == full window:
		--    skipped, equality is right there.)
		local rel = ((r - l) / (t - b)) / (UIParent:GetWidth() / UIParent:GetHeight())
		if rel > 0.995 and rel < 1.005 then
			local bandWidthUI = (WM.Band and WM.Band.width) or UIParent:GetWidth()
			local narrowBand = bandWidthUI < UIParent:GetWidth() * 0.995
			if not (narrowBand and lastAppliedWF and (r - l) <= lastAppliedWF * 1.001) then
				wfFull.left, wfFull.top = l, t
				wfFull.width, wfFull.height = r - l, t - b
				wfFull.ok = true
				return
			end
		end
	end
	-- Rect unresolved or stale: last resort is the effective-scale
	-- conversion; Apply schedules a bounded retry.
	local toWF = UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
	wfFull.left, wfFull.top = nil, nil
	wfFull.width = UIParent:GetWidth() * toWF
	wfFull.height = UIParent:GetHeight() * toWF
	wfFull.ok = false
end

-- Last height a bounds-clamp notice was printed for: Apply re-runs on every
-- loading screen and scale/size change, so the notice dedupes on the clamped
-- value instead of spamming chat (and the phone screen) each time.
local warnedClampPx

function Viewport.Apply()
	WM.OutOfCombat("viewport", function()
		local heightPx = Viewport.HeightPx()
		-- Re-clamp against the LIVE mode's bounds. Config.SetHeight clamps at
		-- set time only, but the bounds move with the window mode: a height
		-- saved legally under a taller-than-9:16 portrait window (RatioMax up
		-- to 1.20) exceeds the exactly-9:16 band mode's ceiling after the
		-- server switches layouts. Applied verbatim it would sink the world
		-- square's bottom rows under the bottom-anchored deck stack, so clamp
		-- for use here — the saved value is deliberately NOT rewritten, since
		-- a transient window resize must not ratchet the user's choice down —
		-- and say so once, because the phone splits its gesture zones by its
		-- own World viewport setting, which must track the value actually
		-- applied.
		if WM.Config and WM.Config.HeightBounds then
			local lo, hi = WM.Config.HeightBounds()
			local clamped = heightPx
			if clamped < lo then clamped = lo end
			if clamped > hi then clamped = hi end
			if clamped ~= heightPx then
				if warnedClampPx ~= clamped then
					warnedClampPx = clamped
					WM.Print(string.format(
						"saved world viewport height %d is outside this window mode's bounds (%d..%d) — using %d; set the same value in the phone client (Set > World viewport), or /wm viewport to re-save",
						heightPx, lo, hi, clamped))
				end
				heightPx = clamped
			end
		end
		local ratio = heightPx / 1080
		-- Height in UI units equals the BAND width in UI units at ratio 1.0
		-- (the band IS the design space; full window width in portrait mode).
		-- Applied as FRACTIONS of the freshly measured full-window rect in
		-- WorldFrame's OWN units (UI units over UI units — the scale cancels):
		-- no effective scale anywhere, so a client that misreports its scale
		-- chain cannot shrink or shift the world.
		local bandLeftUI = (WM.Band and WM.Band.left) or 0
		local bandWidthUI = (WM.Band and WM.Band.width) or UIParent:GetWidth()
		local heightUI = bandWidthUI * ratio
		local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
		MeasureFullWorldFrame()
		local leftWF = wfFull.width * (bandLeftUI / uiW)
		local widthWF = wfFull.width * (bandWidthUI / uiW)
		local heightWF = wfFull.height * (heightUI / uiH)
		WorldFrame:ClearAllPoints()
		WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", leftWF, 0)
		WorldFrame:SetSize(widthWF, heightWF)
		lastAppliedWF = widthWF
		square:SetHeight(heightUI)
		for i = 1, #reflowers do
			reflowers[i](heightPx)
		end
		-- Self-heal: a failed full-window measurement placed the world via
		-- the untrusted scale fallback — re-run Apply once the client has
		-- settled a layout pass (bounded, so an ever-failing client cannot
		-- loop forever).
		if not wfFull.ok and measureRetries < 3 then
			measureRetries = measureRetries + 1
			C_Timer.After(0.2, Viewport.Apply)
		elseif wfFull.ok then
			measureRetries = 0
		end
	end)
end

-- Live geometry dump for /wm status (Config.lua): the measured full-window
-- rect and WorldFrame's current rect as FRACTIONS of it — multiplied by the
-- physical client size (Band.px basis) they yield the physical world rect a
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
	-- debuff cells end at y=208 and their cell.remain texts hang 24 px below,
	-- to ~232 (Auras.lua) — so y=240, the same clearance lane as the quest
	-- tracker (QuestLog.lua), well away from resting thumbs. StaticPopups
	-- (head at y=230, Blizzard.lua) live on the DIALOG strata and draw over
	-- this transient text either way.
	UIErrorsFrame:ClearAllPoints()
	UIErrorsFrame:SetPoint("TOP", square, "TOP", 0, -WM.Px(240))
	UIErrorsFrame:SetWidth(WM.Px(1000))
	if UIErrorsFrame.SetFont then
		UIErrorsFrame:SetFont(STANDARD_TEXT_FONT, WM.Px(32), "OUTLINE")
	end
end)

-- Loading screens don't reset WorldFrame geometry, but scale/resolution
-- changes invalidate both the px factor and the square; re-apply cheaply.
WM.On("PLAYER_ENTERING_WORLD", function() Viewport.Apply() end)
WM.On("UI_SCALE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
WM.On("DISPLAY_SIZE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
