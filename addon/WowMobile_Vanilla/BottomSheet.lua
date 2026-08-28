--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · BottomSheet
-- Full-width NPC interaction sheet rendered in the control deck, replacing
-- GossipFrame / QuestFrame / MerchantFrame / ClassTrainerFrame (banished in
-- Blizzard.lua). Drives the flow purely through the official 1.12 APIs:
--   GOSSIP_SHOW      -> gossip text + options + available/active quests
--   QUEST_GREETING   -> greeting text + available/active quests
--   QUEST_DETAIL     -> quest text + objectives, Accept / Decline
--   QUEST_PROGRESS   -> progress text + required items, Continue / Cancel
--   QUEST_COMPLETE   -> reward text, reward-choice grid, fixed rewards,
--                       money, Complete
--   QUEST_ACCEPT_CONFIRM -> party escort-start confirmation
--   MERCHANT_SHOW    -> Buy / Sell / Buyback tabs, repair-all button
--   TRAINER_SHOW     -> trainer services, tap to learn
-- Every option/quest/action is a ~100px-tall full-width touch button.
--
-- 1.12 gossip return shapes (flat multi-returns, selection by 1-based entry
-- index):
--   GetGossipOptions()          -> text1, gossipType1, ...   (stride 2)
--   GetGossipAvailableQuests()  -> title1, title2, ...       (stride 1)
--   GetGossipActiveQuests()     -> title1, title2, ...       (stride 1)
-- (levels/trivial flags in these returns are later-client additions.)
--------------------------------------------------------------------------------

local WM = WowMobile

local BUTTON_H = 100
local CELL_H = 116
local GAP = 10

local RETRIEVING = "Retrieving item information"

local ICON_GOSSIP    = "Interface\\GossipFrame\\GossipGossipIcon"
local ICON_AVAILABLE = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_ACTIVE    = "Interface\\GossipFrame\\ActiveQuestIcon"

local sheet, scroller, titleText
local mode -- "gossip" | "greeting" | "detail" | "progress" | "complete" | "acceptconfirm" | "merchant" | "trainer"
local chosenReward     -- selected choice index on the QUEST_COMPLETE view
local merchantTab      -- "buy" | "sell" | "buyback"
local lastView         -- view key of the previous render; see FinishLayout

-- Widget pools, reset on every rebuild.
local pools = { text = {}, button = {}, cell = {} }
local used = { text = 0, button = 0, cell = 0 }
local cursorY -- running layout offset into scroller.child (design px)

local function ResetContent()
	used.text, used.button, used.cell = 0, 0, 0
	for _, pool in pairs(pools) do
		for i = 1, table.getn(pool) do pool[i]:Hide() end
	end
	cursorY = 0
end

local function ContentWidthPx()
	-- Scroller content width converted back to design px for layout math.
	return scroller.ContentWidth() / WM.Px(1)
end

local function QualityColoredName(name, quality)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		return string.format("|cff%02x%02x%02x%s|r", q.r * 255, q.g * 255, q.b * 255, name)
	end
	return name
end

--------------------------------------------------------------------------------
-- Content builders (stack top-down into scroller.child)
--------------------------------------------------------------------------------

local function NextText()
	used.text = used.text + 1
	local fs = pools.text[used.text]
	if not fs then
		fs = WM.CreateText(scroller.child, 30)
		fs:SetJustifyH("LEFT")
		pools.text[used.text] = fs
	end
	return fs
end

local function AddText(text, sizePx, r, g, b)
	local fs = NextText()
	WM.SetFont(fs, sizePx or 30)
	fs:SetTextColor(r or 0.92, g or 0.92, b or 0.92)
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px(4), -WM.Px(cursorY))
	fs:SetWidth(scroller.ContentWidth() - WM.Px(8))
	fs:SetText(text)
	fs:Show()
	-- 1.12 FontStrings have no GetStringHeight; with width set and no fixed
	-- height, GetHeight() returns the wrapped text height — the vanilla idiom.
	cursorY = cursorY + fs:GetHeight() / WM.Px(1) + GAP
end

