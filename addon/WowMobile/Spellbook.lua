--------------------------------------------------------------------------------
-- WowMobile · Spellbook
-- Deck-filling spellbook panel: one tab per school (GetNumSpellTabs /
-- GetSpellTabInfo), a 3-column grid of big cells (icon + wrapping name + rank)
-- from GetSpellBookItemName/GetSpellBookItemTexture, tap = cast via secure
-- type="spell" (rank-qualified "Name(Rank N)" so downranking works). Passives
-- are dimmed, tooltip-only cells. Grid rebuilds are secure-attribute work, so
-- they run through the combat queue.
--------------------------------------------------------------------------------

local _, WM = ...

local BOOK = BOOKTYPE_SPELL or "spell"
local COLS = 3
local CELL_H = 132
local GAP = 8

local panel, scroller
local combatNotice -- "available after combat" text for a first open in lockdown
local tabButtons = {}
local cells = {}
local activeTab = 1

local function GetCell(i)
	local cell = cells[i]
	if cell then return cell end
	cell = CreateFrame("Button", "WowMobileSpellCell" .. i, scroller.child, "SecureActionButtonTemplate")
	WM.SkinFrame(cell, WM.Colors.button)
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetSize(WM.Px(96), WM.Px(96))
	cell.icon:SetPoint("LEFT", WM.Px(12), 0)
	cell.name = WM.CreateText(cell, 28)
	cell.name:SetPoint("TOPLEFT", WM.Px(120), -WM.Px(20))
	cell.name:SetJustifyH("LEFT")
	cell.name:SetWordWrap(true) -- long spell names wrap to a second line
	cell.rank = WM.CreateText(cell, 22)
	cell.rank:SetPoint("BOTTOMLEFT", WM.Px(120), WM.Px(14))
	cell.rank:SetTextColor(0.65, 0.65, 0.7)
	WM.RegisterSecureClicks(cell) -- CVar-selected click edge, see Core.lua
	WM.AttachTooltip(cell, function(tt, self)
		if self.bookSlot then
			tt:SetSpellBookItem(self.bookSlot, BOOK)
		end
	end)
	cells[i] = cell
	return cell
end

-- Runs out of combat only (queued by callers): SetAttribute on secure cells.
local function RebuildGrid()
	if not panel:IsShown() then return end
	combatNotice:Hide()
	local numTabs = GetNumSpellTabs()
	if activeTab > numTabs then activeTab = 1 end

	-- Tab row.
	for i = 1, numTabs do
		local name, texture = GetSpellTabInfo(i)
		local tab = tabButtons[i]
		if not tab then
			tab = WM.CreateTouchButton(panel.content, 150, 92, nil, 24)
			tab:SetPoint("TOPLEFT", WM.Px((i - 1) * 158), 0)
			tab.icon = tab:CreateTexture(nil, "ARTWORK")
			tab.icon:SetSize(WM.Px(48), WM.Px(48))
			tab.icon:SetPoint("LEFT", WM.Px(10), 0)
			tab.label:ClearAllPoints()
			tab.label:SetPoint("LEFT", WM.Px(64), 0)
			tab.label:SetJustifyH("LEFT")
			tab.label:SetWidth(WM.Px(80))
			tabButtons[i] = tab
		end
		tab.label:SetText(name)
		tab.icon:SetTexture(texture)
		local border = (i == activeTab) and WM.Colors.accent or WM.Colors.border
		tab.borderTex:SetColorTexture(border[1], border[2], border[3], 1)
		tab:SetScript("OnClick", function()
			activeTab = i
			WM.OutOfCombat("spellbook", RebuildGrid)
		end)
		tab:Show()
	end
	for i = numTabs + 1, #tabButtons do
		tabButtons[i]:Hide()
	end

	-- Spell grid for the active tab.
	local _, _, offset, numSpells = GetSpellTabInfo(activeTab)
	local colW = (scroller.ContentWidth() / WM.Px(1) - GAP * (COLS - 1)) / COLS
	local shown = 0
	for j = 1, numSpells do
		local slot = offset + j
		local name, rank = GetSpellBookItemName(slot, BOOK)
		if name then
			shown = shown + 1
			local cell = GetCell(shown)
			local col = (shown - 1) % COLS
			local row = math.floor((shown - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", WM.Px(col * (colW + GAP)), -WM.Px(row * (CELL_H + GAP)))
			cell:SetSize(WM.Px(colW), WM.Px(CELL_H))
			cell.icon:SetTexture(GetSpellBookItemTexture(slot, BOOK))
			cell.name:SetWidth(WM.Px(colW - 132))
			cell.name:SetText(name)
			cell.rank:SetText(rank or "")
			cell.bookSlot = slot
			if IsPassiveSpell(slot, BOOK) then
				cell:SetAttribute("type", nil) -- tap does nothing; tooltip only
				cell.icon:SetDesaturated(true)
				cell.name:SetTextColor(0.6, 0.6, 0.6)
			else
				cell:SetAttribute("type", "spell")
				-- Rank-qualified name: classic casts the exact rank shown.
				cell:SetAttribute("spell", (rank and rank ~= "") and (name .. "(" .. rank .. ")") or name)
				cell.icon:SetDesaturated(false)
				cell.name:SetTextColor(0.92, 0.92, 0.92)
			end
			cell:Show()
		end
	end
	for i = shown + 1, #cells do
		cells[i]:Hide()
	end
	scroller.SetContentHeight(WM.Px(math.ceil(shown / COLS) * (CELL_H + GAP)))
end

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("spellbook", "Spellbook")

	local grid = CreateFrame("Frame", nil, panel.content)
	grid:SetPoint("TOPLEFT", 0, -WM.Px(100)) -- below the tab row
	grid:SetPoint("BOTTOMRIGHT")
	scroller = WM.Deck.CreateScroller(grid)

	-- Shown only for a first-ever open during combat: the whole grid is
	-- secure-attribute work that must wait for PLAYER_REGEN_ENABLED, so say so
	-- instead of presenting a blank panel. (A grid built before combat can
	-- only be stale by a spell learned since — impossible in combat — so no
	-- interim refresh is needed, unlike Bags.lua.)
	combatNotice = WM.CreateText(panel.content, 30)
	combatNotice:SetPoint("TOP", 0, -WM.Px(140)) -- below the (empty) tab row
	combatNotice:SetText("The spellbook will appear when combat ends.")
	combatNotice:SetTextColor(0.7, 0.7, 0.75)
	combatNotice:Hide()

	panel.OnOpen = function()
		combatNotice:SetShown(cells[1] == nil and InCombatLockdown())
		WM.OutOfCombat("spellbook", RebuildGrid)
	end

	WM.On("SPELLS_CHANGED", function()
		WM.OutOfCombat("spellbook", RebuildGrid)
	end)
	WM.On("LEARNED_SPELL_IN_TAB", function()
		WM.OutOfCombat("spellbook", RebuildGrid)
	end)
end)
