--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · WorldMap
-- The map becomes a touch panel over the phone frame. It cannot be rebuilt
-- from scratch — map canvas + POI logic stay Blizzard's — so WorldMapFrame is
-- scaled and anchored into the frame instead of living in a Deck.CreatePanel.
--
-- On 1.12 the map is a fullscreen frame anchored over the whole screen in
-- XML, so the reflow must ClearAllPoints and give it back its design size
-- (1024x768) before scaling — the same shrink technique the vanilla map
-- addons used. POIs are the lazily created WorldMapFramePOI1..N buttons,
-- re-padded on WORLD_MAP_UPDATE.
--
-- Map view (v0.6.2, field report v0.6.1: "really small and on the bottom of
-- my screen ... should be some sort of a zoomed in possibility"): the map
-- fills the phone frame's width above a control row (Zoom- / Zoom+ / four
-- pan arrows / Me / Close) and magnifies up to 3x. At zoom > 1 the map is
-- larger than the view and spills past it (1.12 cannot clip a Blizzard frame
-- tree); the control row sits on top, and whatever spills outside the phone
-- frame is never streamed. A pinch over the map (mouse wheel) zooms too.
--------------------------------------------------------------------------------

local WM = WowMobile

local WorldMap = {}
WM.WorldMap = WorldMap

local MAP_W, MAP_H = 1024, 768 -- 1.12 WorldMapFrame design size
local CTRL_H = 104             -- control row height (design px)
local ZOOMS = { 1, 1.5, 2, 3 } -- magnification steps
local PAN_STEP = 0.25          -- one pan tap moves this fraction of the view

local closeButton, controls, view
local zoomIndex = 1
-- Map point (fractions) wanted at the view centre, and the one actually
-- shown there after clamping the view to the map. Kept apart so a zoom step
-- that has to clamp does not lose the player point for the next step.
local centerX, centerY = 0.5, 0.5
local shownX, shownY = 0.5, 0.5

-- Blizzard's POI art is mouse-sized and each POI's hit rect matches its art.
-- The art cannot grow without drowning the map, but the hit rect can: pad
-- every POI toward touch size — the same trick Blizzard.lua uses for taxi
-- nodes.
local function PadPOIHitRects()
	local i = 1
	while true do
		local poi = getglobal("WorldMapFramePOI" .. i)
		if not poi then break end
		if poi.SetHitRectInsets then
			poi:SetHitRectInsets(-14, -14, -14, -14)
		end
		i = i + 1
	end
end

local function Clamp(c, half, topAlign)
	-- half: half the view in map fractions. A view larger than the map keeps
	-- the map centred horizontally and against the top vertically (clear of
	-- the phone's joystick band right above the bottom bars); otherwise the
	-- view never leaves the map.
	if half >= 0.5 then
		if topAlign then return half end
		return 0.5
	end
	if c < half then return half end
	if c > 1 - half then return 1 - half end
	return c
end

-- Scale + anchor the map for the current zoom and centre. Sizes are worked
-- in UIParent units (what WM.Px and the view frame use) and converted into
-- the map's own space through the effective scales, because the 1.12
-- fullscreen panel path gives WorldMapFrame its own parent and scale.
local function Reflow()
	local map = WorldMapFrame
	-- Strip the fullscreen anchors and restore the design size so SetScale
	-- has something to scale (a both-corners-anchored frame ignores it).
	map:ClearAllPoints()
	map:SetWidth(MAP_W)
	map:SetHeight(MAP_H)
	map:SetFrameStrata("HIGH")

	local viewW, viewH = view:GetWidth(), view:GetHeight()
	if not viewW or viewW <= 0 or not viewH or viewH <= 0 then return end
	-- UI units per map unit: fit the view in both axes, then magnify.
	local unit = math.min(viewW / MAP_W, viewH / MAP_H) * ZOOMS[zoomIndex]
	map:SetScale(1)
	local base = map:GetEffectiveScale()
	map:SetScale(unit * UIParent:GetEffectiveScale() / base)

	shownX = Clamp(centerX, viewW / unit / MAP_W / 2)
	shownY = Clamp(centerY, viewH / unit / MAP_H / 2, true)
	-- Anchor offsets are in the map's own (scaled) space: map units.
	map:SetPoint("TOPLEFT", view, "CENTER", -shownX * MAP_W, shownY * MAP_H)

	-- Our close button lives inside the scaled frame: compensate so it stays
	-- ~100x96 physical px (>=90 px touch targets).
	local k = UIParent:GetEffectiveScale() / map:GetEffectiveScale()
	closeButton:SetWidth(WM.Px(100) * k)
	closeButton:SetHeight(WM.Px(96) * k)
	controls:SetScale(k)
	-- At zoom > 1 the map's own corner is off the phone: Close lives in the
	-- control row.
	WM.SetShown(closeButton, zoomIndex == 1)
	if controls.zoomLabel then
		controls.zoomLabel:SetText(ZOOMS[zoomIndex] .. "x")
	end
end

-- The player's position as fractions of the whole WorldMapFrame (the POI
-- canvas, WorldMapDetailFrame, is inset inside it), or nil when the player
-- is not on the displayed map.
local function PlayerPoint()
	local px, py = GetPlayerMapPosition("player")
	if not px or (px == 0 and py == 0) then return nil end
	local d = WorldMapDetailFrame
	local mapL, mapT = WorldMapFrame:GetLeft(), WorldMapFrame:GetTop()
	if not d or not mapL or not d:GetLeft() then return px, py end
	local x = (d:GetLeft() - mapL + px * d:GetWidth()) / MAP_W
	local y = (mapT - d:GetTop() + py * d:GetHeight()) / MAP_H
	return x, y
