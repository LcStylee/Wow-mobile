--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Minimap
-- Pulls the round Minimap out of the (banished) MinimapCluster and parks it in
-- the top-right corner of the world square, with big +/- zoom buttons and the
-- zone label stacked beneath it. Pinch over the map maps to mouse wheel on the
-- client, so wheel zoom is wired too.
--
-- Right-edge budget of the world square (design px from the square's top, at
-- the default 1080-px square height). Everything except the zone label is an
-- interactive touch target, so these y-ranges MUST stay disjoint —
-- QuickBar.lua and the party-frame re-home in Blizzard.lua anchor against
-- this table:
--   y  10..200  minimap holder   (x 880..1070)
--   y 206..298  zoom buttons     (x 844..1070)
--   y 302..330  zone label       (x 800..1070 — text only, never interactive)
--   y 330..1050 party frames     (x ..960, Blizzard.lua)
--   y 336..952  quick-bar column (x 976..1072, QuickBar.lua)
-- The aura rows approach from the left and must end left of these columns:
--   y  10..94   buff row ends at x=876  (Auras.lua)
--   y 124..208  debuff row ends at x=806 (Auras.lua)
--------------------------------------------------------------------------------

local WM = WowMobile

local MAP_SIZE = 190 -- sized so map + zoom + zone end above the party frames (y>=330)
local NATIVE_SIZE = 140 -- 1.12 Minimap's XML size (see the SetScale note below)

local function Zoom(delta)
	local zoom = Minimap:GetZoom() + delta
	if zoom < 0 then zoom = 0 end
	local max = Minimap:GetZoomLevels() - 1
	if zoom > max then zoom = max end
	Minimap:SetZoom(zoom)
end

-- Nudge the map into redrawing (a zoom step out and back): the 1.12 client
-- can stop drawing a reparented Minimap after UIParent was hidden and shown
-- again — exactly what the fullscreen world map does (field report v0.6.0,
-- "the map top right is blacked out"). Cheap; called on world entry and
-- whenever the world map closes (WorldMap.lua).
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
	Minimap:Show()
end

WM.On("PLAYER_ENTERING_WORLD", function() WM.RefreshMinimap() end)

-- Field diagnosis (v0.6.3; Turtle WoW report: the map draws one top-down
-- picture of the terrain and then never moves). `/wm minimap` prints the
-- map's live state; `/wm minimap blizzard` puts the map back exactly where
-- and how the client had it (inside MinimapCluster) and `/wm minimap phone`
-- returns it to the phone layout — if the map moves in Blizzard's spot but
-- not in ours, the re-homing is the cause; if it is frozen there too, it is
-- the client or the capture.
local original -- the client's own placement, captured before the re-home
local placeInPhone -- set in OnInit

local function SavePlacement()
	local point, rel, relPoint, x, y = Minimap:GetPoint(1)
	original = {
		parent = Minimap:GetParent(), point = point, rel = rel,
		relPoint = relPoint, x = x, y = y,
		w = Minimap:GetWidth(), h = Minimap:GetHeight(),
		scale = Minimap:GetScale(), strata = Minimap:GetFrameStrata(),
		level = Minimap:GetFrameLevel(),
	}
end

local function RestoreBlizzard()
	if not original then return end
	if MinimapCluster then
		-- Blizzard.lua banished the cluster before this module loaded, so
		-- its own parent is not recorded: on 1.12 it is UIParent.
		MinimapCluster:SetParent(UIParent)
		MinimapCluster:Show()
	end
	Minimap:SetParent(original.parent)
	Minimap:SetScale(original.scale or 1)
	Minimap:SetWidth(original.w)
	Minimap:SetHeight(original.h)
	Minimap:SetFrameStrata(original.strata)
	Minimap:SetFrameLevel(original.level)
	Minimap:ClearAllPoints()
	if original.point then
		Minimap:SetPoint(original.point, original.rel, original.relPoint, original.x, original.y)
	end
	Minimap:Show()
end

local function PrintState()
	local px, py = GetPlayerMapPosition("player")
	local parent = Minimap:GetParent()
	WM.Print(string.format("minimap: visible=%s parent=%s size=%.0fx%.0f scale=%.2f eff=%.2f zoom=%d strata=%s level=%d alpha=%.2f",
		tostring(Minimap:IsVisible()), (parent and parent:GetName()) or "?",
		Minimap:GetWidth(), Minimap:GetHeight(), Minimap:GetScale(),
		Minimap:GetEffectiveScale(), Minimap:GetZoom(), Minimap:GetFrameStrata(),
		Minimap:GetFrameLevel(), Minimap:GetAlpha()))
	WM.Print(string.format("minimap: player at %.3f, %.3f on the zone map (walk and run this again: the numbers should change)",
		px or 0, py or 0))
end

function WM.MinimapCommand(arg)
	if arg == "blizzard" then
		RestoreBlizzard()
		WM.Print("minimap: back in the client's own spot (top right of the screen, outside the phone frame). Does it move there? /wm minimap phone puts it back.")
	elseif arg == "phone" then
		if placeInPhone then placeInPhone() end
		WM.Print("minimap: back in the phone layout")
	else
		PrintState()
		WM.Print("minimap: /wm minimap blizzard = client's own placement (test), /wm minimap phone = phone layout")
	end
