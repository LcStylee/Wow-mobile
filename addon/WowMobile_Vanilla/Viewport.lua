--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Viewport
-- The 3D world renders FULL WINDOW, edge to edge — the game is a normal
-- widescreen game on the PC (docs/PHONE_FRAME.md). Inside the phone frame
-- (Band.lua) this module only defines the "world square": the transparent
-- region at the top of the frame through which the world shows on the
-- phone, and paints a black backdrop over the frame below it — the "control
-- deck" that owns all primary UI.
--
-- Publishes:
--   WM.WorldSquare — frame exactly covering the world region, used as the
--                    anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--   WM.Viewport.GetStatus() — world-render state for /wm status.
--
-- Until v0.5.0 this module shrank WorldFrame to the square (the 1.12
-- "viewport" technique) and blacked out the rest of the window. On
-- vanilla-plus builds (OctoWow) the engine did not even render the world
-- where WorldFrame's rect said — offset and oversized inside the frame, field
-- report v0.5.0. That is all gone: Apply RESTORES WorldFrame to the whole
-- client area (zero-offset corner anchors, exact whatever any scale claims).
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

-- The FRAME rect in UI units at call time: left offset from UIParent's left
-- edge, width, top offset from UIParent's top edge, height. Full window when Band.lua is unavailable (its failure is
-- already bannered by the crash guard) — exactly the pre-band behavior.
local function BandRect()
	local band = WM.Band
	if band and band.width then
		return band.left or 0, band.width, band.top or 0, band.height or UIParent:GetHeight()
	end
	return 0, UIParent:GetWidth(), 0, UIParent:GetHeight()
end

-- The intended square height in UI units, derived ONLY from live
-- measurements taken at call time: the FRAME's width (a design ratio of 1.0
-- means "square = frame width") capped so the fixed deck stack still fits
-- below it inside the frame; the caller reports a real clamp.
-- Returns heightUI, clamped(boolean), exact(boolean); clamped is true only
-- for a MEANINGFUL overshoot: Config.HeightBounds advertises whole design px
-- (and float math adds noise), so a height configured exactly at the
-- advertised bound can exceed the true geometric max by a sub-pixel amount on
-- a fully legitimate window — that is shaved silently, never reported. exact
-- is true when the clamp did not engage at all, i.e. heightUI is precisely
-- the configured height (lets Apply hand reflowers the configured integer
-- verbatim instead of a float roundtrip).
local function ComputeHeightUI()
	local _, bandW, _, bandH = BandRect()
	local ratio = Viewport.HeightPx() / 1080
	local heightUI = bandW * ratio
	local deckFixed = (WM.Config and WM.Config.DECK_FIXED_PX) or 790
	-- The deck budget as a PURE measurement — design px resolved as fractions
	-- of the MEASURED band width, never via WM.Px: its cached pxFactor is
	-- deliberately not refreshed on drift, and this function must clamp
	-- correctly whatever that factor holds (CheckLayoutFresh's emergency
	-- re-apply runs exactly when the factor is stale). The frame's height
	-- is the budget.
	local maxUI = bandH - bandW * (deckFixed / 1080)
	if maxUI < bandH * 0.25 then
		maxUI = bandH * 0.25 -- degenerate window: keep SOME world
	end
	if heightUI > maxUI then
		if heightUI > maxUI + bandW * (2 / 1080) then
			return maxUI, true, false -- real shape mismatch: caller raises the banner
		end
		return maxUI, false, false -- rounding/float overshoot (< 2 design px): silent
	end
	return heightUI, false, true
end

-- Restore the 3D world to the whole client area.
local function FullWindowWorld()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
end

local badShapeReported = false

function Viewport.Apply()
	local heightUI, clamped, exact = ComputeHeightUI()
	-- What the overlays must lay out against: the square that actually
	-- applied, in design px. When the clamp did not engage this is the
	-- configured height VERBATIM — the float roundtrip can land 1 ulp low,
	-- and integer-sensitive reflowers (QuickBar's floor((h - 328) / 104))
	-- would silently drop a slot at exact-fit heights.
	local _, bandW = BandRect()
	local heightPx
	if exact then
		heightPx = Viewport.HeightPx()
	else
		heightPx = heightUI * 1080 / bandW
	end
	FullWindowWorld()
	square:SetHeight(heightUI)
	if clamped and not badShapeReported then
		badShapeReported = true
		WM.ReportError(string.format(
			"Viewport.lua: the phone frame cannot fit the configured world square above the deck"
				.. " (%.0fx%.0f UI units) — square clamped; lower /wm viewport (or /wm reset),"
				.. " or pick a taller phone (/wm phone), then reload",
			UIParent:GetWidth(), UIParent:GetHeight()))
		WM.ShowSetupBanner("The phone frame cannot fit the WoW Mobile layout at full size.", "shape")
	end
	for i = 1, table.getn(reflowers) do
		reflowers[i](heightPx)
	end
end

-- /wm status: the world always renders full window now.
function Viewport.GetStatus()
	return { fullWindow = true }
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
