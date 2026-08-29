--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Inspect
-- Touch inspect panel: the inspected player's equipped items as a big grid
-- with tooltips, plus name/level/class/guild.
--
-- Entry point: the long-press unit menus (the boosted dropdowns) carry
-- Blizzard's own "Inspect" option — for the current target AND for party
-- members (1.12's UnitPopupMenus["PARTY"] includes INSPECT, so the call can
-- arrive with "party1".."party4" as well as "target"). On 1.12 that option
-- runs through the GLOBAL InspectUnit(unit) — UIParent.lua's stub that
-- load-on-demands Blizzard_InspectUI and shows InspectFrame. This module
-- REPLACES the global at init (plain replacement; no hooksecurefunc and no
-- protection on 1.12), so the menu opens the touch panel for WHATEVER unit
-- was asked (stored; the panel paints from that unit's inventory functions —
-- Blizzard_InspectUI itself reads GetInventoryItemLink(InspectFrame.unit,
-- slot) for party units after NotifyInspect(unit), so non-target units are
-- fully supported by the C API). The LoD addon is normally never loaded at
-- all. Belt-and-braces: if some other addon force-loads Blizzard_InspectUI
-- anyway, its ADDON_LOADED both re-asserts our InspectUnit (the LoD addon
-- redefines the global as it loads) and banishes InspectFrame.
--
-- PLATFORM HONESTY (the panel says so on screen): 1.12 has NO INSPECT_READY
-- event. NotifyInspect(unit) asks the server to stream that unit's item
-- data; the unit-inventory functions on the inspected unit then start
-- answering — but
-- there is no signal for "all data arrived", and out of inspect range (~10yd)
-- or if the target is lost, nothing ever arrives. The panel therefore
-- repaints on a short delay ladder (0.4 s / 1.2 s / 2.5 s) after every
-- NotifyInspect and shows whatever the client has; empty cells past the last
-- repaint mean the server sent nothing for that slot. Degrading honestly
-- beats pretending at completeness.
--------------------------------------------------------------------------------

local WM = WowMobile

-- Paper-doll order, 4x5 grid — the CharacterPanel gear-tab layout, minus
-- MoveMode (you cannot move another player's items) and durability (not
-- readable on other units).
local SLOTS = {
	{ "HeadSlot", "Head" },       { "NeckSlot", "Neck" },
	{ "ShoulderSlot", "Shoulder" },{ "BackSlot", "Back" },
	{ "ChestSlot", "Chest" },     { "ShirtSlot", "Shirt" },
	{ "TabardSlot", "Tabard" },   { "WristSlot", "Wrist" },
	{ "HandsSlot", "Hands" },     { "WaistSlot", "Waist" },
	{ "LegsSlot", "Legs" },       { "FeetSlot", "Feet" },
	{ "Finger0Slot", "Ring 1" },  { "Finger1Slot", "Ring 2" },
	{ "Trinket0Slot", "Trinket 1" },{ "Trinket1Slot", "Trinket 2" },
	{ "MainHandSlot", "Main Hand" },{ "SecondaryHandSlot", "Off Hand" },
	{ "RangedSlot", "Ranged" },
}

local COLS = 4
-- Height budget: header line (60) + 5 rows at CELL+GAP pitch = 60 +
-- 5*(116+8)-8 = 672 <= 678 px content at the tightest Config ratio; 116 px
-- cells still clear the 90 px touch floor.
local CELL = 116
local GAP = 8

local panel
local slotCells = {}
local headerText, noteText
local refreshToken = 0
local inspectUnit = "target" -- the unit the panel was opened FOR (see header)

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

local function HaveInspectTarget()
	return UnitExists(inspectUnit) and UnitIsPlayer(inspectUnit)
end

local function Paint()
	if not panel:IsShown() then return end
	if not HaveInspectTarget() then
		headerText:SetText("No player to inspect.")
		noteText:SetText("Target a player (or long-press a party member), " ..
			"then pick Inspect from the unit menu.")
		for i = 1, table.getn(SLOTS) do
			slotCells[i]:Hide()
		end
		return
	end
	local name = UnitName(inspectUnit) or "?"
	local level = UnitLevel(inspectUnit) or 0
	local class = UnitClass(inspectUnit) or ""
	local guild = GetGuildInfo and GetGuildInfo(inspectUnit) or nil
	local r, g, b = WM.UnitColor(inspectUnit)
	headerText:SetText(string.format("|cff%02x%02x%02x%s|r  —  level %d %s%s",
		r * 255, g * 255, b * 255, name, level, class,
		guild and ("  ·  <" .. guild .. ">") or ""))
	noteText:SetText("Item data streams from the server (no ready signal on " ..
		"1.12) — slots fill in over a moment; blanks mean nothing was sent " ..
		"(out of range, or the slot is empty).")
	for i = 1, table.getn(SLOTS) do
		local cell = slotCells[i]
		local texture = GetInventoryItemTexture(inspectUnit, cell.slotID)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetVertexColor(1, 1, 1)
		else
			cell.icon:SetTexture(WM.TEX_WHITE)
			cell.icon:SetVertexColor(0.14, 0.14, 0.17)
		end
		cell:Show()
	end