end

WM.OnInit(function()
	local holder = CreateFrame("Frame", "WowMobileMinimapHolder", WM.WorldSquare)
	-- Below the target's aura row (it hangs ~44 px under the top HUD).
	holder:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT", -WM.Px(10), -WM.Px(56))
	holder:SetWidth(WM.Px(MAP_SIZE))
	holder:SetHeight(WM.Px(MAP_SIZE))
	-- No backdrop (v0.6.1): the world renders full window behind the map now,
	-- and an opaque square here is exactly what showed as a "blacked-out
	-- minimap" whenever the map itself did not draw (field report v0.6.0).
	-- The holder sits on LOW strata so the reparented map draws above the
	-- world-square overlays, not under them.
	holder:SetFrameStrata("LOW")

	SavePlacement()
	placeInPhone = function()
		if MinimapCluster then WM.BanishFrame(MinimapCluster, true) end
		Minimap:SetParent(holder)
		Minimap:SetFrameStrata("LOW")
		Minimap:SetFrameLevel(holder:GetFrameLevel() + 1)
		Minimap:ClearAllPoints()
		Minimap:SetWidth(NATIVE_SIZE)
		Minimap:SetHeight(NATIVE_SIZE)
		Minimap:SetScale(WM.Px(MAP_SIZE) / NATIVE_SIZE)
		Minimap:SetPoint("CENTER", holder, "CENTER", 0, 0)
		Minimap:Show()
	end
	Minimap:SetParent(holder)
	Minimap:SetFrameStrata("LOW")
	Minimap:SetFrameLevel(holder:GetFrameLevel() + 1)
	Minimap:ClearAllPoints()
	-- Size through SetScale, never SetWidth/SetHeight (v0.6.2): the 1.12
	-- engine renders the minimap terrain for its native 140x140 box only — a
	-- resized Minimap stops drawing or freezes on one image (field reports
	-- v0.6.0 "blacked out", v0.6.1 "not moving"). This is how the vanilla
	-- minimap addons sized it. CENTER with zero offsets is scale-proof.
	Minimap:SetWidth(NATIVE_SIZE)
	Minimap:SetHeight(NATIVE_SIZE)
	Minimap:SetScale(WM.Px(MAP_SIZE) / NATIVE_SIZE)
	Minimap:SetPoint("CENTER", holder, "CENTER", 0, 0)
	Minimap:EnableMouse(true) -- tap = ping, default behavior
	-- 1.12 XML parentage of MiniMapMailFrame (Minimap vs MinimapCluster) is
	-- ambiguous across clients; if it rides along with the reparented Minimap
	-- it would duplicate the addon's flat mail badge, so banish it outright —
	-- correct regardless of which parent the client's FrameXML used.
	if MiniMapMailFrame then WM.BanishFrame(MiniMapMailFrame) end
	Minimap:EnableMouseWheel(true)
	Minimap:SetScript("OnMouseWheel", function() Zoom(arg1) end)

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
	-- holder's top edge is only 10 px below the screen top, so a label up
	-- there would render almost entirely off-screen and be clipped.
	local zone = WM.CreateText(holder, 24, "OUTLINE")
	zone:SetPoint("TOPRIGHT", zoomIn, "BOTTOMRIGHT", 0, -WM.Px(4))
	zone:SetWidth(WM.Px(MAP_SIZE + 80))
	zone:SetJustifyH("CENTER")
	WM.SingleLine(zone, 24)

	local function UpdateZone()
		zone:SetText(GetMinimapZoneText() or "")
	end
	UpdateZone()
	WM.On("ZONE_CHANGED", UpdateZone)
	WM.On("ZONE_CHANGED_INDOORS", UpdateZone)
	WM.On("ZONE_CHANGED_NEW_AREA", UpdateZone)

	-- New-mail indicator: MiniMapMailFrame was banished with MinimapCluster,
	-- so a flat badge on the holder takes over. It occupies the holder's
	-- top-left corner deadspace outside the round map. Plain Frame,
	-- mouse-disabled by default: taps pass through to the map ping. The
	-- reparented Minimap keeps its Blizzard strata, so the badge is lifted
	-- above it explicitly.
	local mail = CreateFrame("Frame", "WowMobileMailBadge", holder)
	mail:SetWidth(WM.Px(64))
	mail:SetHeight(WM.Px(36))
	mail:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
	mail:SetFrameStrata("MEDIUM")
	WM.SkinFrame(mail, { 0.09, 0.09, 0.11, 0.92 }, WM.Colors.accent)
	local mailText = WM.CreateText(mail, 22, "OUTLINE")
	mailText:SetPoint("CENTER", mail, "CENTER", 0, 0)
	mailText:SetText("Mail")
	mailText:SetTextColor(1, 0.82, 0)
	mail:Hide()

	local function UpdateMail()
		WM.SetShown(mail, HasNewMail())
	end
	UpdateMail()
	WM.On("UPDATE_PENDING_MAIL", UpdateMail)
	WM.On("MAIL_CLOSED", UpdateMail) -- HasNewMail flips as inbox mail is read
	WM.On("PLAYER_ENTERING_WORLD", UpdateMail)
end)
