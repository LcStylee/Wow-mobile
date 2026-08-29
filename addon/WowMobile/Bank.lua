--------------------------------------------------------------------------------
-- WowMobile · Bank
-- Touch rebuild of the bank (the default BankFrame is banished in
-- Blizzard.lua with the established technique — its OnHide calls
-- CloseBankFrame, which would end the banker session, so it must never
-- open). One sheet on BANKFRAME_OPENED:
--   * the generic bank grid (container BANK_CONTAINER = -1) and every
--     equipped bank bag's grid (containers NUM_BAG_SLOTS+1 .. +NUM_BANKBAGSLOTS),
--   * the player's own bag grids below, so items move BOTH directions
--     without leaving the sheet (opening the Bags panel would dismiss this
--     sheet through the exclusive system and close the bank),
--   * tap = auto-move across (Container.UseItem: the same "use at a bank
--     moves the item to the other side" semantics the default bags have),
--     long-press = MoveMode carry (stacks get the split stepper), tap while
--     carrying = place/swap into that exact slot,
--   * "Buy slot" with GetBankSlotCost(GetNumBankSlots()) behind a confirm
--     tap → PurchaseSlot(); empty purchased bag slots equip a carried bag
--     via PickupInventoryItem on the slot's inventory ID.
-- Cells mirror the Bags panel grid (114 px, 8 columns) but stay INSECURE
-- buttons — nothing here needs a secure action, so combat never blocks a
-- rebuild (moves themselves are still out-of-combat via SheetKit.CanMove).
--------------------------------------------------------------------------------

local _, WM = ...

local BANK_BAG = BANK_CONTAINER or -1
local COLS = 8
local CELL = 114 -- same scroller-budget arithmetic as Bags.lua (8x120-6 = 954 <= 966)
local GAP = 6

local sheet, scroller, st
local cells = {}   -- "bag:slot" -> cell button
local shownCells   -- set collected during a render
local confirmBuy = false

local function BankBagContainers()
	local first = (NUM_BAG_SLOTS or 4) + 1
	local last = (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6)
	return first, last
end

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

local function CellTooltip(cell)
	WM.AttachTooltip(cell, function(tt)
		if cell.bag == BANK_BAG and BankButtonIDToInvSlotID then
			-- Generic bank slots tooltip via their inventory IDs (the default
			-- BankFrame's own technique); bag containers use SetBagItem.
			tt:SetInventoryItem("player", BankButtonIDToInvSlotID(cell.slot))
		else
			tt:SetBagItem(cell.bag, cell.slot)
		end
	end)
end

local function OnCellClick(cell, mouseButton)
	if mouseButton == "RightButton" then
		WM.MoveMode.Begin({ kind = "bag", bag = cell.bag, slot = cell.slot })
		return
	end
	local t = GetCursorInfo()
	if t then
		if not WM.SheetKit.CanMove() then return end
		if t == "item" then
			WM.Container.Pickup(cell.bag, cell.slot) -- place/swap into this slot
		else
			WM.MoveMode.Cancel() -- spells etc. have no home in a bank
		end
		return
	end
	local icon = WM.Container.GetItemInfo(cell.bag, cell.slot)
	if not icon then return end
	if not WM.SheetKit.CanMove() then return end
	-- With the bank open, "use" moves the item to the other side (bags <->
	-- bank), the default UI's tap-to-deposit/withdraw.
	WM.Container.UseItem(cell.bag, cell.slot)
end

local function GetCell(bag, slot)
	local key = bag .. ":" .. slot
	local cell = cells[key]
	if not cell then
		cell = CreateFrame("Button", nil, scroller.child)
		cell:SetSize(WM.Px(CELL), WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local hl = cell:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.10)
		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(4))
		cell.icon:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
		cell.count = WM.CreateText(cell, 26, "OUTLINE")
		cell.count:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
		cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cell.bag, cell.slot = bag, slot
		cell:SetScript("OnClick", OnCellClick)
		CellTooltip(cell)
		-- Cell identity is fixed (one cell per container slot, never pooled
		-- across views), so the permanent MoveMode drop-cue overlay is safe.
		WM.MoveMode.RegisterTarget(cell, WM.MoveMode.AcceptsItem)
		cells[key] = cell
	end
	return cell
end

local function UpdateCellVisuals(cell)
	local icon, count, locked, quality = WM.Container.GetItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		cell.icon:SetDesaturated(locked and true or false)
		cell.icon:SetVertexColor(1, 1, 1)
		cell.count:SetText(count and count > 1 and count or "")
		local q = quality and quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		if q then
			cell.borderTex:SetColorTexture(q.r, q.g, q.b, 1)
		else
			local bd = WM.Colors.border
			cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
		end
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
		local bd = WM.Colors.border
		cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
	end
end

-- Lays a container's grid into the stack flow at the current offset.
local function PlaceGrid(bag)
	local size = WM.Container.GetNumSlots(bag)
	if size == 0 then return end
	local y = st.Y()
	for slot = 1, size do
		local cell = GetCell(bag, slot)
		local col = (slot - 1) % COLS
		local row = math.floor((slot - 1) / COLS)
		cell:ClearAllPoints()
		cell:SetPoint("TOPLEFT", WM.Px(col * (CELL + GAP)), -WM.Px(y + row * (CELL + GAP)))
		UpdateCellVisuals(cell)
		cell:Show()
		shownCells[bag .. ":" .. slot] = true
	end
	st.Skip(math.ceil(size / COLS) * (CELL + GAP))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

local function Render()
	if not sheet:IsShown() then return end
	st.Reset()
	shownCells = {}

	st.Text("Your money: " .. WM.FormatMoney(GetMoney()), 26)

	-- Buy the next bank bag slot (cost of slot numSlots+1 is
	-- GetBankSlotCost(numSlots), the default BankFrame's own arithmetic).
	local numSlots, full = GetNumBankSlots()
	if not full then
		local cost = GetBankSlotCost(numSlots)
		if confirmBuy then
			st.Row({
				{ label = "Confirm: buy bag slot for " .. WM.FormatMoney(cost or 0),
					green = true,
					disabled = (cost or 0) > GetMoney(),
					onTap = function()
						confirmBuy = false
						PurchaseSlot()
					end },
				{ label = "Back", onTap = function()
					confirmBuy = false
					Render()
				end },
			})
		else
			local b = st.Button("Buy a bank bag slot — " .. WM.FormatMoney(cost or 0), nil, function()
				confirmBuy = true
				Render()
			end)
			WM.SetButtonEnabled(b, (cost or 0) <= GetMoney())
		end
	end

	st.Text("Bank", 32, 1, 0.82, 0)
	PlaceGrid(BANK_BAG)

	local firstBag, lastBag = BankBagContainers()
	for bag = firstBag, lastBag do
		local slotIndex = bag - firstBag + 1 -- 1-based purchased-slot index
		if slotIndex <= numSlots then
			local size = WM.Container.GetNumSlots(bag)
			if size > 0 then
				local invID = WM.Container.BagInventoryID(bag)
				local bagLink = invID and GetInventoryItemLink("player", invID)
				local bagName = bagLink and bagLink:match("%[(.-)%]") or ("Bank bag " .. slotIndex)
				st.Text(bagName, 30, 1, 0.82, 0)
				PlaceGrid(bag)
			else
				-- Purchased but empty: equip a carried bag here.
				local invID = WM.Container.BagInventoryID(bag)
				local carryingItem = GetCursorInfo() == "item"
				local b = st.Button(carryingItem
					and "Bank bag slot " .. slotIndex .. " — tap to equip the carried bag"
					or "Bank bag slot " .. slotIndex .. " — empty (long-press a bag, then tap here)",
					nil, function()
						if not WM.SheetKit.CanMove() then return end
						local t = GetCursorInfo()
						if t == "item" and invID then
							-- Places the carried bag into the inventory slot;
							-- a non-bag payload bounces with Blizzard's own
							-- error and stays on the cursor.
							PickupInventoryItem(invID)
						end
					end)
				if carryingItem then
					local g = WM.Colors.green
					b.borderTex:SetColorTexture(g[1], g[2], g[3], 1)
				end
			end
		end
	end

	st.Text("Your bags — tap an item to move it across", 30, 1, 0.82, 0)
	for bag = 0, NUM_BAG_SLOTS or 4 do
		PlaceGrid(bag)
	end

	-- Hide cells whose bag shrank/was swapped since the last render.
	for key, cell in pairs(cells) do
		if not shownCells[key] then cell:Hide() end
	end

	st.Finish("bank")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("bank", "Bank")
	sheet.OnDismiss = function()
		CloseBankFrame() -- BANKFRAME_CLOSED then hides the sheet
	end

	scroller = WM.Deck.CreateScroller(sheet.body)
	st = Kit.NewStack(scroller)

	WM.On("BANKFRAME_OPENED", function()
		confirmBuy = false
		sheet.Open(UnitName("npc") or "Bank")
		Render()
	end)
	WM.On("BANKFRAME_CLOSED", function()
		confirmBuy = false
		if sheet:IsShown() then sheet:Hide() end
		st.ClearView()
	end)

	WM.On("PLAYERBANKSLOTS_CHANGED", Render)
	WM.TryOn("PLAYERBANKBAGSLOTS_CHANGED", Render)
	WM.On("BAG_UPDATE", function()
		if sheet:IsShown() then Render() end
	end)
	WM.On("ITEM_LOCK_CHANGED", function()
		if sheet:IsShown() then Render() end
	end)
	WM.On("PLAYER_MONEY", function()
		if sheet:IsShown() then Render() end
	end)
	-- Carry state drives the empty-bag-slot cue (cell drop cues come from
	-- MoveMode.RegisterTarget overlays and need no re-render).
	WM.TryOn("CURSOR_CHANGED", function()
		if sheet:IsShown() then Render() end
	end)
	WM.TryOn("CURSOR_UPDATE", function()
		if sheet:IsShown() then Render() end
	end)
end)
