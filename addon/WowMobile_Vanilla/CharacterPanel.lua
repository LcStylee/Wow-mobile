--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · CharacterPanel
-- Deck-filling character sheet: equipped item grid (tap/hover = tooltip, with
-- per-slot durability bars) on the left, core stats on the right, overall
-- durability at the bottom of the stat column.
--------------------------------------------------------------------------------

local WM = WowMobile

-- Paper-doll order, laid out as a 4x5 grid. Labels are our own short names.
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
-- Height budget: 19 slots in 4 columns = 5 rows -> 5*(CELL+GAP)-GAP = 672 px;
-- the panel content region is at least 678 px at the tightest Config ratio,
-- so the fifth row (Main Hand / Off Hand / Ranged) always fits on screen.
local CELL = 128
local GAP = 8

local panel
local slotCells = {}
local statRows = {}
local durabilityText

--------------------------------------------------------------------------------
-- Stats
-- Each row: label + value closure. pcall-guarded so a build lacking an API
-- simply omits that row instead of erroring. 1.12: UnitStat's 2nd return is
-- the effective stat; UnitArmor's 2nd return the effective armor; there is no
-- GetCritChance/GetRangedCritChance (those rows self-omit here — melee/ranged
-- crit is only visible in tooltips on this client).
--------------------------------------------------------------------------------

local STAT_DEFS = {
	{ "Strength",  function() local _, v = UnitStat("player", 1) return v end },
	{ "Agility",   function() local _, v = UnitStat("player", 2) return v end },
	{ "Stamina",   function() local _, v = UnitStat("player", 3) return v end },
	{ "Intellect", function() local _, v = UnitStat("player", 4) return v end },
	{ "Spirit",    function() local _, v = UnitStat("player", 5) return v end },
	{ "Armor",     function() local _, eff = UnitArmor("player") return eff end },
	{ "Attack Power", function()
		local base, pos, neg = UnitAttackPower("player")
		return base + pos + neg
	end },
	{ "Melee Crit", function()
		if not GetCritChance then return nil end
		return string.format("%.1f%%", GetCritChance())
	end },
	{ "Ranged Crit", function()
		if not GetRangedCritChance then return nil end
		return string.format("%.1f%%", GetRangedCritChance())
	end },
	{ "Defense", function()
		if not UnitDefense then return nil end
		local base, mod = UnitDefense("player")
		return base + mod
	end },
}

local function UpdateStats()
	for i = 1, table.getn(STAT_DEFS) do
		local row = statRows[i]
		local ok, value = pcall(STAT_DEFS[i][2])
		if ok and value ~= nil then
			row.value:SetText(value)
			row:Show()
		else
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Equipment
--------------------------------------------------------------------------------

local function UpdateSlots()
	local totalCur, totalMax = 0, 0
	for i = 1, table.getn(SLOTS) do
		local cell = slotCells[i]
		local texture = GetInventoryItemTexture("player", cell.slotID)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetVertexColor(1, 1, 1)
		else
			cell.icon:SetTexture(cell.emptyTexture or WM.TEX_QUESTION)
			cell.icon:SetVertexColor(0.45, 0.45, 0.45)
		end
		local cur, max
		if GetInventoryItemDurability then
			cur, max = GetInventoryItemDurability(cell.slotID)
		end
		if cur and max and max > 0 then
			totalCur, totalMax = totalCur + cur, totalMax + max
			cell.dura:Show()
			cell.dura:SetMinMaxValues(0, max)
			cell.dura:SetValue(cur)
			local frac = cur / max
			if frac < 0.2 then
				cell.dura:SetStatusBarColor(0.9, 0.2, 0.2)
			elseif frac < 0.5 then
				cell.dura:SetStatusBarColor(0.95, 0.8, 0.25)
			else
				cell.dura:SetStatusBarColor(0.3, 0.8, 0.35)
			end
		else
			cell.dura:Hide()
		end
	end
	if totalMax > 0 then
		durabilityText:SetText(string.format("Durability  %d%%", totalCur / totalMax * 100))
	else
		durabilityText:SetText("")
	end
end

