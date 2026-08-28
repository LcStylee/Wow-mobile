--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · WorldMap
-- The map becomes a touch panel over the control deck. It cannot be rebuilt
-- from scratch — map canvas + POI logic stay Blizzard's — so WorldMapFrame is
-- scaled over the deck rect instead of living in a Deck.CreatePanel. Deck
-- placement also matters for input: the client maps deck touches to plain
-- taps, while world-square touches carry the camera-drag gesture, so map taps
-- land as clean left clicks.
--
-- On 1.12 the map is a fullscreen frame anchored over the whole screen in
-- XML, so the reflow must ClearAllPoints and give it back its design size
-- (1024x768) before scaling — the same shrink technique the vanilla map
-- addons used. POIs are the lazily created WorldMapFramePOI1..N buttons,
-- re-padded on WORLD_MAP_UPDATE.
--------------------------------------------------------------------------------

local WM = WowMobile

local WorldMap = {}
WM.WorldMap = WorldMap

local MAP_W, MAP_H = 1024, 768 -- 1.12 WorldMapFrame design size

local closeButton

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

local function Reflow()
	local map = WorldMapFrame
	-- Strip the fullscreen anchors and restore the design size so SetScale
	-- has something to scale (a both-corners-anchored frame ignores it).
	map:ClearAllPoints()
	map:SetWidth(MAP_W)
	map:SetHeight(MAP_H)
	-- Fit the deck rect in both axes (sizes compared in UI units at the
	-- map's scale 1).
	local scale = math.min(
		WM.Deck:GetWidth() / MAP_W,
		WM.Deck:GetHeight() / MAP_H)
	map:SetScale(scale)
	-- Anchor offsets are in the map's own (scaled) space; zero offsets keep
	-- the math trivial.
	map:SetPoint("TOP", WM.Deck, "TOP", 0, 0)
	map:SetFrameStrata("HIGH")
	-- Our close button lives inside the scaled frame: compensate so it stays
	-- ~100x96 physical px (>=90 px touch targets).
	closeButton:SetWidth(WM.Px(100) / scale)
	closeButton:SetHeight(WM.Px(96) / scale)
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

function WorldMap.Close()
	if WorldMapFrame:IsShown() then
		-- The 1.12 map is not a managed UIPanel; Hide() is the direct and
		-- safe close (its OnHide handler does the world-state cleanup).
		WorldMapFrame:Hide()
	end
end

WM.OnInit(function()
	closeButton = WM.CreateTouchButton(WorldMapFrame, 100, 96, "X", 44)
	closeButton:SetFrameStrata("FULLSCREEN_DIALOG") -- above every map overlay
	closeButton:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", 0, 0)
	closeButton:SetScript("OnClick", WorldMap.Close)

	-- Runs after Blizzard's own OnShow for the frame, so our geometry wins
	-- (manual wrap; no HookScript on 1.12).
	local origOnShow = WorldMapFrame:GetScript("OnShow")
	WorldMapFrame:SetScript("OnShow", function()
		if origOnShow then origOnShow() end
		WM.Deck.YieldTo("worldmap")
		Reflow()
		PadPOIHitRects()
	end)

	-- POIs are re-laid-out whenever the displayed map changes; re-pad after
	-- Blizzard's own WORLD_MAP_UPDATE handler has run (it registered at
	-- load, so it dispatches before ours).
	WM.On("WORLD_MAP_UPDATE", function()
		if WorldMapFrame:IsShown() then PadPOIHitRects() end
	end)

	WM.Deck.RegisterExclusive("worldmap", WorldMap.Close)
end)
