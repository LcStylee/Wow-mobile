--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Minimap
-- The client's own minimap, untouched inside its own MinimapCluster (border,
-- zone text, mail / tracking / day-night icons, and on Turtle WoW its extra
-- buttons), moved into the top-right corner of the world square and sized
-- with one SetScale on the cluster. Big +/- zoom buttons sit beneath it, and
-- a pinch over the map (mouse wheel) zooms too.
--
-- v0.6.5 (Turtle WoW field reports v0.6.0..v0.6.4: the map "blacked out",
-- then drew one top-down picture and never moved): every earlier version
-- pulled Minimap out of its cluster and re-parented it into an addon frame.
-- No reparenting any more — the Minimap frame keeps the parent, size,
-- strata and anchor the client gave it; only its cluster moves and scales,
-- the way a user-scaled default minimap works.
--
-- Right-edge budget of the world square (design px from the square's top, at
-- the default 1080-px square height). Interactive touch targets, so these
-- y-ranges MUST stay disjoint — QuickBar.lua and the party-frame re-home in
-- Blizzard.lua anchor against this table:
--   y  10..200  minimap (map centred in x 880..1070; the cluster's zone
--               text and border art reach a little further out)
--   y 206..298  zoom buttons     (x 844..1070)
--   y 330..1050 party frames     (x ..960, Blizzard.lua)
--   y 336..952  quick-bar column (x 976..1072, QuickBar.lua)
-- The aura rows approach from the left and must end left of these columns:
--   y  10..94   buff row ends at x=876  (Auras.lua)
--   y 124..208  debuff row ends at x=806 (Auras.lua)
--------------------------------------------------------------------------------

local WM = WowMobile

local MAP_SIZE = 190 -- on-screen map diameter (design px)

local function Zoom(delta)
	local zoom = Minimap:GetZoom() + delta
	if zoom < 0 then zoom = 0 end
	local max = Minimap:GetZoomLevels() - 1
	if zoom > max then zoom = max end
	Minimap:SetZoom(zoom)
end

-- Nudge the map into redrawing (a zoom step out and back) after the world
-- map's fullscreen mode hid and re-showed UIParent. Cheap; called on world
-- entry and whenever the world map closes (WorldMap.lua).
function WM.RefreshMinimap()
	if not Minimap or not Minimap.GetZoom then return end
	local z = Minimap:GetZoom()
	local max = Minimap:GetZoomLevels() - 1
	if z < max then
		Minimap:SetZoom(z + 1)
	elseif z > 0 then
		Minimap:SetZoom(z - 1)
	end
	Minimap:SetZoom(z)
end

WM.On("PLAYER_ENTERING_WORLD", function() WM.RefreshMinimap() end)

-- The cluster's own placement, captured before the move (for /wm minimap
-- blizzard), and the Minimap centre's offset from the cluster's top-right
-- corner in cluster units (measured, so any client's XML layout works).
local original
local centerDX, centerDY = 87, 92 -- 1.12 XML values; replaced by the measurement
local holder

local function Measure()
	local point, rel, relPoint, x, y = MinimapCluster:GetPoint(1)
	original = { point = point, rel = rel, relPoint = relPoint, x = x, y = y,
		scale = MinimapCluster:GetScale() }
	local right, top = MinimapCluster:GetRight(), MinimapCluster:GetTop()
	local mx, my = Minimap:GetCenter()
	if right and top and mx and my then
		-- Same units: Minimap is the cluster's child at the cluster's scale.
		local s = Minimap:GetEffectiveScale() / MinimapCluster:GetEffectiveScale()
		centerDX = right - mx * s
		centerDY = top - my * s
	end
end

local function PlaceInPhone()
	MinimapCluster:SetParent(UIParent)
	MinimapCluster:Show()
	MinimapCluster:SetFrameStrata("LOW")
	-- Map diameter in UI units -> cluster scale (the map is the cluster's
	-- child, so it scales along; its own size stays native).
	local scale = WM.Px(MAP_SIZE) / Minimap:GetWidth()
	MinimapCluster:SetScale(scale)
	MinimapCluster:ClearAllPoints()
	-- Offsets are in the cluster's own (scaled) units: the measured
	-- centre offset puts the map's centre on the holder's centre.
	MinimapCluster:SetPoint("TOPRIGHT", holder, "CENTER", centerDX, centerDY)
end

local function RestoreBlizzard()
	if not original then return end
	MinimapCluster:SetScale(original.scale or 1)
	MinimapCluster:ClearAllPoints()
	if original.point then
		MinimapCluster:SetPoint(original.point, original.rel, original.relPoint, original.x, original.y)
	end
	MinimapCluster:Show()
end

local function PrintState()
	local px, py = GetPlayerMapPosition("player")
	local parent = Minimap:GetParent()
	WM.Print(string.format("minimap: visible=%s parent=%s size=%.0fx%.0f eff=%.2f zoom=%d strata=%s cluster scale=%.2f",
		tostring(Minimap:IsVisible()), (parent and parent:GetName()) or "?",
		Minimap:GetWidth(), Minimap:GetHeight(), Minimap:GetEffectiveScale(),
		Minimap:GetZoom(), Minimap:GetFrameStrata(), MinimapCluster:GetScale()))
	WM.Print(string.format("minimap: player at %.3f, %.3f on the zone map (walk and run this again: the numbers should change)",
		px or 0, py or 0))
end

-- `/wm minimap` prints the map's live state; `/wm minimap blizzard` puts
-- the cluster back where and how the client had it, `/wm minimap phone`
-- returns it to the phone layout.
function WM.MinimapCommand(arg)
	if arg == "blizzard" then
		RestoreBlizzard()
		WM.Print("minimap: back in the client's own spot (top right of the screen). /wm minimap phone puts it back.")
	elseif arg == "phone" then
		PlaceInPhone()
		WM.Print("minimap: back in the phone layout")
	else
		PrintState()
		WM.Print("minimap: /wm minimap blizzard = client's own placement, /wm minimap phone = phone layout")
	end
end

WM.OnInit(function()
	if not MinimapCluster or not Minimap then return end
	-- The map's box in the phone layout (no art of its own, never takes the
	-- mouse: taps reach the real map, which keeps its default ping).
	holder = CreateFrame("Frame", "WowMobileMinimapHolder", WM.WorldSquare)
	holder:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT", -WM.Px(10), -WM.Px(56))
	holder:SetWidth(WM.Px(MAP_SIZE))
	holder:SetHeight(WM.Px(MAP_SIZE))
	holder:EnableMouse(false)

	Measure()
	PlaceInPhone()

	Minimap:EnableMouseWheel(true)
	Minimap:SetScript("OnMouseWheel", function() Zoom(arg1) end)

	-- Big zoom buttons directly below the map (the default nubs are far too
	-- small for a thumb). 110x92 keeps them on the >=90 px touch bar; per the
	-- budget table above they end at y=298, clear of the party frames' range
	-- (y>=330).
	local zoomIn = WM.CreateTouchButton(holder, 110, 92, "+", 40)
	zoomIn:SetPoint("TOPRIGHT", holder, "BOTTOMRIGHT", 0, -WM.Px(6))
	zoomIn:SetScript("OnClick", function() Zoom(1) end)

	local zoomOut = WM.CreateTouchButton(holder, 110, 92, "-", 40)
	zoomOut:SetPoint("TOPRIGHT", zoomIn, "TOPLEFT", -WM.Px(6), 0)
	zoomOut:SetScript("OnClick", function() Zoom(-1) end)
end)
