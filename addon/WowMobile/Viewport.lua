--------------------------------------------------------------------------------
-- WowMobile · Viewport
-- The 3D world renders FULL WINDOW, edge to edge — the game is a normal
-- widescreen game on the PC (docs/PHONE_FRAME.md). Inside the phone frame
-- (Band.lua) this module defines the phone layout's top HUD strip and the
-- "world square": the transparent middle of the frame through which the
-- world shows on the phone, between the top HUD and the bottom stack.
--
-- Publishes:
--   WM.WorldSquare — insecure frame exactly covering the world region, used as
--                    the anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--   WM.Viewport.GetStatus() — world-render state for /wm status.
--
-- Until v0.5.0 this module shrank WorldFrame to the square and blacked out
-- the rest of the window. That is gone: Apply now RESTORES WorldFrame to the
-- whole client area (undoing any earlier viewport, including one a previous
-- version left behind in this session).
--------------------------------------------------------------------------------

local _, WM = ...

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
-- Mouse-disabled containers: world taps must reach WorldFrame untouched.
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

-- World-square overlays whose layout depends on the configurable square
-- height (quick-bar column, party-frame re-home) register here. Callbacks run
-- inside Apply's out-of-combat closure — secure Show/Hide and SetScale are
-- legal there — receiving the square height in design px, and must be
-- idempotent (Apply re-runs on login, /wm viewport, and scale/size changes).
local reflowers = {}

function Viewport.OnApply(fn)
	reflowers[#reflowers + 1] = fn
end

-- Restore the 3D world to the whole client area: zero-offset corner anchors
-- resolve in absolute screen space, exact whatever any scale claims.
local function FullWindowWorld()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
end

function Viewport.Apply()
	WM.OutOfCombat("viewport", function()
		FullWindowWorld()
		topHud:SetHeight(WM.Px(WM.PhoneData.topHudPx))
		local heightPx = Viewport.HeightPx()
		for i = 1, #reflowers do
			reflowers[i](heightPx)
		end
	end)
end

-- /wm status: the world always renders full window now.
function Viewport.GetStatus()
	return { fullWindow = true }
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
