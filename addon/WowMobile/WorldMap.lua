--------------------------------------------------------------------------------
-- WowMobile · WorldMap
-- The map becomes a touch panel over the control deck, per ARCHITECTURE §4
-- ("map becomes a fullscreen touch panel in the control deck"). It cannot be
-- rebuilt from scratch — map canvas + pin logic stay Blizzard's — so
-- WorldMapFrame is scaled over the deck rect instead of living in a
-- Deck.CreatePanel. Deck placement also matters for input (§5): the client
-- maps deck touches to plain taps, while world-square touches carry the
-- camera-drag gesture, so map taps land as clean left clicks. Adds a big
-- close button, pads pin hit rects toward touch size, and coordinates with
-- the deck exclusives so map / panels / bottom sheet never stack. Always
-- closes cleanly via HideUIPanel.
--------------------------------------------------------------------------------

local _, WM = ...

local WorldMap = {}
WM.WorldMap = WorldMap

local closeButton

-- Blizzard's pin art is mouse-sized (~30 physical px after the deck fit) and
-- each pin's hit rect matches its art. The art cannot grow without drowning
-- the map, but the hit rect can: pad every pin by 10 units per side (~40
-- extra physical px of touch area at the ~0.6 deck scale) so POIs and flight
-- masters land under a thumb — the same trick Blizzard.lua uses for taxi
-- nodes. Classic Era 1.15 ships the retail-lineage MapCanvas map, so pins
-- enumerate via MapCanvasMixin:EnumerateAllPins; guarded in case a future
-- build changes the mixin.
local function PadPinHitRects()
	local map = WorldMapFrame
	if not map.EnumerateAllPins then return end
	for pin in map:EnumerateAllPins() do
		if pin.SetHitRectInsets then
			pin:SetHitRectInsets(-10, -10, -10, -10)
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
	-- Fit the deck rect in both axes. The classic map is wider than the deck
	-- is tall, so the width ratio usually wins: ~1080x810 px of the 1080x840
	-- deck, leaving only a sliver of the bottom row uncovered.
	local scale = math.min(
		WM.Deck:GetWidth() / map:GetWidth(),
		WM.Deck:GetHeight() / map:GetHeight())
	map:SetScale(scale)
	map:ClearAllPoints()
	-- Anchor offsets are in the map's own (scaled) space; zero offsets keep
	-- the math trivial.
	map:SetPoint("TOP", WM.Deck, "TOP", 0, 0)
	-- Our close button lives inside the scaled frame: compensate so it stays
	-- ~100x96 physical px (>=90 px touch targets, ARCHITECTURE §4).
	closeButton:SetSize(WM.Px(100) / scale, WM.Px(96) / scale)
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

	-- Runs after Blizzard's own UIPanel positioning for the frame, so our
	-- anchors win; queued because the reflow happens while the panel system
	-- may be mid-combat-restricted.
	WorldMapFrame:HookScript("OnShow", function()
		WM.Deck.YieldTo("worldmap")
		WM.OutOfCombat("worldmap", function()
			if WorldMapFrame:IsShown() then
				Reflow()
				PadPinHitRects()
			end
		end)
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
