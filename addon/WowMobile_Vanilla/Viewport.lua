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
--
-- WorldFrame geometry manipulation is the classic 1.12 "viewport" technique
-- (CT_Viewport-style): WorldFrame does not inherit uiScale from UIParent, so
-- the height is converted into its own coordinate space.
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
	-- Converted into WorldFrame's own coordinate space because WorldFrame
	-- does not inherit uiScale from UIParent (both effective scales are LIVE
	-- measurements, so this is right whatever the cvars say) — offsets passed
	-- to SetPoint are in the moved frame's space, so the band-left offset
	-- converts too. In landscape mode WorldFrame covers only the band (its
	-- width is set explicitly, no TOPRIGHT anchor); the side rails black out
	-- the rest of the window.
	local toWF = UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", bandLeft * toWF, 0)
	WorldFrame:SetWidth(bandW * toWF)
	WorldFrame:SetHeight(heightUI * toWF)
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

-- Measure WorldFrame's ACTUAL on-screen rect against the intended square
-- (both sides in physical screen px via the live effective scales). Any
-- mismatch — a client that reset WorldFrame behind our back, a scale that
-- shifted after Apply, SetHeight silently refused — is recorded like a crash
-- (/wm errors lists it) and raises the reload banner: a stretched world must
-- never pass silently again.
local verifyReported = false

function Viewport.Verify()
	local wfL, wfR = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local wfT, wfB = WorldFrame:GetTop(), WorldFrame:GetBottom()
	local uL, uT = UIParent:GetLeft(), UIParent:GetTop()
	if not wfL or not wfR or not wfT or not wfB or not uL then return end
	local ws = WorldFrame:GetEffectiveScale()
	local us = UIParent:GetEffectiveScale()
	-- Intended rect, re-measured NOW: the square spans the BAND width at the
	-- band's left edge (full window in portrait mode).
	local bandLeft, bandW = BandRect()
	local wantH = ComputeHeightUI() * us
	local wantW = bandW * us
	local wantL = (uL + bandLeft) * us
	local tol = 2 + wantW * 0.005 -- rounding slack: 0.5% + 2 screen px
	local badTop = math.abs(wfT * ws - uT * us) > tol
	local badL = math.abs(wfL * ws - wantL) > tol
	local badW = math.abs((wfR - wfL) * ws - wantW) > tol
	local badH = math.abs((wfT - wfB) * ws - wantH) > tol
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
			"Viewport.lua: world square did not apply — WorldFrame is %.0fx%.0f px at (%.0f, top %.0f),"
				.. " wanted %.0fx%.0f at (%.0f, top %.0f) (world looks stretched); reload to reapply",
			(wfR - wfL) * ws, (wfT - wfB) * ws, wfL * ws, wfT * ws,
			wantW, wantH, wantL, uT * us))
	end
	WM.ShowSetupBanner("The 3D world viewport did not apply — the world looks stretched.", "verify")
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