end

-- Ask the server for the target's data and repaint on the delay ladder (see
-- the header). The token voids stale scheduled repaints when a newer request
-- (target switch, reopen) supersedes them.
local function RequestAndPaint()
	if not panel:IsShown() then return end
	if HaveInspectTarget() and NotifyInspect then
		NotifyInspect(inspectUnit)
	end
	Paint()
	refreshToken = refreshToken + 1
	local token = refreshToken
	local delays = { 0.4, 1.2, 2.5 }
	for i = 1, 3 do
		WM.After(delays[i], function()
			if token == refreshToken then Paint() end
		end)
	end
end

--------------------------------------------------------------------------------
-- Public open (also the InspectUnit replacement's landing point)
--------------------------------------------------------------------------------

function WM.InspectOpen(unit)
	-- Store the requested unit: the menus can ask for "target" OR a party
	-- unit (see the header), and the unit-inventory functions answer for
	-- whichever unit NotifyInspect was called with.
	inspectUnit = unit or "target"
	WM.Deck.Open("inspect")
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("inspect", "Inspect")

	headerText = WM.CreateText(panel.content, 32)
	headerText:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(4))
	headerText:SetJustifyH("LEFT")
	headerText:SetWidth(WM.Px(1040))
	WM.SingleLine(headerText, 32)

	for i = 1, table.getn(SLOTS) do
		local slotName, label = SLOTS[i][1], SLOTS[i][2]
		local cell = CreateFrame("Button", nil, panel.content)
		cell:SetWidth(WM.Px(CELL))
		cell:SetHeight(WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local col = math.mod(i - 1, COLS)
		local row = math.floor((i - 1) / COLS)
		cell:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
			WM.Px(col * (CELL + GAP)), -WM.Px(60 + row * (CELL + GAP)))
		local slotID = GetInventorySlotInfo(slotName)
		cell.slotID = slotID
		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetWidth(WM.Px(64))
		cell.icon:SetHeight(WM.Px(64))
		cell.icon:SetPoint("TOP", cell, "TOP", 0, -WM.Px(8))
		local nameFs = WM.CreateText(cell, 20)
		nameFs:SetPoint("BOTTOM", cell, "BOTTOM", 0, WM.Px(8))
		nameFs:SetText(label)
		nameFs:SetTextColor(0.7, 0.7, 0.75)
		cell.slotLabel = label
		-- Tooltip above the finger; the unit-inventory tooltip works on the
		-- inspected unit once the server has streamed that slot.
		WM.AttachTooltip(cell, function(tt, self)
			if HaveInspectTarget() and GetInventoryItemLink(inspectUnit, self.slotID) then
				tt:SetInventoryItem(inspectUnit, self.slotID)
			else
				tt:SetText(self.slotLabel)
			end
		end)
		slotCells[i] = cell
	end

	-- Note column right of the 4x5 grid.
	noteText = WM.CreateText(panel.content, 24)
	noteText:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
		WM.Px(COLS * (CELL + GAP) + 24), -WM.Px(70))
	noteText:SetPoint("TOPRIGHT", panel.content, "TOPRIGHT", -WM.Px(8), -WM.Px(70))
	noteText:SetJustifyH("LEFT")
	noteText:SetTextColor(0.7, 0.7, 0.75)

	panel.OnOpen = RequestAndPaint

	-- Replace UIParent.lua's LoD launcher (see the header): the target menu's
	-- Inspect option calls this global.
	function InspectUnit(unit)
		WM.InspectOpen(unit)
	end

	-- If another addon force-loads Blizzard_InspectUI, it redefines
	-- InspectUnit and raises InspectFrame (whose OnHide would also
	-- ClearInspectPlayer mid-session) — re-assert ours and banish the frame.
	WM.On("ADDON_LOADED", function(_, addonName)
		if addonName == "Blizzard_InspectUI" then
			function InspectUnit(unit)
				WM.InspectOpen(unit)
			end
			if InspectFrame then
				WM.BanishFrame(InspectFrame)
			end
		end
	end)

	-- A target switch mid-inspect re-requests for the new target (or clears
	-- the panel honestly if the target is gone / not a player) — but only
	-- when the panel is inspecting "target"; a party-member inspect is
	-- unaffected by the player's targeting.
	WM.On("PLAYER_TARGET_CHANGED", function()
		if panel:IsShown() and inspectUnit == "target" then RequestAndPaint() end
	end)
	-- The one live signal 1.12 does give: cached item records resolving can
	-- fire UNIT_INVENTORY_CHANGED for the inspected unit on some builds.
	WM.On("UNIT_INVENTORY_CHANGED", function(_, unit)
		if unit == inspectUnit and panel:IsShown() then Paint() end
	end)
end)
