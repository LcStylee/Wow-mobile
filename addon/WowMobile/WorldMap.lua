--------------------------------------------------------------------------------
-- WowMobile · WorldMap
-- The map becomes a touch panel over the phone frame (above its own control
-- row since v0.6.2), per ARCHITECTURE §4 ("map becomes a fullscreen touch
-- panel"). It cannot be rebuilt from scratch — map canvas + pin logic stay
-- Blizzard's — so WorldMapFrame is scaled over the frame instead of living
-- in a Deck.CreatePanel. Phone taps on it are left clicks, a long press is a
-- right click (zoom out a level), a pinch is the mouse wheel. Adds a big
-- close button, pads pin hit rects toward touch size, and coordinates with
-- the deck exclusives so map / panels / bottom sheet never stack. Always
-- closes cleanly via HideUIPanel.
--------------------------------------------------------------------------------

local _, WM = ...

local WorldMap = {}
WM.WorldMap = WorldMap

local closeButton, controls, view

-- Map view (v0.6.2, field report v0.6.1: the map was "really small and on
-- the bottom of my screen", with no way to magnify): the map fills the phone
-- frame's width above a control row — Zoom- / Zoom+ / four pan arrows / Me /
-- Close — driving the MapCanvas scroll container's own zoom and pan (touch
-- drags over the world zone are camera drags, so the canvas' click-drag pan
-- is out of reach from the phone).
local CTRL_H = 104   -- control row height (design px)
local PAN_STEP = 0.1 -- one pan tap, in normalized map coordinates

-- Blizzard's pin art is mouse-sized (~30 physical px after the deck fit) and
-- each pin's hit rect matches its art. The art cannot grow without drowning
-- the map, but the hit rect can: pad every pin by 14 units per side — 28
-- units per axis x ~0.6 deck scale x ~2.5 px/unit ≈ 42 extra physical px —
-- for a ~70 px effective target so POIs and flight masters land under a
-- thumb (still short of the 90 px touch bar; padding further makes adjacent
-- pins' invisible rects swallow each other) — the same trick Blizzard.lua
-- uses for taxi nodes. Classic Era 1.15 ships the retail-lineage MapCanvas
-- map, so pins enumerate via MapCanvasMixin:EnumerateAllPins; guarded in
-- case a future build changes the mixin.
local function PadPinHitRects()
	local map = WorldMapFrame
	if not map.EnumerateAllPins then return end
	for pin in map:EnumerateAllPins() do
		if pin.SetHitRectInsets then
			pin:SetHitRectInsets(-14, -14, -14, -14)
		end
	end
end

local function Reflow()
	local map = WorldMapFrame
	-- Force windowed mode on builds that have the maximize/minimize toggle;
	-- fullscreen mode ignores external scaling.
	if map.IsMaximized and map:IsMaximized() and map.MaximizeMinimizeFrame then
		map.MaximizeMinimizeFrame:Minimize()
	end
	-- Fit the view (the phone frame above the control row) in both axes;
	-- the map is wider than tall, so it spans the full frame width.
	local scale = math.min(
		view:GetWidth() / map:GetWidth(),
		view:GetHeight() / map:GetHeight())
	map:SetScale(scale)
	map:ClearAllPoints()
	-- Top of the frame: clear of the phone's joystick band right above the
	-- bottom bars. Anchor offsets are in the map's own (scaled) space; zero
	-- offsets keep the math trivial.
	map:SetPoint("TOP", view, "TOP", 0, 0)
	-- Our close button lives inside the scaled frame: compensate so it stays
	-- ~100x96 physical px (>=90 px touch targets, ARCHITECTURE §4).
	closeButton:SetSize(WM.Px(100) / scale, WM.Px(96) / scale)
end

local function Canvas()
	return WorldMapFrame.ScrollContainer
end

local function Zoom(dir)
	local sc = Canvas()
	if not sc then return end
	if dir > 0 and sc.ZoomIn then sc:ZoomIn() end
	if dir < 0 and sc.ZoomOut then sc:ZoomOut() end
end

local function Pan(dx, dy)
	local sc = Canvas()
	if not sc or not sc.SetPanTarget then return end
	local x = (sc.GetCurrentScrollX and sc:GetCurrentScrollX()) or sc.currentScrollX or 0.5
	local y = (sc.GetCurrentScrollY and sc:GetCurrentScrollY()) or sc.currentScrollY or 0.5
	sc:SetPanTarget(math.min(1, math.max(0, x + dx * PAN_STEP)),
		math.min(1, math.max(0, y + dy * PAN_STEP)))
end

-- Zoom in on the player on the displayed map (no-op when the player is not
-- on it, or where the position is a secret value on the modern clients).
local function CenterOnPlayer()
	local sc = Canvas()
	if not sc or not C_Map or not WorldMapFrame.GetMapID then return end
	local pos = C_Map.GetPlayerMapPosition(WorldMapFrame:GetMapID(), "player")
	if not pos then return end
	local x, y = pos:GetXY()
	if WM.IsSecret and (WM.IsSecret(x) or WM.IsSecret(y)) then return end
	if sc.PanAndZoomTo then
		sc:PanAndZoomTo(x, y)
	elseif sc.SetPanTarget then
		sc:SetPanTarget(x, y)
	end
end

function WorldMap.Toggle()
	if WorldMapFrame:IsShown() then
		HideUIPanel(WorldMapFrame)
	else
		ShowUIPanel(WorldMapFrame)
	end
end

function WorldMap.Close()
	if WorldMapFrame:IsShown() then
		HideUIPanel(WorldMapFrame)
	end
end

WM.OnInit(function()
	closeButton = WM.CreateTouchButton(WorldMapFrame, 100, 96, "X", 44)
	closeButton:SetFrameStrata("FULLSCREEN_DIALOG") -- above every map overlay
	closeButton:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", 0, 0)
	closeButton:SetScript("OnClick", WorldMap.Close)

	-- The map's view: the whole phone frame above the control row.
	view = CreateFrame("Frame", "WowMobileMapView", UIParent)
	view:SetPoint("TOPLEFT", WowMobileBand, "TOPLEFT", 0, 0)
	view:SetPoint("BOTTOMRIGHT", WowMobileBand, "BOTTOMRIGHT", 0, WM.Px(CTRL_H))

	-- Control row: parented to UIParent (the map is not a fullscreen panel
	-- here, UIParent stays shown), shown with the map.
	controls = CreateFrame("Frame", "WowMobileMapControls", UIParent)
	controls:SetFrameStrata("FULLSCREEN_DIALOG")
	controls:SetPoint("BOTTOMLEFT", WowMobileBand, "BOTTOMLEFT", 0, 0)
	controls:SetPoint("BOTTOMRIGHT", WowMobileBand, "BOTTOMRIGHT", 0, 0)
	controls:SetHeight(WM.Px(CTRL_H))
	WM.SkinFrame(controls, { 0.05, 0.05, 0.07, 0.92 })
	controls:Hide()
	local entries = {
		{ "Zoom -", function() Zoom(-1) end },
		{ "Zoom +", function() Zoom(1) end },
		{ "<",      function() Pan(-1, 0) end },
		{ "^",      function() Pan(0, -1) end },
		{ "v",      function() Pan(0, 1) end },
		{ ">",      function() Pan(1, 0) end },
		{ "Me",     CenterOnPlayer },
		{ "Close",  WorldMap.Close },
	}
	-- 8 x 128 + 7 x 4 = 1052 design px inside the 1080 frame.
	local prev
	for i = 1, #entries do
		local b = WM.CreateTouchButton(controls, 128, CTRL_H - 12, entries[i][1], 26)
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", WM.Px(4), 0)
		else
			b:SetPoint("LEFT", controls, "LEFT", WM.Px(14), 0)
		end
		b:SetScript("OnClick", entries[i][2])
		prev = b
	end

	-- Runs after Blizzard's own UIPanel positioning for the frame, so our
	-- anchors win. WorldMapFrame is NOT protected — SetScale/SetPoint/
	-- SetHitRectInsets are legal in combat — so the reflow runs immediately:
	-- deferring it would leave a mid-fight map at Blizzard's default
	-- position/scale until combat ended.
	WorldMapFrame:HookScript("OnShow", function()
		WM.Deck.YieldTo("worldmap")
		Reflow()
		PadPinHitRects()
		controls:Show()
	end)
	-- A fullscreen-panel close path can leave UIParent hidden (the v0.5.1
	-- 1.12 field bug); never let closing the map take the whole UI with it.
	-- UIParent:Show is protected in combat, hence the lockdown queue.
	WorldMapFrame:HookScript("OnHide", function()
		controls:Hide()
		if not UIParent:IsShown() then
			WM.OutOfCombat("worldmap-uiparent", function() UIParent:Show() end)
		end
		if WM.RefreshMinimap then WM.RefreshMinimap() end
	end)

	-- Pins are re-acquired from pools whenever the displayed map changes;
	-- re-pad after Blizzard's own OnMapChanged provider pass has run.
	if WorldMapFrame.OnMapChanged then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
			if WorldMapFrame:IsShown() then PadPinHitRects() end
		end)
	end

	WM.Deck.RegisterExclusive("worldmap", WorldMap.Close)
end)
