--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Crafting
-- One deck sheet serving BOTH 1.12 crafting APIs, replacing the banished
-- TradeSkillFrame and CraftFrame (both core FrameXML on this client — the
-- Blizzard_TradeSkillUI/CraftUI LoD splits are TBC-era; banished with events
-- unregistered in Blizzard.lua because their OnHides call CloseTradeSkill /
-- CloseCraft):
--   * tradeskill API — GetNumTradeSkills / GetTradeSkillInfo(i) -> name,
--     type ("header"/"optimal"/"medium"/"easy"/"trivial"), numAvailable,
--     isExpanded; GetTradeSkillNumReagents / GetTradeSkillReagentInfo(i, j)
--     -> name, texture, needCount, playerCount; GetTradeSkillIcon(i);
--     DoTradeSkill(i, repeatCount); GetTradeSkillLine() -> name, rank, max.
--     Events: TRADE_SKILL_SHOW / TRADE_SKILL_UPDATE / TRADE_SKILL_CLOSE.
--   * craft API (enchanting, hunter beast training) — GetNumCrafts /
--     GetCraftInfo(i) -> name, subSpellName, type, numAvailable, isExpanded;
--     GetCraftNumReagents / GetCraftReagentInfo(i, j) (same shape);
--     GetCraftIcon(i); DoCraft(i) — NO repeat count on 1.12, an enchant is
--     one cast per tap (the detail view hides the quantity controls and
--     Create All for craft sessions, honestly). GetCraftDisplaySkillLine()
--     titles enchanting; GetCraftName() covers Beast Training (no skill
--     line). Events: CRAFT_SHOW / CRAFT_UPDATE / CRAFT_CLOSE.
--
-- No profession picker is needed on 1.12: the server allows ONE open
-- tradeskill/craft session at a time — opening another closes the previous
-- one with its *_CLOSE event — so the sheet simply binds to whichever
-- session is live (`kind` below).
--
-- Recipe indices are positions in the CURRENT (filter/expansion-dependent)
-- list, so every *_SHOW expands all headers (ExpandTradeSkillSubClass(0) /
-- ExpandCraftSkillLine(0), pcall-guarded) before rendering, and the detail
-- view re-validates its stored index by NAME on every *_UPDATE.
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 104
local GAP = 6
local REAGENT_H = 100

local sheet, scroller, titleText
local detail, reagentRows = nil, {}
local listRows = {}

local kind          -- "tradeskill" | "craft" | nil
local selected      -- recipe index while the detail overlay is up
local selectedName
local qty = 1

local TYPE_COLORS = {
	optimal = { 1.00, 0.50, 0.25 },
	medium  = { 1.00, 1.00, 0.10 },
	easy    = { 0.25, 0.75, 0.25 },
	trivial = { 0.50, 0.50, 0.50 },
}

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

--------------------------------------------------------------------------------
-- API indirection (one panel, two APIs)
--------------------------------------------------------------------------------

local function NumEntries()
	if kind == "craft" then return GetNumCrafts() end
	return GetNumTradeSkills()
end

-- -> name, type, numAvailable (craft's extra subSpellName return is folded
-- into the name).
local function EntryInfo(i)
	if kind == "craft" then
		local name, subName, craftType, numAvailable = GetCraftInfo(i)
		if name and subName and subName ~= "" then
			name = name .. " (" .. subName .. ")"
		end
		return name, craftType, numAvailable
	end
	local name, skillType, numAvailable = GetTradeSkillInfo(i)
	return name, skillType, numAvailable
end

local function EntryIcon(i)
	if kind == "craft" then return GetCraftIcon(i) end
	return GetTradeSkillIcon(i)
end

local function NumReagents(i)
	if kind == "craft" then return GetCraftNumReagents(i) end
	return GetTradeSkillNumReagents(i)
end

local function ReagentInfo(i, j)
	if kind == "craft" then return GetCraftReagentInfo(i, j) end
	return GetTradeSkillReagentInfo(i, j)
end

local function SheetTitle()
	if kind == "craft" then
		local name, rank, maxRank
		if GetCraftDisplaySkillLine then
			name, rank, maxRank = GetCraftDisplaySkillLine()
		end
		if not name and GetCraftName then
			name = GetCraftName()
		end
		if name and rank and maxRank then
			return name .. "  " .. rank .. " / " .. maxRank
		end
		return name or "Crafting"
	end
	local name, rank, maxRank = GetTradeSkillLine()
	if name and rank and maxRank then
		return name .. "  " .. rank .. " / " .. maxRank
	end
	return name or "Crafting"
