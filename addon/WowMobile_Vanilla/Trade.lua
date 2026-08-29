--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Trade
-- Player trading as a deck bottom sheet, replacing the default TradeFrame
-- (banished with events unregistered in Blizzard.lua — its OnHide calls
-- CloseTrade, the established suppression rationale; UIParent's TRADE_SHOW
-- show path is unregistered there too).
--
-- 1.12 trade API (vanilla FrameXML TradeFrame.lua):
--   * TRADE_SHOW / TRADE_CLOSED; TRADE_PLAYER_ITEM_CHANGED(slot) /
--     TRADE_TARGET_ITEM_CHANGED(slot); TRADE_MONEY_CHANGED;
--     TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted).
--   * Seven slots per side (MAX_TRADE_ITEMS = 7); slot 7 is the
--     "Will not be traded" slot (shown to the partner for inspection or
--     enchanting, never exchanged). ClickTradeButton(i) places the cursor
--     item into YOUR slot i, or lifts the slot's occupant onto the cursor.
--   * GetTradePlayerItemInfo(i) / GetTradeTargetItemInfo(i) -> name, texture,
--     numItems, ... (only the first three are relied on — the later returns
--     differ between the two calls on 1.12); tooltips via
--     GameTooltip:SetTradePlayerItem(i) / SetTradeTargetItem(i).
--   * Money: SetTradeMoney(copper) / GetPlayerTradeMoney() /
--     GetTargetTradeMoney(). AcceptTrade() / CancelTrade().
--   * The trade partner is unit token "NPC" on 1.12 (TradeFrame.lua reads
--     UnitName("NPC") for the recipient line).
--
-- The sheet embeds the player's bag grid so items are addable without
-- leaving it (the deck's exclusive surfaces can't stack): tap a bag item =
-- add it to the first free offer slot; long-press = MoveMode carry (split
-- stepper included), then tap the exact offer slot to place; tap a filled
-- offer slot with no carry = lift it back off the trade (ClearCursor sends a
-- cursor item home to its bag — the MoveMode.Cancel semantics).
--------------------------------------------------------------------------------

local WM = WowMobile

local NUM_SLOTS = 7   -- MAX_TRADE_ITEMS on 1.12; slot 7 = will-not-be-traded
local CELL = 120      -- 7 * (120+6) - 6 = 876 <= 966 scroller viewport
local GAP = 6
local BAG_CELL = 114  -- bag grid, the Bags.lua 8-column budget
local COLS = 8

local sheet, scroller, titleText, acceptBtn, statusText
local playerSlots, targetSlots = {}, {}
local playerStepper, targetMoneyText, theirStateText
local bagCells = {}
local bagGridTop = 0
local playerAccepted, targetAccepted = 0, 0

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

--------------------------------------------------------------------------------
-- Offer slots
--------------------------------------------------------------------------------

local function UpdateTradeSlot(cell)
	local name, texture, numItems
	if cell.isTarget then
		name, texture, numItems = GetTradeTargetItemInfo(cell.slotIndex)
	else
		name, texture, numItems = GetTradePlayerItemInfo(cell.slotIndex)
	end
	if texture then
		cell.icon:SetTexture(texture)
		cell.icon:SetVertexColor(1, 1, 1)
		cell.count:SetText(numItems and numItems > 1 and numItems or "")
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
	end
	if cell.slotIndex == NUM_SLOTS then
		WM.TintBorder(cell, WM.Colors.accent) -- the not-traded slot stands out
	end
end

local function CreateTradeSlot(parent, slotIndex, isTarget)
	local cell = CreateFrame("Button", nil, parent)
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
	cell.slotIndex, cell.isTarget = slotIndex, isTarget
	if slotIndex == NUM_SLOTS then
		local keep = WM.CreateText(cell, 18, "OUTLINE")
		keep:SetPoint("TOP", cell, "TOP", 0, -WM.Px(4))
		keep:SetText("KEEP")
		keep:SetTextColor(1, 0.82, 0)
	end
	if not isTarget then
		cell:SetScript("OnClick", function()
			if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
				ClickTradeButton(this.slotIndex)
				WM.MoveMode.NoteSlotDrop()
			elseif GetTradePlayerItemInfo(this.slotIndex) then
				ClickTradeButton(this.slotIndex) -- lift it off the trade...
				ClearCursor()                    -- ...and home to its bag slot
			end
		end)
		WM.MoveMode.MakeTarget(cell, "bag")
	end
	WM.AttachTooltip(cell, function(tt, self)
		local has
		if self.isTarget then
			has = GetTradeTargetItemInfo(self.slotIndex)
			if has then
				tt:SetTradeTargetItem(self.slotIndex)
				return
			end
		else
			has = GetTradePlayerItemInfo(self.slotIndex)
			if has then
				tt:SetTradePlayerItem(self.slotIndex)
				return
			end
		end
		if self.slotIndex == NUM_SLOTS then
			tt:SetText("Shown but NOT traded")
		else
			tt:SetText(self.isTarget and "Their offer slot" or "Your offer slot")
		end
	end)
	return cell