end

local function CenterOnPlayer()
	local x, y = PlayerPoint()
	if x then centerX, centerY = x, y end
end

local function Zoom(step)
	local z = zoomIndex + step
	if z < 1 then z = 1 end
	if z > table.getn(ZOOMS) then z = table.getn(ZOOMS) end
	if z == zoomIndex then return end
	-- Zooming in from the whole-map view goes to where the player is.
	if zoomIndex == 1 and step > 0 then CenterOnPlayer() end
	zoomIndex = z
	Reflow()
end

local function Pan(dx, dy)
	local unit = ZOOMS[zoomIndex]
	-- From what is on screen, so a pan never spends taps undoing a clamp.
	centerX = shownX + dx * PAN_STEP / unit
	centerY = shownY + dy * PAN_STEP / unit
	Reflow()
end

function WorldMap.Toggle()
	if WorldMapFrame:IsShown() then
		WorldMap.Close()
	else
		-- ToggleWorldMap is 1.12's canonical open path (sets up the current
		-- zone before showing).
		ToggleWorldMap()
	end
end

-- Field report v0.5.1: closing the map from the phone left the WHOLE UI
-- gone. On 1.12 ToggleWorldMap opens the map as a FULLSCREEN UI panel, which
-- hides UIParent (and with it every WowMobile frame) until the panel system
-- closes it again — a bare WorldMapFrame:Hide() skipped that restore. Close
-- through the panel system when it exists, and the OnHide hook below brings
-- UIParent back whatever path closed the map.
function WorldMap.Close()
	if WorldMapFrame:IsShown() then
		if HideUIPanel then
			HideUIPanel(WorldMapFrame)
		end
		if WorldMapFrame:IsShown() then
			WorldMapFrame:Hide()
		end
	end
	if not UIParent:IsShown() then
		UIParent:Show()
	end
end