end

--------------------------------------------------------------------------------
-- Recipe list
--------------------------------------------------------------------------------

local OpenDetail, RenderDetail -- forward

local function AcquireListRow(i)
	local row = listRows[i]
	if row then return row end
	row = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 30)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(72))
	row.icon:SetHeight(WM.Px(72))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(16), 0)
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row, "LEFT", WM.Px(108), 0)
	row.label:SetJustifyH("LEFT")
	WM.SingleLine(row.label, 30)
	row.avail = WM.CreateText(row, 28)
	row.avail:SetPoint("RIGHT", row, "RIGHT", -WM.Px(20), 0)
	row.avail:SetJustifyH("RIGHT")
	row:SetScript("OnClick", function()
		if this.recipeIndex then OpenDetail(this.recipeIndex) end
	end)
	WM.AttachTooltip(row, function(tt, self)
		if not self.recipeIndex then
			tt:SetText(self.label:GetText() or "") -- header row: name only
			return
		end
		if kind == "craft" then
			-- SetCraftSpell(index) is the craft-result tooltip on 1.12 (what
			-- the default CraftFrame's highlight frame uses); SetCraftItem is
			-- the REAGENT form and requires both (index, reagentSlot) — a
			-- one-argument SetCraftItem is a call shape the 1.12 client never
			-- exposes and would raise a Usage error.
			tt:SetCraftSpell(self.recipeIndex)
		else
			tt:SetTradeSkillItem(self.recipeIndex)
		end
	end)
	listRows[i] = row
	return row
end

local function RenderList()
	if not IsOpen() then return end
	titleText:SetText(SheetTitle())
	local n = NumEntries()
	local used = 0
	for i = 1, n do
		local name, entryType, numAvailable = EntryInfo(i)
		if name then
			used = used + 1
			local row = AcquireListRow(used)
			row.label:SetWidth(scroller.ContentWidth() - WM.Px(240))
			if entryType == "header" then
				-- Headers stay in the list (expanded at show) as unclickable
				-- section rows.
				row.recipeIndex = nil
				row.icon:Hide()
				row.label:ClearAllPoints()
				row.label:SetPoint("LEFT", row, "LEFT", WM.Px(20), 0)
				row.label:SetText(name)
				row.label:SetTextColor(1, 0.82, 0)
				row.avail:SetText("")
				WM.TintBorder(row, WM.Colors.border)
			else
				row.recipeIndex = i
				row.icon:Show()
				row.icon:SetTexture(EntryIcon(i) or WM.TEX_QUESTION)
				row.label:ClearAllPoints()
				row.label:SetPoint("LEFT", row, "LEFT", WM.Px(108), 0)
				row.label:SetText(name)
				local c = TYPE_COLORS[entryType or ""]
				if c then
					row.label:SetTextColor(c[1], c[2], c[3])
				else
					row.label:SetTextColor(0.92, 0.92, 0.92)
				end
				if numAvailable and numAvailable > 0 then
					row.avail:SetText("|cff33cc33[" .. numAvailable .. "]|r")
				else
					row.avail:SetText("|cff9999a3[0]|r")
				end
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetPoint("TOPRIGHT", scroller.child, "TOPRIGHT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetHeight(WM.Px(ROW_H))
			row:Show()
		end
	end
	for i = used + 1, table.getn(listRows) do
		listRows[i]:Hide()
	end
	scroller.SetContentHeight(WM.Px(used * (ROW_H + GAP)))
end

--------------------------------------------------------------------------------
-- Detail overlay (reagents + create)
--------------------------------------------------------------------------------

local function AcquireReagentRow(i)
	local row = reagentRows[i]
	if row then return row end
	row = CreateFrame("Button", nil, detail.scroller.child)
	row:SetHeight(WM.Px(REAGENT_H))
	WM.SkinFrame(row, { 0.07, 0.07, 0.09, 1 })
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(72))
	row.icon:SetHeight(WM.Px(72))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(14), 0)
	row.name = WM.CreateText(row, 28)
	row.name:SetPoint("LEFT", row, "LEFT", WM.Px(104), 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWidth(WM.Px(560))
	WM.SingleLine(row.name, 28)
	row.have = WM.CreateText(row, 28)
	row.have:SetPoint("RIGHT", row, "RIGHT", -WM.Px(20), 0)
	row.have:SetJustifyH("RIGHT")
	WM.AttachTooltip(row, function(tt, self)
		if kind == "craft" then
			tt:SetCraftItem(selected, self.reagentIndex)
		else
			tt:SetTradeSkillItem(selected, self.reagentIndex)
		end
	end)
	reagentRows[i] = row
	return row
end

RenderDetail = function()
	if not detail:IsShown() or not selected then return end
	local name, _, numAvailable = EntryInfo(selected)
	if not name or name ~= selectedName then
		-- The list shifted under us (*_UPDATE); the stored index no longer
		-- names the same recipe — bail rather than crafting the wrong thing.
		detail:Hide()
		return
	end
	detail.title:SetText(name)
	detail.icon:SetTexture(EntryIcon(selected) or WM.TEX_QUESTION)

	local n = NumReagents(selected)
	for j = 1, n do
		local rname, rtex, needCount, playerCount = ReagentInfo(selected, j)
		local row = AcquireReagentRow(j)
		row.reagentIndex = j
		row.icon:SetTexture(rtex or WM.TEX_QUESTION)
		row.name:SetText(rname or "…")
		local have, need = playerCount or 0, needCount or 0
		if have >= need then
			row.have:SetText("|cff33cc33" .. have .. " / " .. need .. "|r")
		else
			row.have:SetText("|cffcc4444" .. have .. " / " .. need .. "|r")
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", detail.scroller.child, "TOPLEFT",
			0, -WM.Px((j - 1) * (REAGENT_H + GAP)))
		row:SetPoint("TOPRIGHT", detail.scroller.child, "TOPRIGHT",
			0, -WM.Px((j - 1) * (REAGENT_H + GAP)))
		row:Show()
	end
	for j = n + 1, table.getn(reagentRows) do
		reagentRows[j]:Hide()
	end
	detail.scroller.SetContentHeight(WM.Px(n * (REAGENT_H + GAP)))

	local avail = numAvailable or 0
	detail.avail:SetText(avail > 0
		and ("|cff33cc33Reagents for " .. avail .. "|r")
		or "|cffcc4444Missing reagents|r")
	if kind == "craft" then
		-- DoCraft takes no repeat count on 1.12 (see header): single casts.
		detail.minus:Hide()
		detail.qtyText:Hide()
		detail.plus:Hide()
		detail.maxBtn:Hide()
		detail.createAll:Hide()
		detail.create.label:SetText("Create")
	else
		detail.minus:Show()
		detail.qtyText:Show()
		detail.plus:Show()
		detail.maxBtn:Show()
		detail.createAll:Show()
		if qty > avail then qty = avail end
		if qty < 1 then qty = 1 end
		detail.qtyText:SetText(qty)
		detail.create.label:SetText("Create " .. qty)
		WM.SetButtonEnabled(detail.createAll, avail > 0)
	end
	WM.SetButtonEnabled(detail.create, avail > 0)