end

local function FirstEmptyOfferSlot()
	for i = 1, NUM_SLOTS - 1 do
		if not GetTradePlayerItemInfo(i) then return i end
	end
	return nil
end

local function AddFromBag(bag, slot)
	local i = FirstEmptyOfferSlot()
	if not i then
		WM.Print("Trade: all six offer slots are full.")
		return
	end
	PickupContainerItem(bag, slot)
	if CursorHasItem() then
		ClickTradeButton(i)
		WM.MoveMode.NoteSlotDrop()
	end
end

--------------------------------------------------------------------------------
-- Bag grid
--------------------------------------------------------------------------------

local function UpdateBagCell(cell)
	local icon, count, locked = GetContainerItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		-- Locked = already offered (or mid-transaction): dimmed like Bags.lua.
		if locked then
			cell.icon:SetVertexColor(0.4, 0.4, 0.45)
		else
			cell.icon:SetVertexColor(1, 1, 1)
		end
		cell.count:SetText(count and count > 1 and count or "")
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
	end
end

local function CreateBagCell(bag, slot)
	local cell = CreateFrame("Button", nil, scroller.child)
	cell:SetWidth(WM.Px(BAG_CELL))
	cell:SetHeight(WM.Px(BAG_CELL))
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
			AddFromBag(this.bag, this.slot)
		end
	end)
	WM.MoveMode.MakeTarget(cell, "bag")
	WM.AttachTooltip(cell, function(tt, self)
		tt:SetBagItem(self.bag, self.slot)
	end)
	return cell
end

local function RenderBags()
	if not IsOpen() then return end
	local index = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			index = index + 1
			local key = bag .. ":" .. slot
			local cell = bagCells[key]
			if not cell then
				cell = CreateBagCell(bag, slot)
				bagCells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				WM.Px(col * (BAG_CELL + GAP)), -WM.Px(bagGridTop + row * (BAG_CELL + GAP)))
			UpdateBagCell(cell)
			cell:Show()
		end
	end
	for _, cell in pairs(bagCells) do
		if cell.slot > GetContainerNumSlots(cell.bag) then
			cell:Hide()
		end
	end
	scroller.SetContentHeight(
		WM.Px(bagGridTop + math.ceil(index / COLS) * (BAG_CELL + GAP) + 8))
end

--------------------------------------------------------------------------------
-- Accept state
--------------------------------------------------------------------------------

local function UpdateAcceptUI()
	if targetAccepted == 1 then
		theirStateText:SetText("|cff33cc33Partner has ACCEPTED|r")
	else
		theirStateText:SetText("|cffcc9933Partner has not accepted yet|r")
	end
	if playerAccepted == 1 then
		acceptBtn.label:SetText("Accepted…")
		WM.SetButtonEnabled(acceptBtn, false)
		statusText:SetText("Waiting for the other player. Changing anything cancels your accept.")
	else
		acceptBtn.label:SetText("Accept")
		WM.SetButtonEnabled(acceptBtn, true)
		if targetAccepted == 1 then
			statusText:SetText("|cff33cc33They accepted — check the offer, then Accept.|r")
		else
			statusText:SetText("Add items below, then Accept. Nothing moves until BOTH accept.")
		end
	end
end

