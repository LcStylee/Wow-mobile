--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · AuctionHouse
-- The auction house as a deck bottom sheet with Browse / Sell / My auctions
-- tabs. The default AH UI never appears at all: on 1.12 it is the LoD addon
-- Blizzard_AuctionUI, loaded from UIParent's AUCTION_HOUSE_SHOW handler —
-- Blizzard.lua unregistered that event on UIParent, so the addon is never
-- loaded and this module drives the AH purely through the C API (with an
-- ADDON_LOADED banish as belt-and-braces should another addon force-load it).
--
-- 1.12 AH API (verified against 1.12 Blizzard_AuctionUI):
--   * QueryAuctionItems(name, minLevel, maxLevel, invTypeIndex, classIndex,
--     subclassIndex, page, isUsable, qualityIndex) — page is 0-BASED, 50
--     results per page, and there is NO getAll on this client. Queries are
--     throttled server-side; CanSendAuctionQuery() (no argument on 1.12)
--     gates every send — Search/Prev/Next stay disabled until it answers 1
--     (polled on a coarse tick, no per-frame work).
--   * AUCTION_ITEM_LIST_UPDATE / AUCTION_OWNED_LIST_UPDATE re-render;
--     GetNumAuctionItems("list"|"owner") -> shown, total;
--     GetAuctionItemInfo(type, i) -> name, texture, count, quality, canUse,
--     level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner;
--     GetAuctionItemTimeLeft(type, i) -> 1..4 (AUCTION_TIME_LEFT1..4).
--   * PlaceAuctionBid(type, index, copper) both bids and buys out (amount ==
--     buyoutPrice); CancelAuction(ownerIndex). The owned list is pushed by
--     the server at AH open and after StartAuction/CancelAuction — there is
--     no explicit owner query on 1.12.
--   * SELLING (the 1.12 AuctionFrameAuctions.lua flow — no SetAuctionSellItem
--     exists): the sell slot is loaded by ClickAuctionSellItemButton() with
--     an item on the cursor (empty cursor lifts the slot's item back out);
--     GetAuctionSellItemInfo() -> name, texture, count, quality, canUse,
--     price describes it; CalculateAuctionDeposit(runTime) prices the
--     deposit; StartAuction(minBid, buyoutPrice, runTime) posts it, runTime
--     in MINUTES: 120 / 480 / 1440 (the default UI's radio values).
--   * NO stack-size controls in this API generation (3.x additions): the
--     loaded stack is auctioned as-is — split first via MoveMode's
--     long-press stepper, noted in the sell tab's hint text.
--------------------------------------------------------------------------------

local WM = WowMobile

local PAGE_SIZE = 50 -- server page size for QueryAuctionItems on 1.12
local ROW_H = 150
local GAP = 8
local CELL = 114
local COLS = 8

local sheet, confirm
local browseArea, sellArea, ownedArea
local browseScroller, sellScroller, ownedScroller
local tabBtns = {}
local curTab = "browse"

-- Browse state/widgets.
local searchBox, searchBtn, catBtn, qualityBtn, usableBtn
local prevBtn, nextBtn, pageText, resultText
local catOverlay, catScroller, catRows = nil, nil, {}
local browseRows = {}
local page = 0
local classIndex = nil   -- nil = all categories (1-based into GetAuctionItemClasses)
local qualityIndex = nil -- nil = any
local usableOnly = nil   -- nil | 1
local morePages = false

-- Sell state/widgets.
local sellSlot, sellName, bidStepper, buyoutStepper, depositText, createBtn
local durationBtns = {}
local duration = 1440 -- minutes: 120 / 480 / 1440
local sellCells = {}
local sellGridTop = 0

-- Owned list.
local ownedRows = {}

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

local function QualityColoredName(name, quality)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		return string.format("|cff%02x%02x%02x%s|r", q.r * 255, q.g * 255, q.b * 255, name)
	end
	return name
end

local function TimeLeftText(t)
	return getglobal("AUCTION_TIME_LEFT" .. (t or 0)) or "?"
end

--------------------------------------------------------------------------------
-- Browse: query + result rows
--------------------------------------------------------------------------------

-- Returns true when the query was actually sent, false when the throttle
-- refused it — callers that speculatively moved `page` roll it back on
-- false, keeping the page label / morePages math in sync with the list
-- actually on screen.
local function SendQuery()
	if not CanSendAuctionQuery() then
		WM.Print("Auction query throttled — try again in a moment.")
		return false
	end
	local text = searchBox:GetText()
	QueryAuctionItems(text or "", nil, nil, nil, classIndex, nil,
		page, usableOnly, qualityIndex)
	return true
end

local function AcquireBrowseRow(i)
	local row = browseRows[i]
	if row then return row end
	row = CreateFrame("Button", nil, browseScroller.child)
	row:SetHeight(WM.Px(ROW_H))
	WM.SkinFrame(row, WM.Colors.button)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(92))
	row.icon:SetHeight(WM.Px(92))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(12), 0)
	row.countText = WM.CreateText(row, 24, "OUTLINE")
	row.countText:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	row.line1 = WM.CreateText(row, 28)
	row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(118), -WM.Px(16))
	row.line1:SetJustifyH("LEFT")
	row.line1:SetWidth(WM.Px(420))
	WM.SingleLine(row.line1, 28)
	row.line2 = WM.CreateText(row, 22)
	row.line2:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(118), -WM.Px(64))
	row.line2:SetJustifyH("LEFT")
	row.line2:SetWidth(WM.Px(420))
	row.line2:SetTextColor(0.7, 0.7, 0.75)
	WM.SingleLine(row.line2, 22)
	row.line3 = WM.CreateText(row, 24)
	row.line3:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(118), WM.Px(14))
	row.line3:SetJustifyH("LEFT")
	row.line3:SetWidth(WM.Px(420))
	WM.SingleLine(row.line3, 24)
	-- BID / BUYOUT: near-row-height touch targets on the right end.
	row.buyoutBtn = WM.CreateTouchButton(row, 200, ROW_H - 16, "Buyout", 24)
	row.buyoutBtn:SetPoint("RIGHT", row, "RIGHT", -WM.Px(8), 0)
	-- Both money buttons revalidate at Confirm time: an
	-- AUCTION_ITEM_LIST_UPDATE arriving while the confirm overlay is up
	-- re-renders the list behind it, so the captured index may by then hold a
	-- DIFFERENT auction — PlaceAuctionBid would land real money on the wrong
	-- item. Re-fetch GetAuctionItemInfo at Confirm and abort unless the same
	-- item at the same price still sits at that index.
	row.buyoutBtn:SetScript("OnClick", function()
		local index, amount, label, rawName =
			this.index, this.amount, this.itemLabel, this.rawName
		confirm.Ask("Buy out " .. label .. " for " .. WM.FormatMoney(amount) ..
			"?", "Buy out", function()
			local name, _, _, _, _, _, _, _, buyoutPrice =
				GetAuctionItemInfo("list", index)
			if name ~= rawName or buyoutPrice ~= amount then
				WM.Print("Auction list changed — buyout cancelled. Check the row and retry.")
				return
			end
			PlaceAuctionBid("list", index, amount)
		end)
	end)
	row.bidBtn = WM.CreateTouchButton(row, 200, ROW_H - 16, "Bid", 24)
	row.bidBtn:SetPoint("RIGHT", row.buyoutBtn, "LEFT", -WM.Px(8), 0)
	row.bidBtn:SetScript("OnClick", function()
		local index, amount, label, rawName =
			this.index, this.amount, this.itemLabel, this.rawName
		confirm.Ask("Bid " .. WM.FormatMoney(amount) .. " on " .. label ..
			"?", "Place bid", function()
			local name, _, _, _, _, _, minBid, minIncrement, _, bidAmount =
				GetAuctionItemInfo("list", index)
			-- Recompute the required bid the same way RenderBrowse did; a
			-- mismatch also catches someone outbidding this auction while
			-- the confirm was up (the captured amount would be stale).
			local hasBid = bidAmount ~= nil and bidAmount > 0
			local nextBid = hasBid and (bidAmount + (minIncrement or 0)) or (minBid or 0)
			if nextBid < 1 then nextBid = 1 end
			if name ~= rawName or nextBid ~= amount then
				WM.Print("Auction list changed — bid cancelled. Check the row and retry.")
				return
			end
			PlaceAuctionBid("list", index, amount)
		end)
	end)
	WM.AttachTooltip(row, function(tt, self)
		tt:SetAuctionItem("list", self.index)
	end)
	browseRows[i] = row
	return row
