--------------------------------------------------------------------------------
-- WowMobile · AuctionHouse
-- Touch rebuild of the classic auction house (the LoD Blizzard_AuctionUI is
-- kept from ever loading — Blizzard.lua drops AUCTION_HOUSE_SHOW from
-- UIParent), as a three-tab SheetKit sheet:
--   Browse — search box (phone-keyboard entry pattern), category chips,
--            quality/usable filters, big result rows; tapping a row unfolds
--            BID / BUYOUT buttons, each behind a confirm tap; prev/next page.
--   Sell   — sell slot filled via MoveMode or the bag list, stack size +
--            number-of-stacks steppers (the 1.15 API posts multi-stack),
--            bid/buyout money steppers, duration choice, live deposit,
--            big Create Auction (+ the server's post-warning confirm).
--   Owned  — your auctions with per-row confirm-to-Cancel and a pager. The
--            client only fills the "owner" list after an explicit
--            GetOwnerAuctionItems() query — issued once per session on
--            AUCTION_HOUSE_SHOW (the official UI's pattern: "the get auctions
--            query is only run once per session, after that you only get
--            updates", Blizzard_AuctionUI.lua) — then per page flip.
--
-- API notes (verified against the 1.15 client UI source — Blizzard_AuctionUI/
-- Classic/Blizzard_AuctionUI.lua, gethe/wow-ui-source classic_era branch):
--   * QueryAuctionItems(text, minLevel, maxLevel, page, usable, rarity,
--     getAll, exactMatch, filterData) — filterData entries are tables of
--     { classID, subClassID, inventoryType } (AuctionCategoryMixin:AddFilter);
--     page is 0-based, NUM_AUCTION_ITEMS_PER_PAGE (50) per page.
--   * The query throttle is CanSendAuctionQuery (~0.3 s between page
--     queries on the 1.14+ throttling era kept): every query goes through
--     QueueQuery below, which waits the throttle out on a short ticker that
--     only exists while a query is pending.
--   * Posting/deposit go through the WM.PostAuction / WM.AuctionDeposit
--     Compat wrappers (1.15's PostAuction/GetAuctionDeposit vs the older
--     StartAuction/CalculateAuctionDeposit — signatures documented there).
--   * GetAuctionItemInfo("list"|"owner", i) → name, texture, count, quality,
--     canUse, level, levelColHeader, minBid, minIncrement, buyoutPrice,
--     bidAmount, highBidder, bidderFullName, owner, ownerFullName,
--     saleStatus, itemId, hasAllInfo; GetAuctionItemTimeLeft → 1..4
--     (labels AUCTION_TIME_LEFT1..4).
-- All sell-slot/bag mutations run through SheetKit.CanMove (out-of-combat
-- rule; combat shows the notice, nothing is queued).
--------------------------------------------------------------------------------

local _, WM = ...

local PER_PAGE = NUM_AUCTION_ITEMS_PER_PAGE or 50

local sheet
local stacks, scrollers = {}, {}
local bagList
local searchField
local bidMoney, buyoutMoney, stackStepper, numStacksStepper

-- Browse state. `selected` remembers the tapped row as { index, name } so a
-- list refresh that shuffles indices can drop a stale selection instead of
-- bidding on the wrong auction.
local browse = {
	page = 0,
	category = nil, -- index into CATEGORIES
	quality = 1,    -- index into QUALITIES
	usable = false,
	searched = false,
	selected = nil,
	confirm = nil, -- "bid" | "buyout" awaiting the confirm tap
}
local pendingQuery -- QueryAuctionItems args awaiting the throttle
local queryTicker

local sell = {
	duration = 3,       -- 1|2|3 (2h/8h/24h, see Compat notes)
	confirmPost = nil,  -- args cached for the AUCTION_HOUSE_POST_WARNING confirm
}
local owned = {
	page = 0,            -- 0-based, like the browse list (PER_PAGE per page)
	confirmCancel = nil, -- owner-list index awaiting the confirm tap
}

-- Item classes for the category chips (numeric fallbacks are the classic
-- item-class IDs, matching Enum.ItemClass on 1.15).
local IC = (Enum and Enum.ItemClass) or {}
local CATEGORIES = {
	{ label = "Weapons",    classID = IC.Weapon or 2 },
	{ label = "Armor",      classID = IC.Armor or 4 },
	{ label = "Consumable", classID = IC.Consumable or 0 },
	{ label = "Containers", classID = IC.Container or 1 },
	{ label = "Trade Goods", classID = IC.Tradegoods or 7 },
	{ label = "Reagents",   classID = IC.Reagent or 5 },
	{ label = "Projectiles", classID = IC.Projectile or 6 },
	{ label = "Recipes",    classID = IC.Recipe or 9 },
	{ label = "Quest",      classID = IC.Questitem or 12 },
}
local QUALITIES = {
	{ rarity = nil, label = "Quality: All" },
	{ rarity = 2,   label = "Uncommon+" },
	{ rarity = 3,   label = "Rare+" },
	{ rarity = 4,   label = "Epic+" },
}
local DURATIONS = {
	{ value = 1, label = AUCTION_DURATION_ONE or "2 hours" },
	{ value = 2, label = AUCTION_DURATION_TWO or "8 hours" },
	{ value = 3, label = AUCTION_DURATION_THREE or "24 hours" },
}

local RenderBrowse, RenderSell, RenderOwned -- forward declarations

local function RenderTab(key)
	if not sheet or not sheet:IsShown() then return end
	if key ~= sheet.activeTab then return end
	if key == "browse" then
		RenderBrowse()
	elseif key == "sell" then
		RenderSell()
	elseif key == "owned" then
		RenderOwned()
	end
end

--------------------------------------------------------------------------------
-- Query throttle
--------------------------------------------------------------------------------

local function SendPendingQuery()
	local q = pendingQuery
	if not q then return end
	if not CanSendAuctionQuery("list") then return end -- ticker retries
	pendingQuery = nil
	if queryTicker then
		queryTicker:Cancel()
		queryTicker = nil
	end
	QueryAuctionItems(q.text, nil, nil, q.page, q.usable, q.rarity, false, false, q.filterData)
end

-- Every browse query funnels through here: it fires immediately when the
-- throttle allows, otherwise parks the args and polls on a ticker that lives
-- only until the query goes out (no steady-state timer).
local function QueueQuery()
	local cat = browse.category and CATEGORIES[browse.category]
	pendingQuery = {
		text = searchField and searchField:GetText() or "",
		page = browse.page,
		usable = browse.usable or nil,
		rarity = QUALITIES[browse.quality].rarity,
		filterData = cat and { { classID = cat.classID } } or nil,
	}
	browse.searched = true
	browse.selected, browse.confirm = nil, nil
	SendPendingQuery()
	if pendingQuery and not queryTicker then
		queryTicker = C_Timer.NewTicker(0.4, SendPendingQuery)
	end
	RenderTab("browse") -- show the "searching" state right away
end

--------------------------------------------------------------------------------
-- Browse tab
--------------------------------------------------------------------------------

-- Next valid bid for a result row (classic rule: current bid + increment,
-- or the minimum bid when nobody has bid yet).
local function NextBid(minBid, minIncrement, bidAmount)
	if bidAmount and bidAmount > 0 then
		return bidAmount + (minIncrement or 0)
	end
	return minBid or 0
end

RenderBrowse = function()
	local st = stacks.browse
	st.Reset()

	st.Anchor(searchField, 96)
	st.Row({
		{ label = "Search", green = true, onTap = function()
			browse.page = 0
			QueueQuery()
		end },
		{ label = browse.usable and "Usable only: ON" or "Usable only: off",
			selected = browse.usable,
			onTap = function()
				browse.usable = not browse.usable
				browse.page = 0
				QueueQuery()
			end },
		{ label = QUALITIES[browse.quality].label,
			selected = QUALITIES[browse.quality].rarity ~= nil,
			onTap = function()
				browse.quality = browse.quality % #QUALITIES + 1
				browse.page = 0
				QueueQuery()
			end },
	})

	-- Category chips: "All" + 9 classes as two rows of five.
	local function CategoryChip(i)
		local label = (i == nil) and "All" or CATEGORIES[i].label
		return {
			label = label,
			selected = browse.category == i,
			onTap = function()
				browse.category = i
				browse.page = 0
				QueueQuery()
			end,
		}
	end
	st.Row({ CategoryChip(nil), CategoryChip(1), CategoryChip(2), CategoryChip(3), CategoryChip(4) })
	st.Row({ CategoryChip(5), CategoryChip(6), CategoryChip(7), CategoryChip(8), CategoryChip(9) })

	st.Text("Your money: " .. WM.FormatMoney(GetMoney()), 26)

	if pendingQuery then
		st.Text("Searching…", 30, 0.7, 0.7, 0.75)
	elseif not browse.searched then
		st.Text("Pick filters and tap Search.", 30, 0.7, 0.7, 0.75)
	else
		local numBatch, total = GetNumAuctionItems("list")
		if numBatch == 0 then
			st.Text("No auctions found.", 30, 0.7, 0.7, 0.75)
		end
		for i = 1, numBatch do
			local name, texture, count, quality, _, level, _, minBid, minIncrement,
				buyoutPrice, bidAmount, highBidder = GetAuctionItemInfo("list", i)
			local timeLeft = GetAuctionItemTimeLeft("list", i)
			local owner = select(14, GetAuctionItemInfo("list", i))
			local label = WM.SheetKit.QualityName(name or RETRIEVING_ITEM_INFO, name and quality or nil)
			if count and count > 1 then label = label .. " x" .. count end
			local bid = NextBid(minBid, minIncrement, bidAmount)
			local line2 = "Bid " .. WM.FormatMoney(bid)
			if buyoutPrice and buyoutPrice > 0 then
				line2 = line2 .. " · Buy " .. WM.FormatMoney(buyoutPrice)
			end
			line2 = line2 .. " · " .. (_G["AUCTION_TIME_LEFT" .. (timeLeft or 0)] or "?")
			if owner then line2 = line2 .. " · " .. owner end
			if highBidder then line2 = line2 .. " |cff33cc33(your bid)|r" end
			if level and level > 1 then label = label .. " |cff9999a3(lvl " .. level .. ")|r" end

			local index = i
			local isSelected = browse.selected and browse.selected.index == i
				and browse.selected.name == name
			local b = st.Button(label .. "\n|cffbbbbc4" .. line2 .. "|r", texture, function()
				if isSelected then
					browse.selected, browse.confirm = nil, nil
				else
					browse.selected = { index = index, name = name }
					browse.confirm = nil
				end
				RenderTab("browse")
			end, function(tt) tt:SetAuctionItem("list", index) end)
			if isSelected then
				local a = WM.Colors.accent
				b.borderTex:SetColorTexture(a[1], a[2], a[3], 1)
			end

			-- Action row under the selected result; BID/BUYOUT each arm a
			-- confirm tap so a stray thumb never spends money directly.
			if isSelected then
				if browse.confirm == "bid" then
					st.Row({
						{ label = "Confirm bid " .. WM.FormatMoney(bid), green = true,
							disabled = GetMoney() < bid,
							onTap = function()
								PlaceAuctionBid("list", index, bid)
								browse.selected, browse.confirm = nil, nil
								RenderTab("browse")
							end },
						{ label = "Back", onTap = function()
							browse.confirm = nil
							RenderTab("browse")
						end },
					})
				elseif browse.confirm == "buyout" then
					st.Row({
						{ label = "Confirm buyout " .. WM.FormatMoney(buyoutPrice or 0), green = true,
							disabled = GetMoney() < (buyoutPrice or 0),
							onTap = function()
								PlaceAuctionBid("list", index, buyoutPrice)
								browse.selected, browse.confirm = nil, nil
								RenderTab("browse")
							end },
						{ label = "Back", onTap = function()
							browse.confirm = nil
							RenderTab("browse")
						end },
					})
				else
					st.Row({
						{ label = "BID " .. WM.FormatMoney(bid),
							disabled = highBidder ~= nil or GetMoney() < bid,
							onTap = function()
								browse.confirm = "bid"
								RenderTab("browse")
							end },
						{ label = (buyoutPrice and buyoutPrice > 0)
								and ("BUYOUT " .. WM.FormatMoney(buyoutPrice)) or "No buyout",
							disabled = not (buyoutPrice and buyoutPrice > 0) or GetMoney() < buyoutPrice,
							onTap = function()
								browse.confirm = "buyout"
								RenderTab("browse")
							end },
					})
				end
			end
		end

		-- Pager. Page flips re-query and therefore respect the same throttle.
		if total and total > PER_PAGE then
			local lastPage = math.ceil(total / PER_PAGE) - 1
			st.Row({
				{ label = "< Prev", disabled = browse.page <= 0, onTap = function()
					browse.page = browse.page - 1
					QueueQuery()
				end },
				{ label = "Page " .. (browse.page + 1) .. "/" .. (lastPage + 1), disabled = true },
				{ label = "Next >", disabled = browse.page >= lastPage, onTap = function()
					browse.page = browse.page + 1
					QueueQuery()
				end },
			})
		end
	end

	st.Finish("browse:" .. browse.page .. ":" .. tostring(browse.selected and browse.selected.index))
end

--------------------------------------------------------------------------------
-- Sell tab
--------------------------------------------------------------------------------

-- Put the cursor payload into the sell slot (swaps any current sell item back
-- onto the cursor, where MoveMode's carry bar adopts it).
local function DropOnSellSlot()
	if not WM.SheetKit.CanMove() then return end
	local t = GetCursorInfo()
	if t ~= "item" then
		if t then WM.MoveMode.Cancel() end
		return
	end
	ClickAuctionSellItemButton()
end

local function Deposit()
	return WM.AuctionDeposit(sell.duration, bidMoney.GetCopper(), buyoutMoney.GetCopper(),
		stackStepper.Get(), numStacksStepper.Get())
end

RenderSell = function()
	local st = stacks.sell
	st.Reset()

	local name, texture, count, quality, _, price, _, stackCount, totalCount =
		GetAuctionSellItemInfo()
	local carrying = GetCursorInfo() == "item"

	local slot
	if name then
		slot = st.Button(WM.SheetKit.QualityName(name, quality)
			.. (count and count > 1 and (" x" .. count) or "")
			.. "\n|cffbbbbc4You own " .. (totalCount or count or 1)
			.. " — tap to take back|r", texture, function()
			if carrying then
				DropOnSellSlot()
			elseif WM.SheetKit.CanMove() then
				ClickAuctionSellItemButton() -- lifts the sell item onto the cursor; MoveMode adopts
			end
		end)
	else
		slot = st.Button(carrying and "Tap to place the carried item here"
			or "Auction item — long-press one in the list below (or in your Bags) and tap here",
			nil, function() DropOnSellSlot() end)
	end
	if carrying then
		local g = WM.Colors.green
		slot.borderTex:SetColorTexture(g[1], g[2], g[3], 1)
	end

	if name then
		-- Stack machinery only where the API supports it (stackable items);
		-- a 1-stack item keeps the steppers parked at 1.
		local maxStack = math.min(stackCount or 1, totalCount or 1)
		if maxStack > 1 then
			st.Anchor(stackStepper, 140)
			st.Anchor(numStacksStepper, 140)
		else
			-- SetSilent: parking with Set() from inside this render would
			-- re-enter it via onChange (see CreateStepper).
			stackStepper.SetSilent(1)
			numStacksStepper.SetSilent(1)
		end
		st.Anchor(bidMoney, 150)
		st.Anchor(buyoutMoney, 150)

		local specs = {}
		for i = 1, #DURATIONS do
			local d = DURATIONS[i]
			specs[i] = {
				label = d.label,
				selected = sell.duration == d.value,
				onTap = function()
					sell.duration = d.value
					RenderTab("sell")
				end,
			}
		end
		st.Row(specs)

		st.Text("Deposit: " .. WM.FormatMoney(Deposit())
			.. "   ·   Your money: " .. WM.FormatMoney(GetMoney()), 28)

		-- PostAuction applies the entered bid/buyout to EACH stack (per-stack
		-- prices — official StartPost semantics). With several stacks that is
		-- a classic mispricing footgun (entering the intended TOTAL posts
		-- every stack at N× the price), so spell the math out before the tap.
		local nStacks = numStacksStepper.Get()
		if nStacks > 1 then
			local perBuyout = buyoutMoney.GetCopper()
			st.Text("|cffffcc33Prices are PER STACK:|r posts " .. nStacks
				.. " auctions of " .. stackStepper.Get() .. " each"
				.. (perBuyout > 0 and (" — total buyout "
					.. WM.FormatMoney(perBuyout * nStacks)) or ""), 28)
		end

		local bid, buyout = bidMoney.GetCopper(), buyoutMoney.GetCopper()
		local problem
		if bid <= 0 then
			problem = "Set a starting bid"
		elseif buyout > 0 and buyout < bid then
			problem = "Buyout is below the starting bid"
		elseif Deposit() > GetMoney() then
			problem = "Can't afford the deposit"
		end

		if sell.confirmPost then
			-- The server flagged the post (AUCTION_HOUSE_POST_WARNING — e.g.
			-- posting with no buyout); re-post confirmed or back out.
			st.Text("The auction house wants a confirmation for this post.", 28, 1, 0.82, 0)
			st.Row({
				{ label = "Confirm Create Auction", green = true, onTap = function()
					local p = sell.confirmPost
					sell.confirmPost = nil
					WM.PostAuction(p.bid, p.buyout, p.duration, p.stack, p.num, true)
					RenderTab("sell")
				end },
				{ label = "Back", onTap = function()
					sell.confirmPost = nil
					RenderTab("sell")
				end },
			})
		else
			local create = st.Button(problem or "Create Auction", nil, function()
				local p = {
					bid = bidMoney.GetCopper(), buyout = buyoutMoney.GetCopper(),
					duration = sell.duration,
					stack = stackStepper.Get(), num = numStacksStepper.Get(),
				}
				if WM.PostAuction(p.bid, p.buyout, p.duration, p.stack, p.num, false) then
					sell.confirmPost = nil
				else
					-- false → the POST_WARNING/POST_ERROR event decides; cache
					-- the args so the warning's confirm can re-post them.
					sell.confirmPost = p
				end
				RenderTab("sell")
			end, nil)
			if problem then
				WM.SetButtonEnabled(create, false)
			else
				local a = WM.Colors.accent
				create.borderTex:SetColorTexture(a[1], a[2], a[3], 1)
			end
		end
	end

	st.Text("Your items — tap to load the sell slot, long-press to carry", 26, 0.7, 0.7, 0.75)
	local used = bagList.Render(st.Y(), function(bag, slotIndex)
		if not WM.SheetKit.CanMove() then return end
		if GetCursorInfo() then return end -- a live carry owns the next tap
		WM.Container.Pickup(bag, slotIndex)
		if GetCursorInfo() == "item" then
			ClickAuctionSellItemButton()
		end
	end)
	st.Skip(used)
	st.Finish("sell")
end

--------------------------------------------------------------------------------
-- My auctions tab
--------------------------------------------------------------------------------

RenderOwned = function()
	local st = stacks.owned
	st.Reset()

	local numBatch, totalOwned = GetNumAuctionItems("owner")
	st.Text("Your money: " .. WM.FormatMoney(GetMoney()), 26)
	if numBatch == 0 then
		st.Text("You have no auctions running.", 30, 0.7, 0.7, 0.75)
	end
	for i = 1, numBatch do
		local name, texture, count, quality, _, _, _, minBid, _, buyoutPrice,
			bidAmount = GetAuctionItemInfo("owner", i)
		local saleStatus = select(16, GetAuctionItemInfo("owner", i))
		local timeLeft = GetAuctionItemTimeLeft("owner", i)
		local label = WM.SheetKit.QualityName(name or RETRIEVING_ITEM_INFO, name and quality or nil)
		if count and count > 1 then label = label .. " x" .. count end
		local line2
		if saleStatus == 1 then
			line2 = "|cff33cc33Sold|r"
		else
			line2 = (bidAmount and bidAmount > 0)
				and ("Bid " .. WM.FormatMoney(bidAmount)) or ("No bids — min " .. WM.FormatMoney(minBid or 0))
			if buyoutPrice and buyoutPrice > 0 then
				line2 = line2 .. " · Buy " .. WM.FormatMoney(buyoutPrice)
			end
			line2 = line2 .. " · " .. (_G["AUCTION_TIME_LEFT" .. (timeLeft or 0)] or "?")
		end
		local index = i
		st.Button(label .. "\n|cffbbbbc4" .. line2 .. "|r", texture, nil,
			function(tt) tt:SetAuctionItem("owner", index) end)
		if saleStatus ~= 1 then
			if owned.confirmCancel == i then
				st.Row({
					{ label = "Confirm cancel" .. ((bidAmount and bidAmount > 0)
							and " (bid is forfeit to the bidder)" or ""),
						red = true,
						onTap = function()
							CancelAuction(index)
							owned.confirmCancel = nil
							RenderTab("owned")
						end },
					{ label = "Back", onTap = function()
						owned.confirmCancel = nil
						RenderTab("owned")
					end },
				})
			else
				st.Row({
					{ label = "Cancel this auction", onTap = function()
						owned.confirmCancel = index
						RenderTab("owned")
					end },
				})
			end
		end
	end

	-- Pager: the page argument exists in the client source (AuctionFrame_Show
	-- passes AuctionFrameAuctions.page into GetOwnerAuctionItems), but the
	-- official UI never pages the owner list past 0 — it fetches once and
	-- scrolls the batch. This pager is a best-effort extension: if the server
	-- returns the full list regardless of page, every row still renders and
	-- the flips are harmless no-ops. Owner-page queries are not gated behind
	-- CanSendAuctionQuery — the default UI issues its fetch directly.
	if totalOwned and totalOwned > PER_PAGE then
		local lastPage = math.ceil(totalOwned / PER_PAGE) - 1
		local function FlipTo(page)
			owned.page = page
			owned.confirmCancel = nil
			GetOwnerAuctionItems(owned.page) -- AUCTION_OWNED_LIST_UPDATE re-renders
			RenderTab("owned")
		end
		st.Row({
			{ label = "< Prev", disabled = owned.page <= 0, onTap = function()
				FlipTo(owned.page - 1)
			end },
			{ label = "Page " .. (owned.page + 1) .. "/" .. (lastPage + 1), disabled = true },
			{ label = "Next >", disabled = owned.page >= lastPage, onTap = function()
				FlipTo(owned.page + 1)
			end },
		})
	end
	st.Finish("owned:" .. owned.page)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function ResetSession()
	browse.page, browse.searched = 0, false
	browse.selected, browse.confirm = nil, nil
	owned.page = 0
	sell.confirmPost, owned.confirmCancel = nil, nil
	pendingQuery = nil
	if queryTicker then
		queryTicker:Cancel()
		queryTicker = nil
	end
	for _, st in pairs(stacks) do st.ClearView() end
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("auction", "Auction House", {
		{ key = "browse", label = "Browse" },
		{ key = "sell",   label = "Sell" },
		{ key = "owned",  label = "My Auctions" },
	})
	sheet.OnDismiss = function()
		CloseAuctionHouse() -- AUCTION_HOUSE_CLOSED then hides the sheet
	end
	sheet.OnTabShow = RenderTab

	for _, key in ipairs({ "browse", "sell", "owned" }) do
		scrollers[key] = WM.Deck.CreateScroller(sheet.tabFrames[key])
		stacks[key] = Kit.NewStack(scrollers[key])
	end
	bagList = Kit.NewBagList(scrollers.sell)

	searchField = Kit.CreateTextField(scrollers.browse.child, 950, "Search items…", 63)
	searchField.onEnter = function()
		browse.page = 0
		QueueQuery()
	end

	stackStepper = Kit.CreateStepper(scrollers.sell.child, 460, "Stack size")
	stackStepper.maxFn = function()
		local _, _, _, _, _, _, _, stackCount, totalCount = GetAuctionSellItemInfo()
		return math.min(stackCount or 1, totalCount or 1)
	end
	stackStepper.onChange = function() RenderTab("sell") end
	numStacksStepper = Kit.CreateStepper(scrollers.sell.child, 460, "Number of stacks")
	numStacksStepper.maxFn = function()
		local _, _, _, _, _, _, _, _, totalCount = GetAuctionSellItemInfo()
		return math.max(1, math.floor((totalCount or 1) / stackStepper.Get()))
	end
	numStacksStepper.onChange = function() RenderTab("sell") end
	bidMoney = Kit.CreateMoneyStepper(scrollers.sell.child, "Starting bid")
	bidMoney.onChange = function() RenderTab("sell") end
	buyoutMoney = Kit.CreateMoneyStepper(scrollers.sell.child, "Buyout (0 = none)")
	buyoutMoney.onChange = function() RenderTab("sell") end

	WM.On("AUCTION_HOUSE_SHOW", function()
		ResetSession()
		-- The server only fills the "owner" list after an explicit query;
		-- without this, GetNumAuctionItems("owner") stays 0 forever and no
		-- AUCTION_OWNED_LIST_UPDATE delivers data. Once per session, up front
		-- (mirroring Blizzard_AuctionUI's load/show-time query) — after this,
		-- posts/cancels/sales stream in as owned-list updates on their own.
		GetOwnerAuctionItems(owned.page)
		sheet.Open(UnitName("npc") or "Auction House")
		sheet.SelectTab("browse")
	end)
	WM.On("AUCTION_HOUSE_CLOSED", function()
		if sheet:IsShown() then sheet:Hide() end
		ResetSession()
	end)

	WM.On("AUCTION_ITEM_LIST_UPDATE", function()
		-- Results (or an update to them) arrived; indices may have shuffled,
		-- so RenderBrowse revalidates the selection by name.
		RenderTab("browse")
	end)
	WM.On("AUCTION_OWNED_LIST_UPDATE", function()
		owned.confirmCancel = nil
		RenderTab("owned")
	end)
	WM.On("NEW_AUCTION_UPDATE", function()
		-- Sell item placed/removed. Prefill the bid with the server's default
		-- price the first time a fresh item lands in an untouched stepper.
		local name, _, count, _, _, price = GetAuctionSellItemInfo()
		if name then
			if bidMoney.GetCopper() == 0 and price and price > 0 then
				bidMoney.SetCopper(price)
			end
			-- Steppers re-clamp against the live sell item via maxFn at read
			-- time; seed them with the placed stack. Silent — the explicit
			-- RenderTab below repaints, no need for onChange's re-render.
			stackStepper.SetSilent(count or 1)
			numStacksStepper.SetSilent(1)
		end
		RenderTab("sell")
	end)
	WM.TryOn("AUCTION_HOUSE_POST_WARNING", function()
		-- Keep sell.confirmPost (set by the Create tap) and surface the row.
		RenderTab("sell")
	end)
	WM.TryOn("AUCTION_HOUSE_POST_ERROR", function()
		sell.confirmPost = nil
		UIErrorsFrame:AddMessage("The auction could not be created.", 1, 0.3, 0.3)
		RenderTab("sell")
	end)

	WM.On("PLAYER_MONEY", function()
		RenderTab(sheet.activeTab)
	end)
	WM.On("BAG_UPDATE", function()
		RenderTab("sell") -- bag list + total counts
	end)
	-- Carry state drives the sell slot's green drop cue.
	WM.TryOn("CURSOR_CHANGED", function() RenderTab("sell") end)
	WM.TryOn("CURSOR_UPDATE", function() RenderTab("sell") end)
end)
