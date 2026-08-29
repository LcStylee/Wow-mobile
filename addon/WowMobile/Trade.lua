--------------------------------------------------------------------------------
-- WowMobile · Trade
-- Touch rebuild of player-to-player trading (the default TradeFrame is
-- banished in Blizzard.lua — TradeFrame_OnHide calls CloseTrade, so it must
-- never open). One sheet on TRADE_SHOW:
--   * your offer: 6 tradable slots (MAX_TRADABLE_ITEMS) + the separate
--     "will not be traded" slot (index MAX_TRADE_ITEMS = 7, the enchant
--     target slot) — filled via MoveMode/the bag list, tap a filled slot to
--     take it back (ClickTradeButton does both, Blizzard's own semantics),
--   * money stepper wired to WM.SetTradeMoney (C_TradeInfo.SetTradeMoney on
--     1.15 — the bare global was removed on the 10.x engine, see Compat.lua),
--   * their offer mirrored read-only (GetTradeTargetItemInfo, target money),
--   * big Accept / Cancel with the partner's accept state shown loud —
--     TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted); your own Accept
--     turns into "Un-accept" (CancelTradeAccept) while armed.
-- Item/money mutations run through SheetKit.CanMove (out-of-combat rule).
--------------------------------------------------------------------------------

local _, WM = ...

local NUM_TRADABLE = MAX_TRADABLE_ITEMS or 6
local WNBT_SLOT = MAX_TRADE_ITEMS or 7 -- "will not be traded"

local sheet, scroller, st, bagList, moneyStepper
local playerAccepted, targetAccepted = 0, 0
local partnerName

local Render -- forward

--------------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------------

local function FirstFreeTradeSlot()
	for i = 1, NUM_TRADABLE do
		if not GetTradePlayerItemInfo(i) then return i end
	end
	return nil
end