end

local function RenderBrowse()
	if not IsOpen() or curTab ~= "browse" then return end
	local shown, total = GetNumAuctionItems("list")
	local playerName = UnitName("player")
	for i = 1, shown do
		local name, texture, count, quality, canUse, _, minBid,
			minIncrement, buyoutPrice, bidAmount, _, owner =
			GetAuctionItemInfo("list", i)
		local row = AcquireBrowseRow(i)
		row.index = i
		row.icon:SetTexture(texture or WM.TEX_QUESTION)
		row.countText:SetText(count and count > 1 and count or "")
		local label = QualityColoredName(name or "?", quality)
		row.itemLabel = label
		row.line1:SetText(label ..
			((canUse and canUse ~= 0) and "" or " |cffcc4444(can't use)|r"))
		row.line2:SetText((owner or "?") .. " · " ..
			TimeLeftText(GetAuctionItemTimeLeft("list", i)))
		local hasBid = bidAmount and bidAmount > 0
		row.line3:SetText((hasBid and "Bid " or "Starts ") ..
			WM.FormatMoney(hasBid and bidAmount or minBid))
		local nextBid = hasBid and (bidAmount + (minIncrement or 0)) or (minBid or 0)
		if nextBid < 1 then nextBid = 1 end
		local mine = owner ~= nil and owner == playerName
		row.bidBtn.index, row.bidBtn.amount = i, nextBid
		row.bidBtn.itemLabel = label
		row.bidBtn.rawName = name -- for the Confirm-time revalidation
		row.bidBtn.label:SetText("Bid\n" .. WM.FormatMoney(nextBid))
		WM.SetButtonEnabled(row.bidBtn, not mine and GetMoney() >= nextBid)
		row.buyoutBtn.index = i
		row.buyoutBtn.itemLabel = label
		row.buyoutBtn.rawName = name -- for the Confirm-time revalidation
		if buyoutPrice and buyoutPrice > 0 then
			row.buyoutBtn.amount = buyoutPrice
			row.buyoutBtn.label:SetText("Buyout\n" .. WM.FormatMoney(buyoutPrice))
			WM.SetButtonEnabled(row.buyoutBtn, not mine and GetMoney() >= buyoutPrice)
		else
			row.buyoutBtn.amount = nil
			row.buyoutBtn.label:SetText("No\nbuyout")
			WM.SetButtonEnabled(row.buyoutBtn, false)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", browseScroller.child, "TOPLEFT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetPoint("TOPRIGHT", browseScroller.child, "TOPRIGHT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:Show()
	end
	for i = shown + 1, table.getn(browseRows) do
		browseRows[i]:Hide()
	end
	browseScroller.SetContentHeight(WM.Px(shown * (ROW_H + GAP)))
	morePages = (page + 1) * PAGE_SIZE < (total or 0)
	local pages = math.ceil((total or 0) / PAGE_SIZE)
	if pages < 1 then pages = 1 end
	pageText:SetText("Page " .. (page + 1) .. " / " .. pages)
	resultText:SetText((total or 0) .. " results")
end

--------------------------------------------------------------------------------
-- Browse: filters
--------------------------------------------------------------------------------

local function UpdateFilterLabels()
	local cats = { GetAuctionItemClasses() }
	catBtn.label:SetText(classIndex and cats[classIndex] or "All categories")
	if qualityIndex then
		local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[qualityIndex]
		local qname = getglobal("ITEM_QUALITY" .. qualityIndex .. "_DESC")
			or ("Quality " .. qualityIndex)
		if q then
			qname = string.format("|cff%02x%02x%02x%s|r",
				q.r * 255, q.g * 255, q.b * 255, qname)
		end
		qualityBtn.label:SetText("Min: " .. qname)
	else
		qualityBtn.label:SetText("Quality: any")
	end
	usableBtn.label:SetText(usableOnly and "Usable: yes" or "Usable: all")
end

local function Requery()
	local oldPage = page
	page = 0
	UpdateFilterLabels()
	if not SendQuery() then page = oldPage end
end

local function AcquireCatRow(i)
	local row = catRows[i]
	if row then return row end
	row = WM.CreateTouchButton(catScroller.child, 100, 100, nil, 30)
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row, "LEFT", WM.Px(24), 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetWidth(WM.Px(700))
	row:SetScript("OnClick", function()
		classIndex = this.classIndex
		catOverlay:Hide()
		Requery()
	end)
	catRows[i] = row
	return row
end

local function OpenCategoryPicker()
	local cats = { GetAuctionItemClasses() }
	local used = 0
	local function Place(row)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", catScroller.child, "TOPLEFT",
			0, -WM.Px((used - 1) * 108))
		row:SetPoint("TOPRIGHT", catScroller.child, "TOPRIGHT",
			0, -WM.Px((used - 1) * 108))
		row:SetHeight(WM.Px(100))
		row:Show()
	end
	used = used + 1
	local allRow = AcquireCatRow(used)
	allRow.classIndex = nil
	allRow.label:SetText("All categories")
	Place(allRow)
	for i = 1, table.getn(cats) do
		used = used + 1
		local row = AcquireCatRow(used)
		row.classIndex = i
		row.label:SetText(cats[i])
		Place(row)
	end
	for i = used + 1, table.getn(catRows) do
		catRows[i]:Hide()
	end
	catScroller.SetContentHeight(WM.Px(used * 108))
	catScroller.ScrollToTop()
	catOverlay:Show()