-- Pooled button acquire: resets every per-use property a previous render may
-- have customized (tab borders, tooltips, disabled tint).
local function NextButton()
	used.button = used.button + 1
	local b = pools.button[used.button]
	if not b then
		b = WM.CreateTouchButton(scroller.child, 100, BUTTON_H, nil, 32)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetWidth(WM.Px(56))
		b.icon:SetHeight(WM.Px(56))
		b.icon:SetPoint("LEFT", b, "LEFT", WM.Px(18), 0)
		pools.button[used.button] = b
	end
	WM.TintBorder(b, WM.Colors.border)
	WM.SetButtonEnabled(b, true)
	b:SetScript("OnEnter", nil)
	b:SetScript("OnLeave", nil)
	return b
end

local function AddButton(label, icon, onTap, tooltip)
	local b = NextButton()
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", 0, -WM.Px(cursorY))
	b:SetPoint("TOPRIGHT", scroller.child, "TOPRIGHT", 0, -WM.Px(cursorY))
	b:SetHeight(WM.Px(BUTTON_H))
	b.label:ClearAllPoints()
	b.label:SetPoint("LEFT", b, "LEFT", WM.Px(icon and 92 or 24), 0)
	b.label:SetJustifyH("LEFT")
	b.label:SetWidth(scroller.ContentWidth() - WM.Px(icon and 110 or 48))
	b.label:SetText(label)
	if icon then
		b.icon:SetTexture(icon)
		b.icon:Show()
	else
		b.icon:Hide()
	end
	b:SetScript("OnClick", onTap)
	if tooltip then
		WM.AttachTooltip(b, function(tt) tooltip(tt) end)
	end
	b:Show()
	cursorY = cursorY + BUTTON_H + GAP
	return b
end

-- N equal-width buttons on one row (the merchant's Buy/Sell/Buyback tabs).
-- spec: { label, onTap, selected } — selected paints the accent border.
local function AddButtonRow(specs)
	local n = table.getn(specs)
	local w = (ContentWidthPx() - GAP * (n - 1)) / n
	for i = 1, n do
		local spec = specs[i]
		local b = NextButton()
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px((i - 1) * (w + GAP)), -WM.Px(cursorY))
		b:SetWidth(WM.Px(w))
		b:SetHeight(WM.Px(BUTTON_H))
		b.icon:Hide()
		b.label:ClearAllPoints()
		b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
		b.label:SetJustifyH("CENTER")
		b.label:SetWidth(WM.Px(w - 24))
		b.label:SetText(spec.label)
		if spec.selected then
			WM.TintBorder(b, WM.Colors.accent)
		end
		b:SetScript("OnClick", spec.onTap)
		b:Show()
	end
	cursorY = cursorY + BUTTON_H + GAP
end

-- Item cells in a 2-column grid: quest rewards/choices, merchant stock,
-- sellable bag items, buyback stock. Item shape:
--   { icon, count, label (pre-colored), selected, disabled, tooltip(tt), ... }
-- `onTap` nil (or item.disabled) = tooltip-only cell.
local function AddItemGrid(items, onTap)
	local colW = (ContentWidthPx() - GAP) / 2
	local rows = math.ceil(table.getn(items) / 2)
	for i = 1, table.getn(items) do
		local item = items[i]
		used.cell = used.cell + 1
		local cell = pools.cell[used.cell]
		if not cell then
			cell = WM.CreateTouchButton(scroller.child, 100, CELL_H, nil, 28)
			cell.icon = cell:CreateTexture(nil, "ARTWORK")
			cell.icon:SetWidth(WM.Px(80))
			cell.icon:SetHeight(WM.Px(80))
			cell.icon:SetPoint("LEFT", cell, "LEFT", WM.Px(14), 0)
			cell.countText = WM.CreateText(cell, 24, "OUTLINE")
			cell.countText:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
			cell.label:ClearAllPoints()
			cell.label:SetPoint("LEFT", cell, "LEFT", WM.Px(106), 0)
			cell.label:SetJustifyH("LEFT")
			pools.cell[used.cell] = cell
		end
		local col = math.mod(i - 1, 2)
		local row = math.floor((i - 1) / 2)
		cell:ClearAllPoints()
		cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
			WM.Px(col * (colW + GAP)), -WM.Px(cursorY + row * (CELL_H + GAP)))
		cell:SetWidth(WM.Px(colW))
		cell:SetHeight(WM.Px(CELL_H))
		cell.icon:SetTexture(item.icon or WM.TEX_QUESTION)
		cell.countText:SetText(item.count and item.count > 1 and item.count or "")
		cell.label:SetWidth(WM.Px(colW - 120))
		cell.label:SetText(item.label)
		-- Selected-choice highlight on the border.
		if item.selected then
			WM.TintBorder(cell, WM.Colors.accent)
		else
			WM.TintBorder(cell, WM.Colors.border)
		end
		if onTap and not item.disabled then
			local captured = item
			local index = i
			cell:SetScript("OnClick", function() onTap(captured, index) end)
		else
			cell:SetScript("OnClick", nil)
		end
		if item.tooltip then
			local captured = item
			WM.AttachTooltip(cell, function(tt) captured.tooltip(tt) end)
		else
			cell:SetScript("OnEnter", nil)
			cell:SetScript("OnLeave", nil)
		end
		cell:Show()
	end
	cursorY = cursorY + rows * (CELL_H + GAP)
