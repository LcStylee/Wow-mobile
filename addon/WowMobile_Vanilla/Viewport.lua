--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Viewport
-- The 3D world renders FULL WINDOW, edge to edge — the game is a normal
-- widescreen game on the PC (docs/PHONE_FRAME.md). Inside the phone frame
-- (Band.lua) this module defines the phone layout's top HUD strip and the
-- "world square": the transparent middle of the frame through which the
-- world shows on the phone, between the top HUD and the bottom stack.
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

-- Phone layout (v0.6.0), top to bottom inside the frame:
--   WM.TopHud      — thin XP bar + compact player/target frames
--                    (PhoneData.topHudPx design px tall)
--   WM.WorldSquare — the world region: everything between the top HUD and
--                    the bottom stack; auras, minimap, quick bars and
--                    tooltips anchor to it. No fill — the world shows through.
--   bottom stack   — chat + action bars + menu row (Deck.lua, PhoneData.
--                    deckStackPx tall; the square's bottom anchors to it).
-- Heights are design px resolved at PLAYER_LOGIN (Viewport OnInit), when the
-- px factor is final.
local bandHost = WM.BandFrame or UIParent -- Band.lua loads first; nil-guard mirrors Core's crash-tolerance style

local topHud = CreateFrame("Frame", "WowMobileTopHud", UIParent)
topHud:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
topHud:SetPoint("TOPRIGHT", bandHost, "TOPRIGHT", 0, 0)
topHud:SetHeight(WM.Px(WM.PhoneData.topHudPx))
topHud:SetFrameStrata("LOW")
topHud:EnableMouse(false)
WM.TopHud = topHud

local square = CreateFrame("Frame", "WowMobileWorldSquare", UIParent)
square:SetPoint("TOPLEFT", topHud, "BOTTOMLEFT", 0, 0)
square:SetPoint("TOPRIGHT", topHud, "BOTTOMRIGHT", 0, 0)
square:SetHeight(WM.Px(1080)) -- replaced by the bottom-stack anchor (Deck.lua)
square:SetFrameStrata("BACKGROUND")
square:EnableMouse(false)
WM.WorldSquare = square

-- World-square overlays whose layout depends on the configurable square
-- height register here; callbacks receive the square height in design px and
-- must be idempotent (Apply re-runs on login, /wm viewport, world entry).
local reflowers = {}

function Viewport.OnApply(fn)
	table.insert(reflowers, fn)
end

-- Design height of the world region: the frame's design height (1080-wide
-- design space, so 1080 * height / width) minus the top HUD and the bottom
-- stack. Floored so a squat frame still leaves the overlays some room.
function Viewport.HeightPx()
	local band = WM.Band
	local w = (band and band.width) or WM.UIWidth()
	local h = (band and band.height) or WM.UIHeight()
	local d = WM.PhoneData
	local px = math.floor(1080 * h / w + 0.5) - d.topHudPx - d.deckStackPx
	if px < 300 then px = 300 end
	return px
end

-- Restore the 3D world to the whole client area.
local function FullWindowWorld()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
end

function Viewport.Apply()
	FullWindowWorld()
	topHud:SetHeight(WM.Px(WM.PhoneData.topHudPx))
	local heightPx = Viewport.HeightPx()
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