end

--------------------------------------------------------------------------------
-- Sell tab
--------------------------------------------------------------------------------

local function RefreshSell()
	if not sellArea then return end
	local name, texture, count, quality = GetAuctionSellItemInfo()
	if name then
		sellSlot.icon:SetTexture(texture or WM.TEX_QUESTION)
		sellSlot.icon:SetVertexColor(1, 1, 1)
		sellName:SetText(QualityColoredName(name, quality) ..
			(count and count > 1 and (" x" .. count) or ""))
		local ok, deposit = pcall(CalculateAuctionDeposit, duration)
		depositText:SetText("Deposit: " .. WM.FormatMoney(ok and deposit or 0))
	else
		sellSlot.icon:SetTexture(WM.TEX_WHITE)
		sellSlot.icon:SetVertexColor(0.12, 0.12, 0.14)
		sellName:SetText("|cff9999a3No item loaded|r")
		depositText:SetText("Deposit: —")
	end
	for d, b in pairs(durationBtns) do
		if d == duration then
			WM.TintBorder(b, WM.Colors.accent)
		else
			WM.TintBorder(b, WM.Colors.border)
		end
	end
	WM.SetButtonEnabled(createBtn, name ~= nil and bidStepper.GetCopper() > 0)
end

local function CreateAuction()
	local name = GetAuctionSellItemInfo()
	if not name then return end
	local bid = bidStepper.GetCopper()
	local buyout = buyoutStepper.GetCopper()
	if bid <= 0 then
		WM.Print("Auction: set a starting bid first.")
		return
	end
	if buyout > 0 and buyout < bid then
		WM.Print("Auction: buyout can't be below the starting bid.")
		return
	end
	StartAuction(bid, buyout, duration)