end

-- `viewKey` names the rendered view (e.g. "merchant:sell"). When a rebuild
-- lands on the same key as the previous render (money tick, a sale, a reward
-- pick), the user's scroll offset is preserved — SetContentHeight has already
-- clamped it to the new range — so selling from the bottom of a long bag list
-- never snaps back to the top. nil (or a changed key) starts at the top.
-- lastView is cleared whenever the sheet hides, so a fresh NPC visit that
-- happens to open on the same view still starts at the top.
local function FinishLayout(viewKey)
	scroller.SetContentHeight(WM.Px(cursorY + 8))
	if viewKey == nil or viewKey ~= lastView then
		scroller.ScrollToTop()
	end
	lastView = viewKey
end

--------------------------------------------------------------------------------
-- Quest views
--------------------------------------------------------------------------------

local function OpenSheet(npcName)
	WM.Deck.YieldTo("sheet") -- panels and world map step aside
	titleText:SetText(npcName or UNKNOWNOBJECT or "Unknown")
	sheet:Show()
	ResetContent()
end

local function CollectQuestItems(itemType, count)
	local items = {}
	for i = 1, count do
		-- 1.12: GetQuestItemInfo(type, i) -> name, texture, numItems, quality.
		local name, texture, numItems, quality = GetQuestItemInfo(itemType, i)
		local index = i
		items[i] = {
			-- Uncached items resolve via the QUEST_ITEM_UPDATE re-render below.
			label = QualityColoredName(name or RETRIEVING, name and quality or nil),
			icon = texture,
			count = numItems,
			tooltip = function(tt) tt:SetQuestItem(itemType, index) end,
		}
	end
	return items
end

local function ShowGossip()
	mode = "gossip"
	OpenSheet(UnitName("npc"))
	AddText(GetGossipText() or "")

	-- 1.12 stride-1 title lists; selection is by 1-based position.
	local available = { GetGossipAvailableQuests() }
	for i = 1, table.getn(available) do
		local index = i
		AddButton(available[i] or "", ICON_AVAILABLE,
			function() SelectGossipAvailableQuest(index) end)
	end
	local active = { GetGossipActiveQuests() }
	for i = 1, table.getn(active) do
		local index = i
		AddButton(active[i] or "", ICON_ACTIVE,
			function() SelectGossipActiveQuest(index) end)
	end
	-- 1.12 stride-2 options: text, gossipType pairs.
	local raw = { GetGossipOptions() }
	local optionIndex = 0
	for i = 1, table.getn(raw), 2 do
		optionIndex = optionIndex + 1
		local index = optionIndex
		AddButton(raw[i] or "", ICON_GOSSIP,
			function() SelectGossipOption(index) end)
	end
	FinishLayout()
end

local function ShowGreeting()
	mode = "greeting"
	OpenSheet(UnitName("npc"))
	AddText(GetGreetingText() or "")

	-- Plain quest-giver greeting uses its own selection API (indices, not the
	-- gossip calls — this path only exists on NPCs without gossip).
	for i = 1, GetNumAvailableQuests() do
		local index = i
		AddButton(GetAvailableTitle(i), ICON_AVAILABLE,
			function() SelectAvailableQuest(index) end)
	end
	for i = 1, GetNumActiveQuests() do
		local index = i
		AddButton(GetActiveTitle(i), ICON_ACTIVE,
			function() SelectActiveQuest(index) end)
	end
	FinishLayout()
