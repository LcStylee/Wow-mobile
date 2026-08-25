--------------------------------------------------------------------------------
-- WowMobile · Minimap
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
--   y  10..200  minimap holder   (x 880..1070; the round map's mouse-hit area
--                                 is the full holder square)
--   y 206..298  zoom buttons     (x 844..1070)
--   y 302..330  zone label       (x 800..1070 — text only, never interactive)
--   y 330..1050 party frames     (x ..960, Blizzard.lua)
--   y 336..952  quick-bar column (x 976..1072, QuickBar.lua)
-- The two open-ended rows are viewport-aware: on a reduced viewport.height
-- (Config bounds 648..~1130) the party frames rescale and the quick bar hides
-- tail slots so neither ever crosses the square's bottom into the control
-- deck (both re-solve via WM.Viewport.OnApply). This cluster's fixed rows all
-- end by y=330, inside even the 648 minimum.
-- The aura rows approach from the left and must end left of these columns:
--   y  10..94   buff row ends at x=876  (Auras.lua — clear of the holder)
--   y 124..208  debuff row ends at x=806 (Auras.lua — clear of the zoom
--                                 buttons)
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

	-- New-mail indicator: MiniMapMailFrame was banished with MinimapCluster,
	-- so a flat badge on the holder takes over. It occupies the holder's
	-- top-left corner deadspace outside the round map — 64x36 px at holder
	-- TOPLEFT = screen x 880..944, y 10..46, inside the holder's own budget
	-- cell (x 880..1070, y 10..200 in the table above), so no other
	-- right-edge range is touched. Plain Frame, mouse-disabled by default:
	-- taps pass through to the map ping. The reparented Minimap keeps its
	-- Blizzard strata, so the badge is lifted above it explicitly.
	local mail = CreateFrame("Frame", "WowMobileMailBadge", holder)
	mail:SetSize(WM.Px(64), WM.Px(36))
	mail:SetPoint("TOPLEFT")
	mail:SetFrameStrata("MEDIUM")
	WM.SkinFrame(mail, { 0.09, 0.09, 0.11, 0.92 }, WM.Colors.accent)
	local mailText = WM.CreateText(mail, 22, "OUTLINE")
	mailText:SetPoint("CENTER")
	mailText:SetText("Mail")
	mailText:SetTextColor(1, 0.82, 0)
	mail:Hide()

	local function UpdateMail()
		if HasNewMail() then mail:Show() else mail:Hide() end
	end
	UpdateMail()
	WM.On("UPDATE_PENDING_MAIL", UpdateMail)
	WM.On("MAIL_CLOSED", UpdateMail) -- HasNewMail flips as inbox mail is read
	WM.On("PLAYER_ENTERING_WORLD", UpdateMail)
end)