end

local function LoadSellFromBag(bag, slot)
	if GetAuctionSellItemInfo() then
		ClickAuctionSellItemButton() -- lift the current item out...
		ClearCursor()                -- ...and home to its bag slot
	end
	PickupContainerItem(bag, slot)
	if CursorHasItem() then
		ClickAuctionSellItemButton()
		WM.MoveMode.NoteSlotDrop()
	end
	RefreshSell()
end

local function UpdateSellCell(cell)
	local icon, count, locked = GetContainerItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
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

local function CreateSellCell(bag, slot)
	local cell = CreateFrame("Button", nil, sellScroller.child)
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
			LoadSellFromBag(this.bag, this.slot)
		end
	end)
	WM.MoveMode.MakeTarget(cell, "bag")
	WM.AttachTooltip(cell, function(tt, self)
		tt:SetBagItem(self.bag, self.slot)
	end)
	return cell
end

local function RenderSellBags()
	if not IsOpen() or curTab ~= "sell" then return end
	local index = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			index = index + 1
			local key = bag .. ":" .. slot
			local cell = sellCells[key]
			if not cell then
				cell = CreateSellCell(bag, slot)
				sellCells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", sellScroller.child, "TOPLEFT",
				WM.Px(col * (CELL + 6)), -WM.Px(sellGridTop + row * (CELL + 6)))
			UpdateSellCell(cell)
			cell:Show()
		end
	end
	for _, cell in pairs(sellCells) do
		if cell.slot > GetContainerNumSlots(cell.bag) then
			cell:Hide()
		end
	end
	sellScroller.SetContentHeight(
		WM.Px(sellGridTop + math.ceil(index / COLS) * (CELL + 6) + 8))
end

--------------------------------------------------------------------------------
-- My auctions
--------------------------------------------------------------------------------