end

local function ShowDetail()
	mode = "detail"
	OpenSheet(GetTitleText())
	AddButton("Accept quest", nil, function() AcceptQuest() end)
	AddButton("Decline", nil, function() DeclineQuest() end)
	local objectives = GetObjectiveText()
	if objectives and objectives ~= "" then
		AddText("Objectives", 34, 1, 0.82, 0)
		AddText(objectives)
	end
	AddText(GetQuestText() or "")
	FinishLayout()
end

local function ShowProgress()
	mode = "progress"
	OpenSheet(GetTitleText())

	local ready = IsQuestCompletable()
	local continueBtn = AddButton(ready and "Continue" or "Not yet complete", nil,
		function() CompleteQuest() end)
	WM.SetButtonEnabled(continueBtn, ready)
	AddButton("Cancel", nil, function() DeclineQuest() end)

	AddText(GetProgressText() or "")

	local numItems = GetNumQuestItems()
	if numItems > 0 then
		AddText("Required items", 34, 1, 0.82, 0)
		AddItemGrid(CollectQuestItems("required", numItems), nil)
	end
	-- Money requirements exist on some 1.12 quests but the client build may
	-- lack the accessor; guarded.
	local money = GetQuestMoneyToGet and GetQuestMoneyToGet() or 0
	if money > 0 then
		AddText("Required: " .. WM.FormatMoney(money))
	end
	FinishLayout("progress") -- QUEST_ITEM_UPDATE re-renders keep the scroll
end

local ShowComplete -- forward: the reward grid re-enters it