local function Refresh()
	if not panel:IsShown() then return end
	UpdateSlots()
	UpdateStats()
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("character", "Character")

	-- Equipment grid, left side.
	for i = 1, table.getn(SLOTS) do
		local slotName, label = SLOTS[i][1], SLOTS[i][2]
		local cell = CreateFrame("Button", nil, panel.content)
		cell:SetWidth(WM.Px(CELL))
		cell:SetHeight(WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local col = math.mod(i - 1, COLS)
		local row = math.floor((i - 1) / COLS)
		cell:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
			WM.Px(col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))

		local slotID, emptyTexture = GetInventorySlotInfo(slotName)
		cell.slotID, cell.emptyTexture = slotID, emptyTexture

		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetWidth(WM.Px(72))
		cell.icon:SetHeight(WM.Px(72))
		cell.icon:SetPoint("TOP", cell, "TOP", 0, -WM.Px(8))

		local name = WM.CreateText(cell, 20)
		name:SetPoint("BOTTOM", cell, "BOTTOM", 0, WM.Px(8))
		name:SetText(label)
		name:SetTextColor(0.7, 0.7, 0.75)

		cell.dura = CreateFrame("StatusBar", nil, cell)
		cell.dura:SetStatusBarTexture(WM.TEX_WHITE)
		cell.dura:SetWidth(WM.Px(72))
		cell.dura:SetHeight(WM.Px(8))
		cell.dura:SetPoint("TOP", cell.icon, "BOTTOM", 0, -WM.Px(2))
		local bg = cell.dura:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(cell.dura)
		bg:SetTexture(0.05, 0.05, 0.06, 1)

		-- Plain tap keeps its old meaning (tooltip via the injected hover);
		-- long-press (client right click) = MoveMode pickup of the equipped
		-- item; while a carry is active a tap drops here (equip / swap).
		cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cell:SetScript("OnClick", function()
			-- CursorForeign: an un-adopted Blizzard-loaded cursor (bank
			-- withdraw) drops/equips here too; DropOnInventory adopts it.
			if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
				WM.MoveMode.DropOnInventory(this.slotID)
			elseif arg1 == "RightButton" then
				WM.MoveMode.BeginFromInventory(this.slotID)
			end
		end)
		WM.MoveMode.MakeTarget(cell, "inv")

		cell.slotLabel = label
		WM.AttachTooltip(cell, function(tt, self)
			-- Decide emptiness from the data API, not the tooltip setter.
			if GetInventoryItemLink("player", self.slotID) then
				tt:SetInventoryItem("player", self.slotID)
			else
				tt:SetText(self.slotLabel)
			end
		end)
		slotCells[i] = cell
	end

	-- Stat column, right side.
	local statX = COLS * (CELL + GAP) + 24
	for i = 1, table.getn(STAT_DEFS) do
		local row = CreateFrame("Frame", nil, panel.content)
		row:SetWidth(WM.Px(1064 - statX - 16))
		row:SetHeight(WM.Px(52))
		row:SetPoint("TOPLEFT", panel.content, "TOPLEFT", WM.Px(statX), -WM.Px((i - 1) * 56))
		local label = WM.CreateText(row, 28)
		label:SetPoint("LEFT", row, "LEFT", 0, 0)
		label:SetText(STAT_DEFS[i][1])
		label:SetTextColor(0.75, 0.75, 0.8)
		row.value = WM.CreateText(row, 28)
		row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		statRows[i] = row
	end

	durabilityText = WM.CreateText(panel.content, 28)
	durabilityText:SetPoint("TOPLEFT", panel.content, "TOPLEFT",
		WM.Px(statX), -WM.Px(table.getn(STAT_DEFS) * 56 + 16))

	panel.OnOpen = Refresh
	WM.On("UNIT_INVENTORY_CHANGED", function(_, unit)
		if unit == "player" then Refresh() end
	end)
	WM.On("UNIT_STATS", function(_, unit)
		if unit == "player" then Refresh() end
	end)
	-- 1.12's durability signal is UPDATE_INVENTORY_ALERTS; the _DURABILITY
	-- event is a later addition — TryOn covers both spellings.
	WM.TryOn("UPDATE_INVENTORY_ALERTS", Refresh)
	WM.TryOn("UPDATE_INVENTORY_DURABILITY", Refresh)
	WM.TryOn("UNIT_ATTACK_POWER", function(_, unit)
		if unit == "player" then Refresh() end
	end)
end)
