--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Bank
-- Banking as a deck bottom sheet, replacing the default BankFrame (banished
-- with its events unregistered in Blizzard.lua — the established suppression
-- technique; it matters here because BankFrame's OnHide calls CloseBankFrame,
-- so a merely-hidden frame being Show()n/Hide()n would end the bank session
-- server-side).
--
-- One scroller holds every grid so deposits and withdrawals never need a
-- second surface: the 24-slot bank container (bag -1 = BANK_CONTAINER), the
-- six purchasable bank-bag slots, the purchased bank bags (containers 5..10
-- on 1.12) and the player's own bags (0..4). Cell semantics mirror Bags.lua:
-- tap = UseContainerItem — the 1.12 auto-transfer (withdraw from a bank cell,
-- deposit from a bag cell while the bank is open); long-press (client right
-- click) = MoveMode pickup with the split stepper on stacks; while a carry is
-- active every tap is a drop (place / swap / merge). The 1.12 container API
-- addresses the bank exactly like a bag, so MoveMode's BeginFromBag/DropOnBag
-- serve BOTH directions unchanged.
--
-- Bag-slot purchases (1.12 BankFrame.lua flow): GetNumBankSlots() -> owned,
-- full; GetBankSlotCost(owned) prices the NEXT slot (the owned count is
-- passed the way the default UI passes it — harmless if this build ignores
-- the argument); PurchaseSlot() buys it. Confirmed in our own overlay — the
-- default CONFIRM_BUY_BANK_SLOT popup belonged to the banished frame's flow.
--
-- Equipping a bag INTO a purchased slot: the bank-bag slots are inventory
-- slots, mapped via BankButtonIDToInvSlotID(i, 1) (pcall-guarded — if this
-- build lacks the mapping those cells degrade to display-only, honestly).
-- MoveMode's green highlight doesn't fire for INVTYPE_BAG (its equip-location
-- map covers wearable slots only); the drop itself still works — accepted
-- cosmetic gap.
--------------------------------------------------------------------------------

local WM = WowMobile

local BANK_BAG = BANK_CONTAINER or -1
local GENERIC_SLOTS = NUM_BANKGENERIC_SLOTS or 24
local NUM_BAG_SLOTS = NUM_BANKBAGSLOTS or 6
local FIRST_BAG = 5 -- bank bag containers are 5..10 on 1.12

local COLS = 8
-- Same scroller-viewport budget as Bags.lua: content 1064 minus the 92+6
-- scroll column leaves 966; 8 columns at 114+6 pitch span 954 <= 966.
local CELL = 114
local GAP = 6
local HEADER_H = 56

local sheet, scroller, confirm, buyBtn
local cells = {}        -- "bag:slot" -> item cell
local bagSlotCells = {} -- 1..6 bank bag-slot cells (created at init)
local headers = {}
local sizes = {}        -- container -> size at last layout

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

--------------------------------------------------------------------------------
-- Item cells (Bags.lua look & semantics)
--------------------------------------------------------------------------------

local function UpdateItemCell(cell)
	local icon, count, locked, quality = GetContainerItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		if locked then
			cell.icon:SetVertexColor(0.4, 0.4, 0.45)
		else
			cell.icon:SetVertexColor(1, 1, 1)
		end
		cell.count:SetText(count and count > 1 and count or "")
		local q = quality and quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		if q then
			cell.borderTex:SetTexture(q.r, q.g, q.b, 1)
		else
			WM.TintBorder(cell, WM.Colors.border)
		end
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
		WM.TintBorder(cell, WM.Colors.border)
	end
end

