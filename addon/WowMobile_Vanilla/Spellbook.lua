--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Spellbook
-- Deck-filling spellbook panel: one tab per school (GetNumSpellTabs /
-- GetSpellTabInfo), a 3-column grid of big cells (icon + name + rank) from
-- GetSpellName/GetSpellTexture, tap = CastSpell(bookSlot, "spell") — the
-- exact book slot, so downranking works without name(rank) strings. Passives
-- are dimmed, tooltip-only cells (1.12 marks them by the SPELL_PASSIVE rank
-- text; there is no IsPassiveSpell API).
--------------------------------------------------------------------------------

local WM = WowMobile

local BOOK = BOOKTYPE_SPELL or "spell"
local COLS = 3
local CELL_H = 132
local GAP = 8

local panel, scroller
local tabButtons = {}
local cells = {}
local activeTab = 1

local function IsPassiveRank(rank)
	return rank ~= nil and rank ~= "" and rank == (SPELL_PASSIVE or "Passive")
end

local function GetCell(i)
	local cell = cells[i]
	if cell then return cell end
	cell = CreateFrame("Button", "WowMobileSpellCell" .. i, scroller.child)
	WM.SkinFrame(cell, WM.Colors.button)
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetWidth(WM.Px(96))
	cell.icon:SetHeight(WM.Px(96))
	cell.icon:SetPoint("LEFT", cell, "LEFT", WM.Px(12), 0)
	cell.name = WM.CreateText(cell, 28)
	cell.name:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(120), -WM.Px(20))
	cell.name:SetJustifyH("LEFT")
	cell.rank = WM.CreateText(cell, 22)
	cell.rank:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", WM.Px(120), WM.Px(14))
	cell.rank:SetTextColor(0.65, 0.65, 0.7)
	cell:SetScript("OnClick", function()
		if this.bookSlot and not this.passive then
			CastSpell(this.bookSlot, BOOK)
		end
	end)
	WM.AttachTooltip(cell, function(tt, self)
		if self.bookSlot then
			tt:SetSpell(self.bookSlot, BOOK)
		end
	end)
	cells[i] = cell
	return cell
end

local function RebuildGrid()
	if not panel:IsShown() then return end
	local numTabs = GetNumSpellTabs()
	if activeTab > numTabs then activeTab = 1 end

	-- Tab row.
	for i = 1, numTabs do
		local name, texture = GetSpellTabInfo(i)
		local tab = tabButtons[i]
		if not tab then
			tab = WM.CreateTouchButton(panel.content, 150, 92, nil, 24)
			tab:SetPoint("TOPLEFT", panel.content, "TOPLEFT", WM.Px((i - 1) * 158), 0)
			tab.icon = tab:CreateTexture(nil, "ARTWORK")
			tab.icon:SetWidth(WM.Px(48))
			tab.icon:SetHeight(WM.Px(48))
			tab.icon:SetPoint("LEFT", tab, "LEFT", WM.Px(10), 0)
			tab.label:ClearAllPoints()
			tab.label:SetPoint("LEFT", tab, "LEFT", WM.Px(64), 0)
			tab.label:SetJustifyH("LEFT")
			tab.label:SetWidth(WM.Px(80))
			tab.tabIndex = i
			tab:SetScript("OnClick", function()
				activeTab = this.tabIndex
				RebuildGrid()
			end)
			tabButtons[i] = tab
		end
		tab.label:SetText(name)
		tab.icon:SetTexture(texture)
		WM.TintBorder(tab, (i == activeTab) and WM.Colors.accent or WM.Colors.border)
		tab:Show()
	end
	for i = numTabs + 1, table.getn(tabButtons) do
		tabButtons[i]:Hide()
	end

	-- Spell grid for the active tab.
	local _, _, offset, numSpells = GetSpellTabInfo(activeTab)
	local colW = (scroller.ContentWidth() / WM.Px(1) - GAP * (COLS - 1)) / COLS
	local shown = 0
	for j = 1, numSpells do
		local slot = offset + j
		local name, rank = GetSpellName(slot, BOOK)
		if name then
			shown = shown + 1
			local cell = GetCell(shown)
			local col = math.mod(shown - 1, COLS)
			local row = math.floor((shown - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				WM.Px(col * (colW + GAP)), -WM.Px(row * (CELL_H + GAP)))
			cell:SetWidth(WM.Px(colW))
			cell:SetHeight(WM.Px(CELL_H))
			cell.icon:SetTexture(GetSpellTexture(slot, BOOK))
			cell.name:SetWidth(WM.Px(colW - 132))
			cell.name:SetText(name)
			cell.rank:SetText(rank or "")
			cell.bookSlot = slot
			cell.passive = IsPassiveRank(rank)
			if cell.passive then
				cell.icon:SetVertexColor(0.45, 0.45, 0.45)
				cell.name:SetTextColor(0.6, 0.6, 0.6)
			else
				cell.icon:SetVertexColor(1, 1, 1)
				cell.name:SetTextColor(0.92, 0.92, 0.92)
			end
			cell:Show()
		end
	end
	for i = shown + 1, table.getn(cells) do
		cells[i]:Hide()
	end
	scroller.SetContentHeight(WM.Px(math.ceil(shown / COLS) * (CELL_H + GAP)))
end

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("spellbook", "Spellbook")

	local grid = CreateFrame("Frame", nil, panel.content)
	grid:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(100)) -- below the tab row
	grid:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, 0)
	scroller = WM.Deck.CreateScroller(grid)

	panel.OnOpen = RebuildGrid

	WM.On("SPELLS_CHANGED", RebuildGrid)
	WM.TryOn("LEARNED_SPELL_IN_TAB", RebuildGrid)
end)