local function AcquireOwnedRow(i)
	local row = ownedRows[i]
	if row then return row end
	row = CreateFrame("Button", nil, ownedScroller.child)
	row:SetHeight(WM.Px(ROW_H))
	WM.SkinFrame(row, WM.Colors.button)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(92))
	row.icon:SetHeight(WM.Px(92))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(12), 0)
	row.countText = WM.CreateText(row, 24, "OUTLINE")
	row.countText:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	row.line1 = WM.CreateText(row, 28)
	row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(118), -WM.Px(16))
	row.line1:SetJustifyH("LEFT")
	row.line1:SetWidth(WM.Px(560))
	WM.SingleLine(row.line1, 28)
	row.line2 = WM.CreateText(row, 24)
	row.line2:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(118), -WM.Px(66))
	row.line2:SetJustifyH("LEFT")
	row.line2:SetWidth(WM.Px(560))
	row.line2:SetTextColor(0.7, 0.7, 0.75)
	WM.SingleLine(row.line2, 24)
	row.line3 = WM.CreateText(row, 24)
	row.line3:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(118), WM.Px(14))
	row.line3:SetJustifyH("LEFT")
	row.line3:SetWidth(WM.Px(560))
	WM.SingleLine(row.line3, 24)
	row.cancelBtn = WM.CreateTouchButton(row, 220, ROW_H - 16, "Cancel", 28)
	row.cancelBtn:SetPoint("RIGHT", row, "RIGHT", -WM.Px(8), 0)
	row.cancelBtn:SetScript("OnClick", function()
		local index, label, rawName = this.index, this.itemLabel, this.rawName
		local rawMinBid, rawBuyout = this.rawMinBid, this.rawBuyout
		confirm.Ask("Cancel the auction for " .. label ..
			"? If it already has a bid, the deposit is forfeit.",
			"Cancel auction", function()
			-- Same Confirm-time revalidation as bid/buyout: a sale/expiry
			-- while the confirm was up shifts owned-list indices and
			-- CancelAuction would pull the wrong auction. Prices are checked
			-- too — several auctions of the same item share a name, and a
			-- shift could land the index on a same-name different-price one.
			local name, _, _, _, _, _, minBid, _, buyout =
				GetAuctionItemInfo("owner", index)
			if name ~= rawName or minBid ~= rawMinBid or buyout ~= rawBuyout then
				WM.Print("Your auctions changed — cancel aborted. Check the row and retry.")
				return
			end
			CancelAuction(index)
		end)
	end)
	WM.AttachTooltip(row, function(tt, self)
		tt:SetAuctionItem("owner", self.index)
	end)
	ownedRows[i] = row
	return row
end

