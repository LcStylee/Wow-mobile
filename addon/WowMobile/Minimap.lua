--------------------------------------------------------------------------------
-- WowMobile · Minimap
-- Pulls the round Minimap out of the (banished) MinimapCluster and parks it in
-- the top-right corner of the world square, with big +/- zoom buttons and the
-- zone label stacked beneath it. Pinch over the map maps to mouse wheel on the
-- client, so wheel zoom is wired too.
--
-- Right-edge budget of the world square (design px from the square's top).
-- Everything except the zone label is an interactive touch target, so these
-- y-ranges MUST stay disjoint — QuickBar.lua and the party-frame re-home in
-- Blizzard.lua anchor against this table:
--   y  10..200  minimap holder   (x 880..1070; the round map's mouse-hit area
--                                 is the full holder square)
--   y 206..298  zoom buttons     (x 844..1070)
--   y 302..330  zone label       (x 800..1070 — text only, never interactive)
--   y 330..     party frames     (x ..960, Blizzard.lua)
--   y 336..952  quick-bar column (x 976..1072, QuickBar.lua)
--------------------------------------------------------------------------------

local _, WM = ...

local MAP_SIZE = 190 -- sized so map + zoom + zone end above the party frames (y>=330)

local function Zoom(delta)
	local zoom = Minimap:GetZoom() + delta
	if zoom < 0 then zoom = 0 end
	local max = Minimap:GetZoomLevels() - 1
	if zoom > max then zoom = max end
	Minimap:SetZoom(zoom)
end

WM.OnInit(function()
	local holder = CreateFrame("Frame", "WowMobileMinimapHolder", WM.WorldSquare)
	holder:SetPoint("TOPRIGHT", -WM.Px(10), -WM.Px(10))
	holder:SetSize(WM.Px(MAP_SIZE), WM.Px(MAP_SIZE))

	-- Minimap itself isn't protected, but reparenting stays queued for the
	-- log-in-during-combat edge case, like all layout of Blizzard frames.
	WM.OutOfCombat("minimap", function()
		Minimap:SetParent(holder)
		Minimap:ClearAllPoints()
		Minimap:SetPoint("CENTER")
		Minimap:SetSize(WM.Px(MAP_SIZE), WM.Px(MAP_SIZE))
		Minimap:EnableMouse(true) -- tap = ping, default behavior
		Minimap:EnableMouseWheel(true)
		Minimap:SetScript("OnMouseWheel", function(_, dir) Zoom(dir) end)
	end)

	-- Big zoom buttons directly below the map (the default nubs are far too
	-- small for a thumb and were banished with MinimapCluster's decorations).
	-- 110x92 keeps them on the >=90 px touch bar; per the budget table above
	-- they end at y=298, clear of the party frames' range (y>=330).
	local zoomIn = WM.CreateTouchButton(holder, 110, 92, "+", 40)
	zoomIn:SetPoint("TOPRIGHT", holder, "BOTTOMRIGHT", 0, -WM.Px(6))
	zoomIn:SetScript("OnClick", function() Zoom(1) end)

	local zoomOut = WM.CreateTouchButton(holder, 110, 92, "-", 40)
	zoomOut:SetPoint("TOPRIGHT", zoomIn, "TOPLEFT", -WM.Px(6), 0)
	zoomOut:SetScript("OnClick", function() Zoom(-1) end)

	-- Zone label at the BOTTOM of the cluster, never above the map: the
	-- holder's top edge is only 10 px below the screen top (the world square
	-- is anchored to the window top), so a label up there would render almost
	-- entirely off-screen and be clipped.
	local zone = WM.CreateText(holder, 24, "OUTLINE")
	zone:SetPoint("TOPRIGHT", zoomIn, "BOTTOMRIGHT", 0, -WM.Px(4))
	zone:SetWidth(WM.Px(MAP_SIZE + 80))
	zone:SetJustifyH("CENTER")
	zone:SetWordWrap(false)

	local function UpdateZone()
		zone:SetText(GetMinimapZoneText() or "")
	end
	UpdateZone()
	WM.On("ZONE_CHANGED", UpdateZone)
	WM.On("ZONE_CHANGED_INDOORS", UpdateZone)
	WM.On("ZONE_CHANGED_NEW_AREA", UpdateZone)
end)
