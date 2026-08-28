--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · QuickBar
-- Six large utility buttons (mount, hearthstone, food, ...) as a
-- semi-transparent column on the right edge of the world square — reachable
-- without looking away from the world, opposite the stance column. Backed by
-- action slots 49..54 (MultiBarBottomRight's first half on 1.12), so the user
-- assigns them from the spellbook/bags like any other action slot.
--------------------------------------------------------------------------------

local WM = WowMobile

local FIRST_SLOT = 49 -- MultiBarBottomRight slots 49..60; we surface the first 6
local SLOTS = 6
local SIZE = 96
local GAP = 8
local TOP = 336 -- column top, design px from the square's top (budget below)

local buttons = {}

-- The square's height is a supported knob (viewport.height, Config bounds
-- 648..~1130): slots anchored from the square's TOP would overhang the
-- control deck on a reduced square and steal deck taps. Slot i's bottom edge
-- sits at TOP + i*(SIZE+GAP) - GAP px from the square's top; keep only the
-- slots whose bottom stays inside the square:
-- n = floor((h - TOP + GAP)/(SIZE+GAP)) = floor((h - 328)/104).
-- h=1080 -> 7.2 -> capped 6 (bottom 952); h=648 (RATIO_MIN) -> 3 (bottom 640).
local function SyncToViewport(heightPx)
	local n = math.floor((heightPx - TOP + GAP) / (SIZE + GAP))
	if n > SLOTS then n = SLOTS end
	for i = 1, table.getn(buttons) do
		WM.SetShown(buttons[i], i <= n)
	end
end

WM.OnInit(function()
	local column = CreateFrame("Frame", "WowMobileQuickBar", WM.WorldSquare)
	-- Right-edge layout contract (full budget table in Minimap.lua): the
	-- minimap cluster owns y<=330 of the square's right edge and the party
	-- frames own y>=330 for x<=960 (Blizzard.lua), so this column
	-- (x 976..1072) starts at y=336 — its six slots end at y=952 on the
	-- default 1080 square (fewer on smaller squares, SyncToViewport above),
	-- and no interactive frame overlaps another on the right edge.
	column:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT", -WM.Px(8), -WM.Px(TOP))
	column:SetWidth(WM.Px(SIZE))
	column:SetHeight(WM.Px((SIZE + GAP) * SLOTS))
	column:SetAlpha(0.88) -- keep the world readable behind the column

	WM.Viewport.OnApply(SyncToViewport)

	for i = 1, SLOTS do
		local b = WM.ActionBars.CreateButton("WowMobileQuickButton" .. i, column,
			FIRST_SLOT + i - 1, SIZE, SIZE)
		b:SetPoint("TOP", column, "TOP", 0, -WM.Px((i - 1) * (SIZE + GAP)))
		buttons[i] = b
	end
	SyncToViewport(WM.Viewport.HeightPx())
end)