local function RenderOwned()
	if not IsOpen() or curTab ~= "owned" then return end
	local shown = GetNumAuctionItems("owner")
	for i = 1, shown do
		local name, texture, count, quality, _, _, minBid, _, buyoutPrice,
			bidAmount = GetAuctionItemInfo("owner", i)
		local row = AcquireOwnedRow(i)
		row.index = i
		row.icon:SetTexture(texture or WM.TEX_QUESTION)
		row.countText:SetText(count and count > 1 and count or "")
		local label = QualityColoredName(name or "?", quality)
		row.line1:SetText(label)
		row.line2:SetText(TimeLeftText(GetAuctionItemTimeLeft("owner", i)))
		local hasBid = bidAmount and bidAmount > 0
		row.line3:SetText((hasBid
				and ("|cff33cc33Bid " .. WM.FormatMoney(bidAmount) .. "|r")
				or ("No bids — starts " .. WM.FormatMoney(minBid or 0))) ..
			((buyoutPrice and buyoutPrice > 0)
				and (" · buyout " .. WM.FormatMoney(buyoutPrice)) or ""))
		row.cancelBtn.index = i
		row.cancelBtn.itemLabel = label
		-- For the Confirm-time revalidation: name alone can't distinguish
		-- several auctions of the same item, so prices are compared too.
		row.cancelBtn.rawName = name
		row.cancelBtn.rawMinBid = minBid
		row.cancelBtn.rawBuyout = buyoutPrice
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", ownedScroller.child, "TOPLEFT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetPoint("TOPRIGHT", ownedScroller.child, "TOPRIGHT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:Show()
	end
	for i = shown + 1, table.getn(ownedRows) do
		ownedRows[i]:Hide()
	end
	ownedScroller.SetContentHeight(WM.Px(shown * (ROW_H + GAP)))
end

--------------------------------------------------------------------------------
-- Tabs / lifecycle
--------------------------------------------------------------------------------

local function SetTab(t)
	curTab = t
	searchBox:ClearFocus()
	WM.SetShown(browseArea, t == "browse")
	WM.SetShown(sellArea, t == "sell")
	WM.SetShown(ownedArea, t == "owned")
	for key, b in pairs(tabBtns) do
		WM.TintBorder(b, key == t and WM.Colors.accent or WM.Colors.border)
	end
	if t == "browse" then
		RenderBrowse()
	elseif t == "sell" then
		RefreshSell()
		RenderSellBags()
	else
		RenderOwned()
	end
end

local function Dismiss()
	CloseAuctionHouse()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileAuctionSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	local titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Auction House")

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	-- Tab row in the title bar band, right of the title.
	local tabDefs = {
		{ key = "browse", label = "Browse" },
		{ key = "sell", label = "Sell" },
		{ key = "owned", label = "Mine" },
	}
	local prev
	for i = table.getn(tabDefs), 1, -1 do
		local def = tabDefs[i]
		local b = WM.CreateTouchButton(sheet, 170, 96, def.label, 28)
		if prev then
			b:SetPoint("RIGHT", prev, "LEFT", -WM.Px(6), 0)
		else
			b:SetPoint("TOPRIGHT", close, "TOPLEFT", -WM.Px(8), 0)
		end
		b:SetScript("OnClick", function() SetTab(def.key) end)
		tabBtns[def.key] = b
		prev = b
	end

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))

	confirm = WM.CreateConfirmOverlay(sheet)

	--------------------------------------------------------------------------
	-- Browse area
	--------------------------------------------------------------------------
	browseArea = CreateFrame("Frame", nil, content)
	browseArea:SetAllPoints(content)

	searchBox = WM.CreateEditBox(browseArea, 540, 90, 40)
	searchBox:SetPoint("TOPLEFT", browseArea, "TOPLEFT", 0, 0)
	searchBox:SetScript("OnEnterPressed", function()
		this:ClearFocus()
		local oldPage = page
		page = 0
		if not SendQuery() then page = oldPage end
	end)
	searchBtn = WM.CreateTouchButton(browseArea, 200, 90, "Search", 28)
	searchBtn:SetPoint("LEFT", searchBox, "RIGHT", WM.Px(8), 0)
	searchBtn:SetScript("OnClick", function()
		searchBox:ClearFocus()
		local oldPage = page
		page = 0
		if not SendQuery() then page = oldPage end
	end)
	catBtn = WM.CreateTouchButton(browseArea, 300, 90, "All categories", 24)
	catBtn:SetPoint("LEFT", searchBtn, "RIGHT", WM.Px(8), 0)
	catBtn:SetScript("OnClick", OpenCategoryPicker)

	qualityBtn = WM.CreateTouchButton(browseArea, 340, 90, "Quality: any", 24)
	qualityBtn:SetPoint("TOPLEFT", browseArea, "TOPLEFT", 0, -WM.Px(98))
	qualityBtn:SetScript("OnClick", function()
		-- Cycle any -> Good(2) -> Rare(3) -> Epic(4) -> any; passed straight
		-- through as QueryAuctionItems' qualityIndex (minimum quality).
		if qualityIndex == nil then
			qualityIndex = 2
		elseif qualityIndex >= 4 then
			qualityIndex = nil
		else
			qualityIndex = qualityIndex + 1
		end
		Requery()
	end)
	usableBtn = WM.CreateTouchButton(browseArea, 340, 90, "Usable: all", 24)
	usableBtn:SetPoint("LEFT", qualityBtn, "RIGHT", WM.Px(8), 0)
	usableBtn:SetScript("OnClick", function()
		usableOnly = usableOnly and nil or 1
		Requery()
	end)
	resultText = WM.CreateText(browseArea, 26)
	resultText:SetPoint("LEFT", usableBtn, "RIGHT", WM.Px(20), 0)
	resultText:SetTextColor(0.7, 0.7, 0.75)

	local results = CreateFrame("Frame", nil, browseArea)
	results:SetPoint("TOPLEFT", browseArea, "TOPLEFT", 0, -WM.Px(200))
	results:SetPoint("BOTTOMRIGHT", browseArea, "BOTTOMRIGHT", 0, WM.Px(104))
	browseScroller = WM.Deck.CreateScroller(results)

	prevBtn = WM.CreateTouchButton(browseArea, 240, 96, "< Prev", 28)
	prevBtn:SetPoint("BOTTOMLEFT", browseArea, "BOTTOMLEFT", 0, 0)
	prevBtn:SetScript("OnClick", function()
		-- The 0.3 s throttle-poll enable leaves a window where the tap gets
		-- refused; roll the page counter back so it never desyncs from the
		-- displayed results.
		if page > 0 then
			page = page - 1
			if not SendQuery() then page = page + 1 end
		end
	end)
	nextBtn = WM.CreateTouchButton(browseArea, 240, 96, "Next >", 28)
	nextBtn:SetPoint("BOTTOMRIGHT", browseArea, "BOTTOMRIGHT", -WM.Px(98), 0)
	nextBtn:SetScript("OnClick", function()
		if morePages then
			page = page + 1
			if not SendQuery() then page = page - 1 end
		end
	end)
	pageText = WM.CreateText(browseArea, 28)
	pageText:SetPoint("BOTTOM", browseArea, "BOTTOM", -WM.Px(50), WM.Px(34))
	pageText:SetJustifyH("CENTER")

	-- Category picker overlay (FULLSCREEN_DIALOG — the shared technique).
	catOverlay = CreateFrame("Frame", "WowMobileAuctionCategories", sheet)
	catOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
	catOverlay:SetAllPoints(sheet)
	catOverlay:EnableMouse(true)
	WM.SkinFrame(catOverlay, WM.Colors.panel, WM.Colors.accent)
	catOverlay:Hide()
	local catTitle = WM.CreateText(catOverlay, 34)
	catTitle:SetPoint("TOPLEFT", catOverlay, "TOPLEFT", WM.Px(24), -WM.Px(30))
	catTitle:SetText("Category")
	local catClose = WM.CreateTouchButton(catOverlay, 180, 96, "Cancel", 30)
	catClose:SetPoint("TOPRIGHT", catOverlay, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	catClose:SetScript("OnClick", function() catOverlay:Hide() end)
	local catContent = CreateFrame("Frame", nil, catOverlay)
	catContent:SetPoint("TOPLEFT", catOverlay, "TOPLEFT", WM.Px(8), -WM.Px(104))
	catContent:SetPoint("BOTTOMRIGHT", catOverlay, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	catScroller = WM.Deck.CreateScroller(catContent)

	--------------------------------------------------------------------------
	-- Sell area (everything in its scroller so the bag grid stays reachable)
	--------------------------------------------------------------------------
	sellArea = CreateFrame("Frame", nil, content)
	sellArea:SetAllPoints(content)
	sellArea:Hide()
	sellScroller = WM.Deck.CreateScroller(sellArea)
	local sc = sellScroller.child

	sellSlot = CreateFrame("Button", nil, sc)
	sellSlot:SetWidth(WM.Px(130))
	sellSlot:SetHeight(WM.Px(130))
	sellSlot:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(4))
	WM.SkinFrame(sellSlot, { 0.07, 0.07, 0.09, 1 })
	local shl = sellSlot:CreateTexture(nil, "HIGHLIGHT")
	shl:SetAllPoints(sellSlot)
	shl:SetTexture(1, 1, 1, 0.10)
	sellSlot.icon = sellSlot:CreateTexture(nil, "ARTWORK")
	sellSlot.icon:SetPoint("TOPLEFT", sellSlot, "TOPLEFT", WM.Px(6), -WM.Px(6))
	sellSlot.icon:SetPoint("BOTTOMRIGHT", sellSlot, "BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
	sellSlot:SetScript("OnClick", function()
		if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
			ClickAuctionSellItemButton()
			WM.MoveMode.NoteSlotDrop()
		elseif GetAuctionSellItemInfo() then
			ClickAuctionSellItemButton() -- lift it out...
			ClearCursor()                -- ...and home to its bag slot
		end
		RefreshSell()
	end)
	WM.MoveMode.MakeTarget(sellSlot, "bag")
	WM.AttachTooltip(sellSlot, function(tt)
		tt:SetText("Auction item — tap a bag item below to load it")
	end)

	sellName = WM.CreateText(sc, 30)
	sellName:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(30))
	sellName:SetJustifyH("LEFT")
	sellName:SetWidth(WM.Px(680))
	WM.SingleLine(sellName, 30)
	local sellHint = WM.CreateText(sc, 22)
	sellHint:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(84))
	sellHint:SetJustifyH("LEFT")
	sellHint:SetWidth(WM.Px(680))
	sellHint:SetTextColor(0.6, 0.6, 0.65)
	sellHint:SetText("The loaded stack sells as-is (no stack controls on " ..
		"1.12) — long-press below to split first.")

	local bidLabel = WM.CreateText(sc, 28)
	bidLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(160))
	bidLabel:SetText("Starting bid")
	bidStepper = WM.CreateMoneyStepper(sc, { onChange = RefreshSell })
	bidStepper:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -WM.Px(200))

	local buyoutLabel = WM.CreateText(sc, 28)
	buyoutLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(316))
	buyoutLabel:SetText("Buyout (zero = no buyout)")
	buyoutStepper = WM.CreateMoneyStepper(sc)
	buyoutStepper:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -WM.Px(356))

	local durDefs = {
		{ minutes = 120, label = "2 hours" },
		{ minutes = 480, label = "8 hours" },
		{ minutes = 1440, label = "24 hours" },
	}
	for i = 1, 3 do
		local def = durDefs[i]
		local b = WM.CreateTouchButton(sc, 306, 96, def.label, 28)
		b:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px((i - 1) * 316), -WM.Px(472))
		b:SetScript("OnClick", function()
			duration = def.minutes
			RefreshSell()
		end)
		durationBtns[def.minutes] = b
	end

	depositText = WM.CreateText(sc, 28)
	depositText:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(606))
	createBtn = WM.CreateTouchButton(sc, 440, 110, "Create auction", 32)
	createBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -WM.Px(584))
	createBtn:SetScript("OnClick", CreateAuction)

	local sellBagsLabel = WM.CreateText(sc, 30)
	sellBagsLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(722))
	sellBagsLabel:SetTextColor(1, 0.82, 0)
	sellBagsLabel:SetText("Your bags — tap an item to load it")
	sellGridTop = 774

	--------------------------------------------------------------------------
	-- Owned area
	--------------------------------------------------------------------------
	ownedArea = CreateFrame("Frame", nil, content)
	ownedArea:SetAllPoints(content)
	ownedArea:Hide()
	ownedScroller = WM.Deck.CreateScroller(ownedArea)

	WM.Deck.RegisterExclusive("auction", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("AUCTION_HOUSE_SHOW", function()
		WM.Deck.YieldTo("auction")
		sheet:Show()
		page = 0
		UpdateFilterLabels()
		SetTab("browse")
		browseScroller.ScrollToTop()
		SendQuery() -- initial unfiltered page 0 fill (throttle permitting)
	end)
	WM.On("AUCTION_HOUSE_CLOSED", function()
		sheet:Hide()
	end)
	-- Deliberately does NOT hide the confirm overlay: on 1.12 this event
	-- re-fires for the SAME page as owner names backfill, so hiding here
	-- would flicker away legitimate confirms. Stale confirms are handled by
	-- the Confirm-time revalidation in the bid/buyout handlers instead.
	WM.On("AUCTION_ITEM_LIST_UPDATE", function()
		if IsOpen() then RenderBrowse() end
	end)
	WM.On("AUCTION_OWNED_LIST_UPDATE", function()
		if IsOpen() then RenderOwned() end
	end)
	-- Sell-slot contents changed (loaded, lifted out, consumed by
	-- StartAuction).
	WM.On("NEW_AUCTION_UPDATE", function()
		if IsOpen() then RefreshSell() end
	end)
	WM.On("BAG_UPDATE", function()
		if IsOpen() and curTab == "sell" then RenderSellBags() end
	end)
	WM.On("ITEM_LOCK_CHANGED", function()
		if IsOpen() and curTab == "sell" then RenderSellBags() end
	end)
	WM.On("PLAYER_MONEY", function()
		if IsOpen() and curTab == "browse" then RenderBrowse() end
	end)

	-- Query-throttle poll: one CanSendAuctionQuery C-call per 0.3 s while the
	-- browse tab is up, driving the Search/Prev/Next enables. No allocations.
	WM.Ticker(0.3, function()
		if not IsOpen() or curTab ~= "browse" then return end
		local ready = CanSendAuctionQuery()
		WM.SetButtonEnabled(searchBtn, ready and true or false)
		WM.SetButtonEnabled(prevBtn, ready ~= nil and page > 0)
		WM.SetButtonEnabled(nextBtn, ready ~= nil and morePages)
	end)
end)