local function UpdateMoney()
	targetMoneyText:SetText("They offer: " .. WM.FormatMoney(GetTargetTradeMoney()))
	-- The server echo is authoritative (it also resets on partner-side
	-- refusals); SetCopper never fires onChange, so no feedback loop.
	local mine = GetPlayerTradeMoney()
	if mine ~= playerStepper.GetCopper() then
		playerStepper.SetCopper(mine)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function Dismiss()
	CancelTrade()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileTradeSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetWidth(WM.Px(560))
	titleText:SetJustifyH("LEFT")
	WM.SingleLine(titleText, 40)

	local close = WM.CreateTouchButton(sheet, 160, 96, "Cancel", 30)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	acceptBtn = WM.CreateTouchButton(sheet, 280, 96, "Accept", 32)
	acceptBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -WM.Px(8), 0)
	acceptBtn:SetScript("OnClick", function() AcceptTrade() end)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)
	local sc = scroller.child

	-- Static layout inside the scroller (design px from the top).
	statusText = WM.CreateText(sc, 24)
	statusText:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(4))
	statusText:SetJustifyH("LEFT")
	statusText:SetWidth(WM.Px(940))
	WM.SingleLine(statusText, 24)

	local youLabel = WM.CreateText(sc, 30)
	youLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(56))
	youLabel:SetTextColor(1, 0.82, 0)
	youLabel:SetText("You offer")
	for i = 1, NUM_SLOTS do
		local cell = CreateTradeSlot(sc, i, false)
		cell:SetPoint("TOPLEFT", sc, "TOPLEFT",
			WM.Px((i - 1) * (CELL + GAP)), -WM.Px(104))
		playerSlots[i] = cell
	end

	playerStepper = WM.CreateMoneyStepper(sc, {
		onChange = function() SetTradeMoney(playerStepper.GetCopper()) end,
	})
	playerStepper:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -WM.Px(240))

	local themLabel = WM.CreateText(sc, 30)
	themLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(360))
	themLabel:SetTextColor(1, 0.82, 0)
	themLabel:SetText("They offer")
	theirStateText = WM.CreateText(sc, 26)
	theirStateText:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -WM.Px(4), -WM.Px(362))
	theirStateText:SetJustifyH("RIGHT")
	for i = 1, NUM_SLOTS do
		local cell = CreateTradeSlot(sc, i, true)
		cell:SetPoint("TOPLEFT", sc, "TOPLEFT",
			WM.Px((i - 1) * (CELL + GAP)), -WM.Px(408))
		targetSlots[i] = cell
	end
	targetMoneyText = WM.CreateText(sc, 28)
	targetMoneyText:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(544))

	local bagsLabel = WM.CreateText(sc, 30)
	bagsLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(596))
	bagsLabel:SetTextColor(1, 0.82, 0)
	bagsLabel:SetText("Your bags — tap an item to add it")
	bagGridTop = 648

	WM.Deck.RegisterExclusive("trade", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("TRADE_SHOW", function()
		WM.Deck.YieldTo("trade")
		playerAccepted, targetAccepted = 0, 0
		titleText:SetText("Trade: " .. (UnitName("NPC") or "Unknown"))
		playerStepper.SetCopper(0)
		sheet:Show()
		scroller.ScrollToTop()
		for i = 1, NUM_SLOTS do
			UpdateTradeSlot(playerSlots[i])
			UpdateTradeSlot(targetSlots[i])
		end
		UpdateMoney()
		UpdateAcceptUI()
		RenderBags()
	end)
	WM.On("TRADE_CLOSED", function()
		sheet:Hide()
	end)
	WM.On("TRADE_PLAYER_ITEM_CHANGED", function(_, slot)
		if not IsOpen() then return end
		if slot and playerSlots[slot] then
			UpdateTradeSlot(playerSlots[slot])
		end
	end)
	WM.On("TRADE_TARGET_ITEM_CHANGED", function(_, slot)
		if not IsOpen() then return end
		if slot and targetSlots[slot] then
			UpdateTradeSlot(targetSlots[slot])
		end
	end)
	WM.On("TRADE_MONEY_CHANGED", function()
		if IsOpen() then UpdateMoney() end
	end)
	WM.On("TRADE_ACCEPT_UPDATE", function(_, p, t)
		if not IsOpen() then return end
		playerAccepted, targetAccepted = p or 0, t or 0
		UpdateAcceptUI()
	end)
	WM.On("BAG_UPDATE", function()
		if IsOpen() then RenderBags() end
	end)
	WM.On("ITEM_LOCK_CHANGED", function()
		if IsOpen() then RenderBags() end
	end)
end)
