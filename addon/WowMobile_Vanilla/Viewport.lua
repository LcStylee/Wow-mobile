--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Viewport
-- Shrinks the 3D world (WorldFrame) to a square anchored to the top of the
-- 1080x1920 window and paints a black backdrop over the region below it — the
-- "control deck" that owns all primary UI.
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
-- WorldFrame (targeting, camera) untouched.
local square = CreateFrame("Frame", "WowMobileWorldSquare", UIParent)
square:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
square:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
square:SetHeight(WM.Px(1080))
square:SetFrameStrata("BACKGROUND")
square:EnableMouse(false)
WM.WorldSquare = square

-- Black backdrop behind everything below the square. The deck's flat 2D look
-- is also what keeps the H.264 encoder cheap in that region.
local backdrop = CreateFrame("Frame", "WowMobileDeckBackdrop", UIParent)
backdrop:SetPoint("TOPLEFT", square, "BOTTOMLEFT", 0, 0)
backdrop:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
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

function Viewport.Apply()
	local heightPx = Viewport.HeightPx()
	local ratio = heightPx / 1080
	-- Height in UI units equals UIParent width in UI units at ratio 1.0
	-- (uniform scale); converted into WorldFrame's own coordinate space
	-- because WorldFrame does not inherit uiScale from UIParent.
	local heightUI = UIParent:GetWidth() * ratio
	local heightWF = heightUI * UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
	WorldFrame:SetHeight(heightWF)
	square:SetHeight(heightUI)
	for i = 1, table.getn(reflowers) do
		reflowers[i](heightPx)
	end
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
WM.TryOn("UI_SCALE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
WM.TryOn("DISPLAY_SIZE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