end

OpenDetail = function(index)
	local name = EntryInfo(index)
	if not name then return end
	selected, selectedName = index, name
	qty = 1
	detail:Show()
	detail.scroller.ScrollToTop()
	RenderDetail()
end

local function DoCreate(count)
	if not selected then return end
	local _, _, avail = EntryInfo(selected)
	if not avail or avail < 1 then return end
	if kind == "craft" then
		DoCraft(selected)
	else
		if count > avail then count = avail end
		DoTradeSkill(selected, count)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function CloseSession()
	if kind == "craft" then
		CloseCraft()
	elseif kind == "tradeskill" then
		CloseTradeSkill()
	end
	kind = nil
	sheet:Hide()
end

local function OpenSheet(newKind)
	kind = newKind
	WM.Deck.YieldTo("craft")
	sheet:Show()
	detail:Hide()
	selected, selectedName = nil, nil
	scroller.ScrollToTop()
	RenderList()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileCraftSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetWidth(WM.Px(840))
	titleText:SetJustifyH("LEFT")
	WM.SingleLine(titleText, 40)

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", CloseSession)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	-- Detail overlay (FULLSCREEN_DIALOG — the shared overlay technique; built
	-- by hand because it needs a scroller plus the quantity controls).
	detail = CreateFrame("Frame", "WowMobileCraftDetail", sheet)
	detail:SetFrameStrata("FULLSCREEN_DIALOG")
	detail:SetAllPoints(sheet)
	detail:EnableMouse(true)
	WM.SkinFrame(detail, WM.Colors.panel, WM.Colors.accent)
	detail:Hide()

	detail.icon = detail:CreateTexture(nil, "ARTWORK")
	detail.icon:SetWidth(WM.Px(72))
	detail.icon:SetHeight(WM.Px(72))
	detail.icon:SetPoint("TOPLEFT", detail, "TOPLEFT", WM.Px(20), -WM.Px(16))
	detail.title = WM.CreateText(detail, 34)
	detail.title:SetPoint("TOPLEFT", detail, "TOPLEFT", WM.Px(108), -WM.Px(32))
	detail.title:SetJustifyH("LEFT")
	detail.title:SetWidth(WM.Px(660))
	WM.SingleLine(detail.title, 34)

	local back = WM.CreateTouchButton(detail, 160, 96, "Back", 30)
	back:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	back:SetScript("OnClick", function()
		selected, selectedName = nil, nil
		detail:Hide()
	end)

	local detailContent = CreateFrame("Frame", nil, detail)
	detailContent:SetPoint("TOPLEFT", detail, "TOPLEFT", WM.Px(8), -WM.Px(104))
	detailContent:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -WM.Px(8), WM.Px(248))
	detail.scroller = WM.Deck.CreateScroller(detailContent)

	detail.avail = WM.CreateText(detail, 28)
	detail.avail:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", WM.Px(16), WM.Px(196))

	-- Quantity stepper row (tradeskill sessions only).
	detail.minus = WM.CreateTouchButton(detail, 110, 96, "-", 44)
	detail.minus:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", WM.Px(12), WM.Px(88))
	detail.minus:SetScript("OnClick", function()
		if qty > 1 then
			qty = qty - 1
			RenderDetail()
		end
	end)
	detail.qtyText = WM.CreateText(detail, 40)
	detail.qtyText:SetPoint("LEFT", detail.minus, "RIGHT", 0, 0)
	detail.qtyText:SetWidth(WM.Px(120))
	detail.qtyText:SetJustifyH("CENTER")
	detail.plus = WM.CreateTouchButton(detail, 110, 96, "+", 44)
	detail.plus:SetPoint("LEFT", detail.minus, "RIGHT", WM.Px(120), 0)
	detail.plus:SetScript("OnClick", function()
		qty = qty + 1
		RenderDetail() -- clamped to availability there
	end)
	detail.maxBtn = WM.CreateTouchButton(detail, 140, 96, "Max", 30)
	detail.maxBtn:SetPoint("LEFT", detail.plus, "RIGHT", WM.Px(8), 0)
	detail.maxBtn:SetScript("OnClick", function()
		if not selected then return end
		local _, _, avail = EntryInfo(selected)
		qty = avail and avail > 0 and avail or 1
		RenderDetail()
	end)

	detail.create = WM.CreateTouchButton(detail, 440, 110, "Create", 32)
	detail.create:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", WM.Px(12), WM.Px(12))
	detail.create:SetScript("OnClick", function() DoCreate(qty) end)
	detail.createAll = WM.CreateTouchButton(detail, 440, 110, "Create all", 32)
	detail.createAll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -WM.Px(12), WM.Px(12))
	detail.createAll:SetScript("OnClick", function()
		if not selected then return end
		local _, _, avail = EntryInfo(selected)
		if avail and avail > 0 then DoCreate(avail) end
	end)

	WM.Deck.RegisterExclusive("craft", function()
		if sheet:IsShown() then CloseSession() end
	end)

	WM.On("TRADE_SKILL_SHOW", function()
		-- Expand every collapsed header first: indices are list positions.
		pcall(ExpandTradeSkillSubClass, 0)
		OpenSheet("tradeskill")
	end)
	WM.On("TRADE_SKILL_UPDATE", function()
		if kind ~= "tradeskill" or not IsOpen() then return end
		RenderList()
		RenderDetail()
	end)
	WM.On("TRADE_SKILL_CLOSE", function()
		if kind == "tradeskill" then
			kind = nil
			sheet:Hide()
		end
	end)

	WM.On("CRAFT_SHOW", function()
		pcall(ExpandCraftSkillLine, 0)
		OpenSheet("craft")
	end)
	WM.On("CRAFT_UPDATE", function()
		if kind ~= "craft" or not IsOpen() then return end
		RenderList()
		RenderDetail()
	end)
	WM.On("CRAFT_CLOSE", function()
		if kind == "craft" then
			kind = nil
			sheet:Hide()
		end
	end)
end)