ShowComplete = function()
	mode = "complete"
	OpenSheet(GetTitleText())

	local numChoices = GetNumQuestChoices()
	local mustChoose = numChoices > 1

	local completeButton = AddButton(
		(mustChoose and not chosenReward) and "Choose a reward first" or "Complete quest",
		nil,
		function()
			-- With a single forced choice, index 1; with none, 0 (matches the
			-- default UI's GetQuestReward contract).
			local choice = chosenReward or (numChoices == 1 and 1) or 0
			if mustChoose and not chosenReward then return end
			GetQuestReward(choice)
		end)
	WM.SetButtonEnabled(completeButton, not (mustChoose and not chosenReward))

	AddText(GetRewardText() or "")

	if numChoices > 0 then
		AddText(mustChoose and "Choose one reward" or "Reward", 34, 1, 0.82, 0)
		local items = CollectQuestItems("choice", numChoices)
		for i = 1, table.getn(items) do
			items[i].selected = (i == chosenReward)
		end
		AddItemGrid(items, function(_, i)
			chosenReward = i
			ShowComplete() -- rebuild to repaint selection + enable Complete
		end)
	end

	local numRewards = GetNumQuestRewards()
	if numRewards > 0 then
		AddText("You will also receive", 34, 1, 0.82, 0)
		AddItemGrid(CollectQuestItems("reward", numRewards), nil)
	end

	local money = GetRewardMoney()
	if money and money > 0 then
		AddText(WM.FormatMoney(money))
	end
	FinishLayout("complete") -- reward-pick rebuilds keep the scroll
end

--------------------------------------------------------------------------------
-- Merchant view (vendoring/repair as a bottom sheet)
--------------------------------------------------------------------------------

local ShowMerchant -- forward: the tab buttons re-enter it

-- Parse "[Name]" out of an item link (Lua 5.0: string.find captures, no
-- string.match) and the numeric id for GetItemInfo.
local function LinkName(link)
	if not link then return nil end
	local _, _, name = string.find(link, "%[(.-)%]")
	return name
end

local function LinkQuality(link)
	if not link then return nil end
	local _, _, id = string.find(link, "item:(%d+)")
	if not id then return nil end
	-- 1.12 GetItemInfo: name, link, QUALITY, level, type, subType, stackCount,
	-- invType, texture (no minLevel — that return was added in 2.0).
	local _, _, quality = GetItemInfo("item:" .. id)
	return quality
end

local function CollectMerchantItems()
	local items = {}
	for i = 1, GetMerchantNumItems() do
		-- 1.12: name, texture, price, quantity, numAvailable, isUsable
		-- (no extendedCost — token vendors are a TBC-era addition).
		local name, texture, price, quantity, numAvailable =
			GetMerchantItemInfo(i)
		local index = i
		if not name then
			-- Uncached item record; MERCHANT_UPDATE re-renders when it lands.
			name = RETRIEVING
		end
		local quality = LinkQuality(GetMerchantItemLink and GetMerchantItemLink(i))
		local label = QualityColoredName(name, quality)
		if quantity and quantity > 1 then
			label = label .. " x" .. quantity
		end
		if numAvailable and numAvailable >= 0 then
			label = label .. " |cff9999a3(" .. numAvailable .. " left)|r"
		end
		if price and price > 0 then
			local priceText = WM.FormatMoney(price)
			if GetMoney() < price then
				priceText = priceText .. " |cffcc3333(can't afford)|r"
			end
			label = label .. "\n" .. priceText
		end
		table.insert(items, {
			icon = texture,
			label = label,
			index = index,
			tooltip = function(tt) tt:SetMerchantItem(index) end,
		})
	end
	return items
end

local function CollectSellableItems()
	local items = {}
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			-- 1.12: texture, itemCount, locked, quality, readable.
			local icon, count, _, quality = GetContainerItemInfo(bag, slot)
			if icon then
				local link = GetContainerItemLink(bag, slot)
				local name = LinkName(link) or RETRIEVING
				-- The 1.12 client exposes no vendor sell prices (that data
				-- reached the client with 3.x; vanilla-era "GetSellValue" was
				-- an addon-maintained database), so cells show no price line.
				local label = QualityColoredName(name, quality)
				local b, s = bag, slot
				table.insert(items, {
					icon = icon,
					count = count,
					label = label,
					tooltip = function(tt) tt:SetBagItem(b, s) end,
					bag = b,
					slot = s,
				})
			end
		end
	end
	return items
end

local function CollectBuybackItems()
	local items = {}
	for i = 1, GetNumBuybackItems() do
		local name, texture, price, quantity = GetBuybackItemInfo(i)
		local index = i
		items[i] = {
			icon = texture,
			count = quantity,
			label = (name or RETRIEVING) ..
				(price and price > 0 and ("\n" .. WM.FormatMoney(price)) or ""),
			index = index,
			tooltip = function(tt) tt:SetBuybackItem(index) end,
		}
	end
	return items
end

ShowMerchant = function()
	mode = "merchant"
	OpenSheet(UnitName("npc"))

	AddButtonRow({
		{ label = "Buy", selected = merchantTab == "buy",
			onTap = function() merchantTab = "buy" ShowMerchant() end },
		{ label = "Sell", selected = merchantTab == "sell",
			onTap = function() merchantTab = "sell" ShowMerchant() end },
		{ label = "Buyback", selected = merchantTab == "buyback",
			onTap = function() merchantTab = "buyback" ShowMerchant() end },
	})
	AddText("Your money: " .. WM.FormatMoney(GetMoney()), 28)

	if merchantTab == "buy" then
		if CanMerchantRepair and CanMerchantRepair() then
			local cost = GetRepairAllCost()
			local repair = AddButton(
				cost > 0 and ("Repair all — " .. WM.FormatMoney(cost)) or "Nothing to repair",
				nil,
				function()
					if GetRepairAllCost() > 0 then RepairAllItems() end
				end)
			WM.SetButtonEnabled(repair, cost > 0 and GetMoney() >= cost)
		end
		-- BuyMerchantItem with no quantity buys one listed batch; the error
		-- path ("not enough money") surfaces in UIErrorsFrame like the
		-- default UI.
		AddItemGrid(CollectMerchantItems(), function(item)
			BuyMerchantItem(item.index)
		end)
	elseif merchantTab == "sell" then
		AddText("Tap an item to sell it.", 26, 0.7, 0.7, 0.75)
		local items = CollectSellableItems()
		if table.getn(items) == 0 then
			AddText("Your bags are empty.", 28, 0.7, 0.7, 0.75)
		end
		-- UseContainerItem sells while a merchant window is open (the same
		-- semantics the default bags use at a vendor on 1.12).
		AddItemGrid(items, function(item)
			UseContainerItem(item.bag, item.slot)
		end)
	else -- buyback
		local items = CollectBuybackItems()
		if table.getn(items) == 0 then
			AddText("Nothing to buy back.", 28, 0.7, 0.7, 0.75)
		end
		AddItemGrid(items, function(item)
			BuybackItem(item.index)
		end)
	end
	-- Per-tab key: switching tabs starts at the top, but the re-renders every
	-- sale/purchase triggers (MERCHANT_UPDATE / PLAYER_MONEY / BAG_UPDATE)
	-- keep the user's place in the list.
	FinishLayout("merchant:" .. merchantTab)
end

--------------------------------------------------------------------------------
-- Trainer view (class/profession training as a bottom sheet)
--------------------------------------------------------------------------------

local function ShowTrainer()
	mode = "trainer"
	OpenSheet(UnitName("npc"))
	AddText("Your money: " .. WM.FormatMoney(GetMoney()), 28)

	local n = GetNumTrainerServices()
	if n == 0 then
		AddText("Nothing to learn here right now.", 30, 0.7, 0.7, 0.75)
	end
	for i = 1, n do
		-- 1.12: name, rank, category ("available"/"unavailable"/"used"/
		-- "header"), expanded.
		local name, rank, category = GetTrainerServiceInfo(i)
		if category == "header" then
			AddText(name or "", 34, 1, 0.82, 0)
		else
			local index = i
			local icon = GetTrainerServiceIcon(i)
			local cost = GetTrainerServiceCost(i)
			local label = (name or "") ..
				(rank and rank ~= "" and (" (" .. rank .. ")") or "")
			local tooltip = function(tt) tt:SetTrainerService(index) end
			if category == "available" then
				if cost and cost > 0 then
					label = label .. "  —  " .. WM.FormatMoney(cost)
				end
				local b = AddButton("|cff33cc33" .. label .. "|r", icon,
					function() BuyTrainerService(index) end, tooltip)
				WM.SetButtonEnabled(b, not cost or cost <= GetMoney())
			elseif category == "used" then
				AddButton("|cff9999a3" .. label .. " — known|r", icon, nil, tooltip)
			else -- "unavailable": requirements in the tooltip
				if cost and cost > 0 then
					label = label .. "  —  " .. WM.FormatMoney(cost)
				end
				AddButton("|cffcc4444" .. label .. "|r", icon, nil, tooltip)
			end
		end
	end
	FinishLayout("trainer") -- TRAINER_UPDATE/PLAYER_MONEY re-renders keep the scroll
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Single hide path: clearing lastView here is what makes FinishLayout treat
-- the next NPC visit as a fresh view even when it opens on the same key.
local function HideSheet()
	sheet:Hide()
	mode, lastView = nil, nil
end

local function Dismiss()
	-- Tell the server side we walked away; the close events then hide us.
	if mode == "gossip" then
		CloseGossip()
	elseif mode == "merchant" then
		CloseMerchant()
	elseif mode == "trainer" then
		CloseTrainer()
	elseif mode == "acceptconfirm" then
		DeclineQuest() -- pass on the party-started quest offer
	elseif mode then
		CloseQuest()
	end
	HideSheet()
end

--------------------------------------------------------------------------------
-- Escort-quest accept confirmation
-- QUEST_ACCEPT_CONFIRM(playerName, questTitle) fires when a party member
-- starts a shared-accept quest (escorts). In the default 1.12 UI that
-- confirmation is raised by QuestFrame's OnEvent
-- (StaticPopup_Show("QUEST_ACCEPT", arg1, arg2)) — and Blizzard.lua
-- unregistered QuestFrame's events, so the sheet must render it itself or the
-- offer would silently never appear.
--------------------------------------------------------------------------------

local acceptConfirmToken = 0

local function ShowAcceptConfirm(playerName, questTitle)
	-- Default-UI guard: with a full quest log the offer is ignored outright —
	-- same bail-out here (1.12 log cap is 20 quests).
	local _, numQuests = GetNumQuestLogEntries()
	if numQuests >= (MAX_QUESTLOG_QUESTS or 20) then
		return
	end

	mode = "acceptconfirm"
	OpenSheet(questTitle)
	-- QUEST_ACCEPT is Blizzard's format string for exactly this dialog,
	-- taking (playerName, title).
	AddText(string.format(QUEST_ACCEPT or "%s has asked you to accept: %s",
		playerName or "Someone", questTitle or ""))
	AddButton("Accept quest", nil, function()
		ConfirmAcceptQuest()
		HideSheet()
	end)
	AddButton("Decline", nil, function()
		DeclineQuest()
		HideSheet()
	end)
	FinishLayout()

	-- The server-side offer expires; mirror the default popup's 60 s timeout
	-- so the sheet never lingers on a dead offer. The token voids the timer
	-- when another view (or a newer confirmation) replaced this one.
	acceptConfirmToken = acceptConfirmToken + 1
	local token = acceptConfirmToken
	WM.After(STATICPOPUP_TIMEOUT or 60, function()
		if mode == "acceptconfirm" and token == acceptConfirmToken then
			HideSheet()
		end
	end)
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileBottomSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetWidth(WM.Px(880))
	titleText:SetJustifyH("LEFT")
	WM.SingleLine(titleText, 40)

	-- 100x96: >=90 px touch targets for the rebuilt NPC sheets.
	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104)) -- below title bar + close
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	-- If a deck panel or the map takes the stage, walk away from the NPC too.
	WM.Deck.RegisterExclusive("sheet", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("GOSSIP_SHOW", ShowGossip)
	WM.On("QUEST_GREETING", ShowGreeting)
	WM.On("QUEST_DETAIL", ShowDetail)
	WM.On("QUEST_PROGRESS", ShowProgress)
	WM.On("QUEST_COMPLETE", function()
		chosenReward = nil
		ShowComplete()
	end)
	WM.TryOn("QUEST_ACCEPT_CONFIRM", function(_, playerName, questTitle)
		ShowAcceptConfirm(playerName, questTitle)
	end)
	-- Uncached reward/required items resolve asynchronously; re-render so
	-- names never stay stuck on "Retrieving item information" (the default
	-- QuestFrame re-renders on this event too).
	WM.TryOn("QUEST_ITEM_UPDATE", function()
		if mode == "progress" then
			ShowProgress()
		elseif mode == "complete" then
			ShowComplete()
		end
	end)
	WM.On("GOSSIP_CLOSED", function()
		if mode == "gossip" then HideSheet() end
	end)
	-- Covers every quest view, "acceptconfirm" included (e.g. the offering
	-- party member cancels the escort before we answer).
	WM.On("QUEST_FINISHED", function()
		if mode and mode ~= "gossip" and mode ~= "merchant" and mode ~= "trainer" then
			HideSheet()
		end
	end)

	WM.On("MERCHANT_SHOW", function()
		merchantTab = "buy"
		ShowMerchant()
	end)
	WM.On("MERCHANT_UPDATE", function()
		if mode == "merchant" then ShowMerchant() end
	end)
	WM.On("MERCHANT_CLOSED", function()
		if mode == "merchant" then HideSheet() end
	end)
	-- Money and bag contents drive the affordability tints / sell list.
	WM.On("PLAYER_MONEY", function()
		if mode == "merchant" then
			ShowMerchant()
		elseif mode == "trainer" then
			ShowTrainer()
		end
	end)
	WM.On("BAG_UPDATE", function()
		if mode == "merchant" and merchantTab == "sell" then
			ShowMerchant()
		end
	end)

	WM.On("TRAINER_SHOW", function()
		-- Show everything except already-known services. The filter set must
		-- be fixed before rendering: BuyTrainerService indices are positions
		-- within the currently filtered list.
		SetTrainerServiceTypeFilter("available", 1)
		SetTrainerServiceTypeFilter("unavailable", 1)
		SetTrainerServiceTypeFilter("used", 0)
		ShowTrainer()
	end)
	WM.On("TRAINER_UPDATE", function()
		if mode == "trainer" then ShowTrainer() end
	end)
	WM.On("TRAINER_CLOSED", function()
		if mode == "trainer" then HideSheet() end
	end)
end)