-- The control row. A child of WorldMapFrame (so it shows while the 1.12
-- fullscreen panel has UIParent hidden), counter-scaled back to UIParent
-- units in Reflow so WM.Px sizes hold, and anchored to the phone frame's
-- bottom edge.
local function BuildControls()
	controls = CreateFrame("Frame", "WowMobileMapControls", WorldMapFrame)
	controls:SetFrameStrata("FULLSCREEN_DIALOG")
	controls:SetPoint("BOTTOMLEFT", WowMobileBand, "BOTTOMLEFT", 0, 0)
	controls:SetPoint("BOTTOMRIGHT", WowMobileBand, "BOTTOMRIGHT", 0, 0)
	controls:SetHeight(WM.Px(CTRL_H))
	WM.SkinFrame(controls, { 0.05, 0.05, 0.07, 0.92 })

	local entries = {
		{ "Zoom -", function() Zoom(-1) end },
		{ "Zoom +", function() Zoom(1) end },
		{ "<",      function() Pan(-1, 0) end },
		{ "^",      function() Pan(0, -1) end },
		{ "v",      function() Pan(0, 1) end },
		{ ">",      function() Pan(1, 0) end },
		{ "Me",     function()
			if zoomIndex == 1 then zoomIndex = 3 end
			CenterOnPlayer()
			Reflow()
		end },
		{ "Close",  WorldMap.Close },
	}
	-- 8 x 128 + 7 x 4 = 1052 design px inside the 1080 frame.
	local prev
	for i = 1, table.getn(entries) do
		local e = entries[i]
		local b = WM.CreateTouchButton(controls, 128, CTRL_H - 12, e[1], 26)
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", WM.Px(4), 0)
		else
			b:SetPoint("LEFT", controls, "LEFT", WM.Px(14), 0)
		end
		b:SetScript("OnClick", e[2])
		prev = b
	end

	-- Current magnification, top-left of the map view.
	local tag = CreateFrame("Frame", nil, controls)
	tag:SetWidth(WM.Px(90))
	tag:SetHeight(WM.Px(44))
	tag:SetPoint("BOTTOMLEFT", controls, "TOPLEFT", WM.Px(8), WM.Px(8))
	WM.SkinFrame(tag, { 0.05, 0.05, 0.07, 0.85 })
	controls.zoomLabel = WM.CreateText(tag, 26, "OUTLINE")
	controls.zoomLabel:SetPoint("CENTER", tag, "CENTER", 0, 0)
end

WM.OnInit(function()
	-- The map's view: the whole phone frame above the control row.
	view = CreateFrame("Frame", "WowMobileMapView", UIParent)
	view:SetPoint("TOPLEFT", WowMobileBand, "TOPLEFT", 0, 0)
	view:SetPoint("BOTTOMRIGHT", WowMobileBand, "BOTTOMRIGHT", 0, WM.Px(CTRL_H))

	closeButton = WM.CreateTouchButton(WorldMapFrame, 100, 96, "X", 44)
	closeButton:SetFrameStrata("FULLSCREEN_DIALOG") -- above every map overlay
	closeButton:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", 0, 0)
	closeButton:SetScript("OnClick", WorldMap.Close)
	BuildControls()

	-- Pinch over the map arrives as the mouse wheel.
	WorldMapFrame:EnableMouseWheel(true)
	WorldMapFrame:SetScript("OnMouseWheel", function()
		if arg1 > 0 then Zoom(1) else Zoom(-1) end
	end)

	-- Runs after Blizzard's own OnShow for the frame, so our geometry wins
	-- (manual wrap; no HookScript on 1.12). A magnified map reopens on the
	-- player.
	local origOnShow = WorldMapFrame:GetScript("OnShow")
	WorldMapFrame:SetScript("OnShow", function()
		if origOnShow then origOnShow() end
		WM.Deck.YieldTo("worldmap")
		if zoomIndex > 1 then
			Reflow() -- position first so the player point can be measured
			CenterOnPlayer()
		end
		Reflow()
		PadPOIHitRects()
	end)
	-- Whatever closed the map (our X, Esc, the M key from the phone), the
	-- UI must come back: the fullscreen-panel path may have hidden UIParent.
	local origOnHide = WorldMapFrame:GetScript("OnHide")
	WorldMapFrame:SetScript("OnHide", function()
		if origOnHide then origOnHide() end
		if not UIParent:IsShown() then
			UIParent:Show()
		end
		if WM.RefreshMinimap then WM.RefreshMinimap() end
	end)

	-- POIs are re-laid-out whenever the displayed map changes (another zone
	-- picked in the dropdowns, or zoomed out with a right click): re-pad.
	WM.On("WORLD_MAP_UPDATE", function()
		if WorldMapFrame:IsShown() then PadPOIHitRects() end
	end)

	WM.Deck.RegisterExclusive("worldmap", WorldMap.Close)
end)
