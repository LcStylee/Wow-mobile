--------------------------------------------------------------------------------
-- WowMobile · QuickBar
-- Six large utility buttons (mount, hearthstone, food, ...) as a
-- semi-transparent column on the right edge of the world square — reachable
-- without looking away from the world, opposite the stance column. Backed by
-- action slots 49..54 (MultiBarBottomRight's first half), so the user assigns
-- them from the spellbook/bags like any other action slot.
-- World-square rule from the architecture doc: tap/long-press operable only —
-- these are plain tap targets, satisfied by SecureActionButtonTemplate.
--------------------------------------------------------------------------------

local _, WM = ...

local FIRST_SLOT = 49 -- MultiBarBottomRight slots 49..60; we surface the first 6
local SIZE = 96
local GAP = 8

WM.OnInit(function()
	local column = CreateFrame("Frame", "WowMobileQuickBar", WM.WorldSquare)
	-- Right-edge layout contract (full budget table in Minimap.lua): the
	-- minimap cluster owns y<=330 of the square's right edge and the party
	-- frames own y>=330 for x<=960 (Blizzard.lua), so this column
	-- (x 976..1072) starts at y=336 — its six slots end at y=952, and no
	-- interactive frame overlaps another on the right edge. Any module that
	-- moves must keep those ranges disjoint.
	column:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT", -WM.Px(8), -WM.Px(336))
	column:SetSize(WM.Px(SIZE), WM.Px((SIZE + GAP) * 6))
	column:SetAlpha(0.88) -- keep the world readable behind the column

	-- Secure button creation/anchoring: queued for the mid-combat-login case.
	WM.OutOfCombat("quickbar-build", function()
		for i = 1, 6 do
			local b = WM.ActionBars.CreateButton("WowMobileQuickButton" .. i, column,
				FIRST_SLOT + i - 1, SIZE, SIZE)
			b:SetPoint("TOP", 0, -WM.Px((i - 1) * (SIZE + GAP)))
		end
	end)
end)