local function CreateItemCell(bag, slot)
	local cell = CreateFrame("Button", nil, scroller.child)
	cell:SetWidth(WM.Px(CELL))
	cell:SetHeight(WM.Px(CELL))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(4), -WM.Px(4))
	cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	cell.count = WM.CreateText(cell, 26, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
	cell.bag, cell.slot = bag, slot
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	cell:SetScript("OnClick", function()
		if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
			WM.MoveMode.DropOnBag(this.bag, this.slot)
		elseif arg1 == "RightButton" then
			WM.MoveMode.BeginFromBag(this.bag, this.slot)
		else
			-- 1.12 auto-transfer semantics while the bank is open: withdraw
			-- from a bank cell, deposit from a player-bag cell.
			UseContainerItem(this.bag, this.slot)
		end
	end)
	WM.MoveMode.MakeTarget(cell, "bag")
	WM.AttachTooltip(cell, function(tt, self)
		if self.bag == BANK_BAG then
			-- The bank container has no SetBagItem path on 1.12; its slots
			-- are inventory slots (BankButtonIDToInvSlotID, no isBag arg) —
			-- the same mapping the default BankFrame tooltips use.
			local ok, inv = pcall(BankButtonIDToInvSlotID, self.slot)
			if ok and inv then
				tt:SetInventoryItem("player", inv)
				return
			end
		end
		tt:SetBagItem(self.bag, self.slot)
	end)
	return cell
end

--------------------------------------------------------------------------------
-- Bank bag-slot cells (equip/inspect the six purchasable slots)
--------------------------------------------------------------------------------

local function UpdateBagSlotCell(cell, owned)
	if cell.bagIndex <= owned then
		local texture = cell.invSlot and GetInventoryItemTexture("player", cell.invSlot)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetVertexColor(1, 1, 1)
		else
			cell.icon:SetTexture(WM.TEX_WHITE)
			cell.icon:SetVertexColor(0.15, 0.15, 0.18)
		end
		WM.TintBorder(cell, WM.Colors.border)
		cell.owned = true
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.10, 0.06, 0.06)
		WM.TintBorder(cell, { 0.45, 0.2, 0.2, 1 })
		cell.owned = false
	end
end

local function CreateBagSlotCell(i)
	local cell = CreateFrame("Button", nil, scroller.child)
	cell:SetWidth(WM.Px(CELL))
	cell:SetHeight(WM.Px(CELL))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(4), -WM.Px(4))
	cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	cell.bagIndex = i
	local ok, inv = pcall(BankButtonIDToInvSlotID, i, 1)
	cell.invSlot = ok and inv or nil
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	cell:SetScript("OnClick", function()
		if not this.owned or not this.invSlot then return end
		if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
			WM.MoveMode.DropOnInventory(this.invSlot)
		elseif arg1 == "RightButton" then
			WM.MoveMode.BeginFromInventory(this.invSlot)
		end
	end)
	WM.AttachTooltip(cell, function(tt, self)
		if self.owned and self.invSlot
				and GetInventoryItemLink("player", self.invSlot) then
			tt:SetInventoryItem("player", self.invSlot)
		elseif self.owned then
			tt:SetText("Bank bag slot " .. self.bagIndex ..
				" — long-press a bag, then tap here")
		else
			tt:SetText("Locked — buy this slot")
		end
	end)
	return cell
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local usedHeaders = 0
local layoutY = 0
local shownKeys = {}

local function AddHeader(label)
	usedHeaders = usedHeaders + 1
	local h = headers[usedHeaders]
	if not h then
		h = WM.CreateText(scroller.child, 30)
		h:SetJustifyH("LEFT")
		h:SetTextColor(1, 0.82, 0)
		headers[usedHeaders] = h
	end
	h:ClearAllPoints()
	h:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px(4), -WM.Px(layoutY + 14))
	h:SetText(label)
	h:Show()
	layoutY = layoutY + HEADER_H
end

-- One continuous grid across containers firstBag..lastBag.
local function AddGrids(firstBag, lastBag)
	local index = 0
	for bag = firstBag, lastBag do
		local size = GetContainerNumSlots(bag)
		sizes[bag] = size
		for slot = 1, size do
			index = index + 1
			local key = bag .. ":" .. slot
			local cell = cells[key]
			if not cell then
				cell = CreateItemCell(bag, slot)
				cells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				WM.Px(col * (CELL + GAP)), -WM.Px(layoutY + row * (CELL + GAP)))
			UpdateItemCell(cell)
			cell:Show()
			shownKeys[key] = true
		end
	end
	if index > 0 then
		layoutY = layoutY + math.ceil(index / COLS) * (CELL + GAP)
	end
end