local function PlayerSlotTap(id)
	if not WM.SheetKit.CanMove() then return end
	local t = GetCursorInfo()
	if t and t ~= "item" then
		WM.MoveMode.Cancel()
		return
	end
	-- Places the carried item into the slot, or lifts the slot's item back
	-- onto the cursor (adopted into MoveMode's carry bar).
	ClickTradeButton(id)
end

-- One side's slots as a stack grid. mine=true renders tappable player slots.
local function SlotGrid(mine, fromSlot, toSlot, emptyLabel)
	local carrying = GetCursorInfo() == "item"
	local items = {}
	for id = fromSlot, toSlot do
		local name, texture, count, quality
		if mine then
			name, texture, count, quality = GetTradePlayerItemInfo(id)
		else
			name, texture, count, quality = GetTradeTargetItemInfo(id)
		end
		local slot = id
		items[#items + 1] = {
			icon = texture,
			count = count,
			label = name and WM.SheetKit.QualityName(name, quality) or emptyLabel,
			slot = slot,
			dropTarget = mine and carrying or false,
			tooltip = name and function(tt)
				if mine then
					tt:SetTradePlayerItem(slot)
				else
					tt:SetTradeTargetItem(slot)
				end
			end or nil,
		}
	end
	st.Grid(items, mine and function(item)
		PlayerSlotTap(item.slot)
	end or nil)
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

Render = function()
	if not sheet:IsShown() then return end
	st.Reset()

	local them = partnerName or UNKNOWN
	if targetAccepted == 1 then
		st.Text(them .. " has ACCEPTED the trade.", 32, 0.3, 0.8, 0.35)
	else
		st.Text(them .. " has not accepted yet.", 32, 0.85, 0.75, 0.3)
	end
	if playerAccepted == 1 then
		st.Text("You accepted — waiting for " .. them .. ".", 28, 0.7, 0.7, 0.75)
	end

	st.Row({
		(playerAccepted == 1) and
			{ label = "Un-accept", onTap = function() CancelTradeAccept() end } or
			{ label = "ACCEPT TRADE", green = true, onTap = function() AcceptTrade() end },
		{ label = "Cancel trade", red = true, onTap = function()
			CancelTrade() -- TRADE_CLOSED then hides the sheet
		end },
	})

	st.Text("Your offer", 32, 1, 0.82, 0)
	SlotGrid(true, 1, NUM_TRADABLE, "Empty — tap with a carried item")
	st.Anchor(moneyStepper, 150)
	st.Text("Will not be traded (shown to " .. them .. ", stays yours — enchant target)",
		26, 0.7, 0.7, 0.75)
	SlotGrid(true, WNBT_SLOT, WNBT_SLOT, "Empty")

	st.Text(them .. "'s offer   ·   money: " .. WM.FormatMoney(GetTargetTradeMoney() or 0),
		32, 1, 0.82, 0)
	SlotGrid(false, 1, NUM_TRADABLE, "Empty")
	st.Text(them .. "'s will-not-be-traded item", 26, 0.7, 0.7, 0.75)
	SlotGrid(false, WNBT_SLOT, WNBT_SLOT, "Empty")

	st.Text("Your items — tap to offer, long-press to carry", 26, 0.7, 0.7, 0.75)
	local used = bagList.Render(st.Y(), function(bag, slotIndex)
		if not WM.SheetKit.CanMove() then return end
		if GetCursorInfo() then return end -- a live carry owns the next tap
		local free = FirstFreeTradeSlot()
		if not free then
			UIErrorsFrame:AddMessage("All " .. NUM_TRADABLE .. " trade slots are full.", 1, 0.3, 0.3)
			return
		end
		WM.Container.Pickup(bag, slotIndex)
		if GetCursorInfo() == "item" then
			ClickTradeButton(free)
		end
	end)
	st.Skip(used)
	st.Finish("trade")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("trade", "Trade")
	sheet.OnDismiss = function()
		CancelTrade() -- TRADE_CLOSED then hides the sheet
	end

	scroller = WM.Deck.CreateScroller(sheet.body)
	st = Kit.NewStack(scroller)
	bagList = Kit.NewBagList(scroller)

	moneyStepper = Kit.CreateMoneyStepper(scroller.child, "Your money offer")
	moneyStepper.onChange = function(copper)
		if not sheet:IsShown() then return end
		if copper > GetMoney() then
			moneyStepper.SetCopper(GetMoney()) -- re-enters onChange with the clamp
			return
		end
		WM.SetTradeMoney(copper) -- server resets accepts; TRADE_ACCEPT_UPDATE re-renders
	end

	WM.On("TRADE_SHOW", function()
		-- The trade partner is the "NPC" unit for the whole session (the
		-- default TradeFrame reads the same token).
		partnerName = UnitName("NPC")
		playerAccepted, targetAccepted = 0, 0
		moneyStepper.SetCopper(0)
		sheet.Open("Trade — " .. (partnerName or UNKNOWN))
		Render()
	end)
	WM.On("TRADE_CLOSED", function()
		if sheet:IsShown() then sheet:Hide() end
		st.ClearView()
	end)
	-- TRADE_REQUEST_CANCEL fires when the other side aborts before TRADE_CLOSED
	-- on some paths; treat it as closed.
	WM.TryOn("TRADE_REQUEST_CANCEL", function()
		if sheet:IsShown() then sheet:Hide() end
		st.ClearView()
	end)

	WM.On("TRADE_PLAYER_ITEM_CHANGED", Render)
	WM.On("TRADE_TARGET_ITEM_CHANGED", Render)
	WM.TryOn("TRADE_UPDATE", Render)
	WM.On("TRADE_MONEY_CHANGED", function()
		-- Mirror server-side money state (covers our own SetTradeMoney echo
		-- and any clamp the server applied).
		moneyStepper.SetCopper(GetPlayerTradeMoney() or 0)
		Render()
	end)
	WM.On("TRADE_ACCEPT_UPDATE", function(_, pAccepted, tAccepted)
		playerAccepted, targetAccepted = pAccepted or 0, tAccepted or 0
		Render()
	end)
	WM.On("PLAYER_MONEY", function()
		if sheet:IsShown() then Render() end
	end)
	WM.On("BAG_UPDATE", function()
		if sheet:IsShown() then Render() end
	end)
	WM.TryOn("CURSOR_CHANGED", function()
		if sheet:IsShown() then Render() end
	end)
	WM.TryOn("CURSOR_UPDATE", function()
		if sheet:IsShown() then Render() end
	end)
end)