local function Rebuild()
	if not IsOpen() then return end
	usedHeaders = 0
	layoutY = 0
	for key in pairs(shownKeys) do
		shownKeys[key] = nil
	end

	AddHeader("Bank")
	AddGrids(BANK_BAG, BANK_BAG)

	local owned = GetNumBankSlots()
	AddHeader("Bank bag slots")
	for i = 1, NUM_BAG_SLOTS do
		local cell = bagSlotCells[i]
		cell:ClearAllPoints()
		cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
			WM.Px((i - 1) * (CELL + GAP)), -WM.Px(layoutY))
		UpdateBagSlotCell(cell, owned)
	end
	layoutY = layoutY + CELL + GAP

	for bag = FIRST_BAG, FIRST_BAG + NUM_BAG_SLOTS - 1 do
		if GetContainerNumSlots(bag) > 0 then
			AddHeader("Bank bag " .. (bag - FIRST_BAG + 1))
			AddGrids(bag, bag)
		end
	end

	AddHeader("Your bags — tap to deposit")
	AddGrids(0, 4)

	for key, cell in pairs(cells) do
		if not shownKeys[key] then cell:Hide() end
	end
	for i = usedHeaders + 1, table.getn(headers) do
		headers[i]:Hide()
	end
	scroller.SetContentHeight(WM.Px(layoutY + 8))
end

local function RefreshBagVisuals(bag)
	for slot = 1, sizes[bag] or 0 do
		local cell = cells[bag .. ":" .. slot]
		if cell and cell:IsShown() then UpdateItemCell(cell) end
	end
end

--------------------------------------------------------------------------------
-- Buy-slot button
--------------------------------------------------------------------------------

local function UpdateBuyButton()
	local owned, full = GetNumBankSlots()
	if full then
		buyBtn.label:SetText("All slots bought")
		WM.SetButtonEnabled(buyBtn, false)
		buyBtn.cost = nil
	else
		local cost = GetBankSlotCost(owned)
		buyBtn.cost = cost
		buyBtn.label:SetText("Buy bag slot\n" .. WM.FormatMoney(cost or 0))
		WM.SetButtonEnabled(buyBtn, cost ~= nil and GetMoney() >= cost)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function Dismiss()
	CloseBankFrame()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileBankSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	local titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Bank")

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	buyBtn = WM.CreateTouchButton(sheet, 340, 96, "Buy bag slot", 26)
	buyBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -WM.Px(8), 0)
	buyBtn:SetScript("OnClick", function()
		if not this.cost then return end
		confirm.Ask("Buy the next bank bag slot for " ..
			WM.FormatMoney(this.cost) .. "?", "Buy slot", function()
			PurchaseSlot()
		end)
	end)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	confirm = WM.CreateConfirmOverlay(sheet)

	for i = 1, NUM_BAG_SLOTS do
		bagSlotCells[i] = CreateBagSlotCell(i)
	end

	-- A deck panel / NPC sheet / map taking the stage walks away from the
	-- bank too (CloseBankFrame is safe with no bank open).
	WM.Deck.RegisterExclusive("bank", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("BANKFRAME_OPENED", function()
		WM.Deck.YieldTo("bank")
		sheet:Show()
		scroller.ScrollToTop()
		UpdateBuyButton()
		Rebuild()
	end)
	WM.On("BANKFRAME_CLOSED", function()
		sheet:Hide()
	end)

	-- Per-slot signal for the bank container; arg1 > GENERIC_SLOTS means a
	-- bank BAG slot changed (bag equipped/removed) — sections shift.
	WM.On("PLAYERBANKSLOTS_CHANGED", function(_, slot)
		if not IsOpen() then return end
		if slot and slot <= GENERIC_SLOTS then
			local cell = cells[BANK_BAG .. ":" .. slot]
			if cell and cell:IsShown() then UpdateItemCell(cell) end
		else
			Rebuild()
		end
	end)
	WM.TryOn("PLAYERBANKBAGSLOTS_CHANGED", function()
		if not IsOpen() then return end
		UpdateBuyButton()
		Rebuild()
	end)
	WM.On("BAG_UPDATE", function(_, bag)
		if not IsOpen() or bag == nil then return end
		if sizes[bag] == nil or GetContainerNumSlots(bag) ~= sizes[bag] then
			Rebuild() -- a bag appeared/changed size: rows shift
		else
			RefreshBagVisuals(bag)
		end
	end)
	-- 1.12 ITEM_LOCK_CHANGED carries no usable bag argument; refresh every
	-- visible container (cheap: visuals only).
	WM.On("ITEM_LOCK_CHANGED", function()
		if not IsOpen() then return end
		for bag in pairs(sizes) do
			RefreshBagVisuals(bag)
		end
	end)
	WM.On("PLAYER_MONEY", function()
		if IsOpen() then UpdateBuyButton() end
	end)
end)
