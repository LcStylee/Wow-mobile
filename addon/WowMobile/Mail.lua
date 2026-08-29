--------------------------------------------------------------------------------
-- WowMobile · Mail
-- Touch rebuild of the mailbox (the default MailFrame is banished in
-- Blizzard.lua — its OnHide path calls CloseMail, so it must never open).
-- Two tabs:
--   Inbox — big rows (sender, subject, money/item/COD, days left); tap a row
--     for the letter view (body text, per-attachment Take, Take money, Take
--     everything, Delete/Return behind a confirm tap), plus "Collect all"
--     modeled on the 1.15 client's own OpenAllMailMixin (MailFrame.lua,
--     gethe/wow-ui-source classic_era branch): skips COD and GM mail,
--     waits out C_Mail.IsCommandPending between takes, stops on full bags,
--     blacklists items the server refuses (MAIL_FAILED), and restarts its
--     scan when taking mail slides more messages into the 50-shown window.
--   Send — recipient/subject/body fields (phone-keyboard entry pattern),
--     up to ATTACHMENTS_MAX_SEND = 12 attachment slots (the era cap, set in
--     the client's MailFrame.lua) filled via MoveMode or the bag list,
--     money/COD steppers, big Send.
-- All attachment mutations run through SheetKit.CanMove (out-of-combat rule).
--------------------------------------------------------------------------------

local _, WM = ...

local MAX_SEND = ATTACHMENTS_MAX_SEND or 12
local MAX_RECEIVE = ATTACHMENTS_MAX_RECEIVE or 16

local sheet
local stacks, scrollers = {}, {}
local bagList
local toField, subjectField, bodyField, moneyStepper

local inboxView = nil -- nil = list, number = open mail index
local confirmAction   -- "delete" | "cod" | "codall" armed on the open letter
local codMode = false -- send tab: money attached (false) vs COD requested (true)

local RenderInbox, RenderSend

local function RenderTab(key)
	if not sheet or not sheet:IsShown() then return end
	if key ~= sheet.activeTab then return end
	if key == "inbox" then RenderInbox() else RenderSend() end
end

--------------------------------------------------------------------------------
-- Collect all
--------------------------------------------------------------------------------

local collector -- { mailIndex, attach, numToOpen, blacklist } while running
local collectTicker

local function StopCollecting(reason)
	collector = nil
	if collectTicker then
		collectTicker:Cancel()
		collectTicker = nil
	end
	if reason then WM.Print(reason) end
	RenderTab("inbox")
end

local function CollectStep()
	local c = collector
	if not c then return end
	if not sheet:IsShown() then
		StopCollecting(nil)
		return
	end
	if WM.MailCommandPending() then return end -- ticker retries
	if WM.FreeBagSlots() == 0 then
		StopCollecting("Bags are full — collecting stopped.")
		return
	end
	local numItems = GetInboxNumItems()
	while c.mailIndex <= numItems do
		local _, _, _, _, money, cod = GetInboxHeaderInfo(c.mailIndex)
		local isGM = select(13, GetInboxHeaderInfo(c.mailIndex))
		if isGM or (cod and cod > 0) then
			c.mailIndex, c.attach = c.mailIndex + 1, MAX_RECEIVE
		elseif money and money > 0 then
			TakeInboxMoney(c.mailIndex)
			return -- MAIL_INBOX_UPDATE + ticker continue the sweep
		else
			while c.attach >= 1 do
				if HasInboxItem(c.mailIndex, c.attach) then
					local _, itemID = GetInboxItem(c.mailIndex, c.attach)
					if not (itemID and c.blacklist[itemID]) then
						TakeInboxItem(c.mailIndex, c.attach)
						c.attach = c.attach - 1
						return
					end
				end
				c.attach = c.attach - 1
			end
			c.mailIndex, c.attach = c.mailIndex + 1, MAX_RECEIVE
		end
	end
	StopCollecting("Inbox collected.")
end

local function StartCollecting()
	collector = {
		mailIndex = 1,
		attach = MAX_RECEIVE,
		numToOpen = GetInboxNumItems(),
		blacklist = {},
	}
	if not collectTicker then
		collectTicker = C_Timer.NewTicker(0.25, CollectStep)
	end
	CollectStep()
	RenderTab("inbox")
end

--------------------------------------------------------------------------------
-- Inbox
--------------------------------------------------------------------------------

local function RenderLetter(st, index)
	local _, _, sender, subject, money, cod, daysLeft = GetInboxHeaderInfo(index)
	local isGM = select(13, GetInboxHeaderInfo(index))

	st.Button("< Back to inbox", nil, function()
		inboxView, confirmAction = nil, nil
		RenderTab("inbox")
	end)

	st.Text((sender or UNKNOWN) .. " — " .. (subject or ""), 34)
	if daysLeft then
		local r, g, b = 0.7, 0.7, 0.75
		if daysLeft < 1 then r, g, b = 0.85, 0.35, 0.35 end
		st.Text(string.format("Expires in %.1f days", daysLeft), 26, r, g, b)
	end

	-- GetInboxText marks the mail read server-side, same as opening it in the
	-- default UI.
	local body = GetInboxText(index)
	if body and body ~= "" then
		st.Text(body, 30)
	end

	local hasCOD = cod and cod > 0
	if hasCOD then
		st.Text("Cash on delivery: taking the items pays " .. WM.FormatMoney(cod), 28, 1, 0.82, 0)
	end

	local items = {}
	for j = 1, MAX_RECEIVE do
		if HasInboxItem(index, j) then
			local name, _, texture, count, quality = GetInboxItem(index, j)
			local attach = j
			items[#items + 1] = {
				icon = texture,
				count = count,
				label = WM.SheetKit.QualityName(name or RETRIEVING_ITEM_INFO, name and quality or nil),
				attach = attach,
				tooltip = function(tt) tt:SetInboxItem(index, attach) end,
			}
		end
	end
	if #items > 0 then
		st.Text("Attachments — tap to take", 28, 0.7, 0.7, 0.75)
		st.Grid(items, function(item)
			if hasCOD and confirmAction ~= "cod" then
				confirmAction = "cod"
				RenderTab("inbox")
				return
			end
			confirmAction = nil
			TakeInboxItem(index, item.attach)
		end)
		if hasCOD and confirmAction == "cod" then
			st.Text("Tap the item again to take it and pay the COD.", 26, 1, 0.82, 0)
		end
	end

	if money and money > 0 then
		st.Button("Take " .. WM.FormatMoney(money), nil, function()
			TakeInboxMoney(index)
		end)
	end
	if #items > 0 or (money and money > 0) then
		st.Button(hasCOD and ("Take everything (pays " .. WM.FormatMoney(cod) .. ")")
			or "Take everything", nil, function()
			if hasCOD and confirmAction ~= "codall" then
				confirmAction = "codall"
				RenderTab("inbox")
				return
			end
			confirmAction = nil
			AutoLootMailItem(index)
		end)
		if hasCOD and confirmAction == "codall" then
			st.Text("Tap again to confirm paying the COD.", 26, 1, 0.82, 0)
		end
	end

	-- Delete vs Return follows the server's rule (returned/system mail can
	-- only be deleted; player mail with content returns to the sender).
	local canDelete = InboxItemCanDelete(index)
	if not isGM then
		local verb = canDelete and "Delete" or "Return to sender"
		if confirmAction == "delete" then
			st.Row({
				{ label = "Confirm " .. verb, red = true, onTap = function()
					confirmAction = nil
					if canDelete then
						DeleteInboxItem(index)
					else
						ReturnInboxItem(index)
					end
					inboxView = nil
					RenderTab("inbox")
				end },
				{ label = "Back", onTap = function()
					confirmAction = nil
					RenderTab("inbox")
				end },
			})
		else
			st.Button(verb, nil, function()
				confirmAction = "delete"
				RenderTab("inbox")
			end)
		end
	end
end

RenderInbox = function()
	local st = stacks.inbox
	st.Reset()

	if inboxView then
		-- The open letter may have vanished (taken empty + auto-deleted).
		local _, _, sender = GetInboxHeaderInfo(inboxView)
		if sender then
			RenderLetter(st, inboxView)
			st.Finish("letter:" .. inboxView)
			return
		end
		inboxView, confirmAction = nil, nil
	end

	local numItems, totalItems = GetInboxNumItems()
	st.Text("Your money: " .. WM.FormatMoney(GetMoney()), 26)

	if collector then
		st.Button("Collecting… tap to stop", nil, function()
			StopCollecting("Collecting stopped.")
		end)
	elseif numItems > 0 then
		st.Button("Collect all (skips COD mail)", nil, StartCollecting)
	end

	if numItems == 0 then
		st.Text("Your mailbox is empty.", 30, 0.7, 0.7, 0.75)
	end
	for i = 1, numItems do
		local packageIcon, stationeryIcon, sender, subject, money, cod, daysLeft,
			itemCount, wasRead = GetInboxHeaderInfo(i)
		local line2 = {}
		if money and money > 0 then line2[#line2 + 1] = WM.FormatMoney(money) end
		if itemCount and itemCount > 0 then line2[#line2 + 1] = itemCount .. " item" .. (itemCount > 1 and "s" or "") end
		if cod and cod > 0 then line2[#line2 + 1] = "|cffcc4444COD " .. WM.FormatMoney(cod) .. "|r" end
		if daysLeft then
			line2[#line2 + 1] = (daysLeft < 1 and "|cffcc4444" or "|cff9999a3")
				.. string.format("%.1fd left", daysLeft) .. "|r"
		end
		local label = (wasRead and "|cff9999a3" or "")
			.. (sender or UNKNOWN) .. " — " .. (subject or "") .. (wasRead and "|r" or "")
		if #line2 > 0 then
			label = label .. "\n|cffbbbbc4" .. table.concat(line2, " · ") .. "|r"
		end
		local index = i
		st.Button(label, packageIcon or stationeryIcon, function()
			inboxView, confirmAction = index, nil
			RenderTab("inbox")
		end)
	end
	if totalItems and totalItems > numItems then
		st.Text((totalItems - numItems) .. " more mails arrive as these are cleared (the mailbox shows 50 at a time).",
			26, 0.7, 0.7, 0.75)
	end
	st.Finish("inbox")
end

--------------------------------------------------------------------------------
-- Send
--------------------------------------------------------------------------------

local function FirstFreeSendSlot()
	for i = 1, MAX_SEND do
		if not HasSendMailItem(i) then return i end
	end
	return nil
end

RenderSend = function()
	local st = stacks.send
	st.Reset()

	st.Anchor(toField, 96)
	st.Anchor(subjectField, 96)
	st.Anchor(bodyField, 96)

	local carrying = GetCursorInfo() == "item"

	-- Attachment slots: the filled ones plus one open slot (12 max — the era
	-- send cap, see header).
	local items, filled = {}, 0
	for i = 1, MAX_SEND do
		if HasSendMailItem(i) then
			filled = filled + 1
			local name, _, texture, count, quality = GetSendMailItem(i)
			local slot = i
			items[#items + 1] = {
				icon = texture,
				count = count,
				label = WM.SheetKit.QualityName(name or RETRIEVING_ITEM_INFO, name and quality or nil),
				slot = slot,
				tooltip = function(tt) tt:SetSendMailItem(slot) end,
			}
		end
	end
	local freeSlot = FirstFreeSendSlot()
	if freeSlot then
		items[#items + 1] = {
			icon = nil,
			label = carrying and "|cff33cc33Place carried item|r"
				or ("Attach (" .. filled .. "/" .. MAX_SEND .. ")"),
			slot = freeSlot,
			dropTarget = carrying,
		}
	end
	st.Text("Attachments — tap an item to take it back", 28, 0.7, 0.7, 0.75)
	st.Grid(items, function(item)
		if not WM.SheetKit.CanMove() then return end
		local t = GetCursorInfo()
		if t and t ~= "item" then
			WM.MoveMode.Cancel()
			return
		end
		-- One call does both: places the carried item into the slot, or lifts
		-- the slot's item onto the cursor (MoveMode adopts it into the carry
		-- bar), Blizzard's own send-slot semantics.
		ClickSendMailItemButton(item.slot)
	end)

	st.Anchor(moneyStepper, 150)
	st.Row({
		{ label = "Send money", selected = not codMode, onTap = function()
			codMode = false
			RenderTab("send")
		end },
		{ label = "Request COD", selected = codMode, onTap = function()
			codMode = true
			RenderTab("send")
		end },
	})

	local postage = GetSendMailPrice() or 30
	st.Text("Postage: " .. WM.FormatMoney(postage)
		.. "   ·   Your money: " .. WM.FormatMoney(GetMoney()), 26)

	-- Typing never re-renders this stack (a full rebuild would drop the edit
	-- box's keyboard focus every keystroke), so NOTHING about validity may be
	-- baked into the button at render time: the tap below re-reads every field
	-- and validates live — a recipient typed after the last render works, and
	-- a recipient edited after the last render can never be shadowed by a
	-- stale render-time capture (items/money go where the field says NOW).
	local send = st.Button("Send", nil, function()
		local recipient = strtrim(toField:GetText() or "")
		local copper = moneyStepper.GetCopper()
		local nowFilled, firstItemName = 0, nil
		for i = 1, MAX_SEND do
			if HasSendMailItem(i) then
				nowFilled = nowFilled + 1
				firstItemName = firstItemName or (GetSendMailItem(i))
			end
		end
		if recipient == "" then
			UIErrorsFrame:AddMessage("Enter a recipient first.", 1, 0.3, 0.3)
			return
		end
		if codMode and copper > 0 and nowFilled == 0 then
			UIErrorsFrame:AddMessage("COD needs an attached item.", 1, 0.3, 0.3)
			return
		end
		if not codMode and copper + (GetSendMailPrice() or 30) > GetMoney() then
			UIErrorsFrame:AddMessage("Can't afford money + postage.", 1, 0.3, 0.3)
			return
		end
		-- Always set BOTH sides, like the official SendMailFrame does
		-- (MailFrame.lua sets SetSendMailCOD(0) alongside the money): the
		-- client's staged send state survives a failed SendMail, so zeroing
		-- the inactive one is what keeps a stale money stage from riding
		-- along on a COD mail (and vice versa) after a mode switch.
		SetSendMailMoney(codMode and 0 or copper)
		SetSendMailCOD(codMode and copper or 0)
		local subject = subjectField:GetText() or ""
		if subject == "" then
			-- Same default the client applies: name the mail after its content.
			subject = firstItemName or "(no subject)"
		end
		SendMail(recipient, subject, bodyField:GetText() or "")
	end)
	local a = WM.Colors.accent
	send.borderTex:SetColorTexture(a[1], a[2], a[3], 1)

	st.Text("Your items — tap to attach, long-press to carry", 26, 0.7, 0.7, 0.75)
	local used = bagList.Render(st.Y(), function(bag, slotIndex)
		if not WM.SheetKit.CanMove() then return end
		if GetCursorInfo() then return end -- a live carry owns the next tap
		local free = FirstFreeSendSlot()
		if not free then
			UIErrorsFrame:AddMessage("All " .. MAX_SEND .. " attachment slots are full.", 1, 0.3, 0.3)
			return
		end
		WM.Container.Pickup(bag, slotIndex)
		if GetCursorInfo() == "item" then
			ClickSendMailItemButton(free)
		end
	end)
	st.Skip(used)
	st.Finish("send")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function ClearSendForm()
	toField:SetText("")
	subjectField:SetText("")
	bodyField:SetText("")
	moneyStepper.SetCopper(0)
	codMode = false
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("mail", "Mail", {
		{ key = "inbox", label = "Inbox" },
		{ key = "send",  label = "Send" },
	})
	sheet.OnDismiss = function()
		CloseMail() -- MAIL_CLOSED then hides the sheet
	end
	sheet.OnTabShow = RenderTab

	for _, key in ipairs({ "inbox", "send" }) do
		scrollers[key] = WM.Deck.CreateScroller(sheet.tabFrames[key])
		stacks[key] = Kit.NewStack(scrollers[key])
	end
	bagList = Kit.NewBagList(scrollers.send)

	toField = Kit.CreateTextField(scrollers.send.child, 950, "To…", 48)
	subjectField = Kit.CreateTextField(scrollers.send.child, 950, "Subject…", 64)
	bodyField = Kit.CreateTextField(scrollers.send.child, 950, "Message…", 500)
	moneyStepper = Kit.CreateMoneyStepper(scrollers.send.child, "Money")
	moneyStepper.onChange = function() RenderTab("send") end

	-- MAIL_SHOW is the mailbox-interaction event on era; the 10.x engine can
	-- deliver the same moment as PLAYER_INTERACTION_MANAGER_FRAME_SHOW too —
	-- both funnel here and a double Open is harmless (Show + re-render).
	local function OnMailOpen()
		inboxView, confirmAction = nil, nil
		CheckInbox()
		sheet.Open()
		sheet.SelectTab("inbox")
	end
	WM.TryOn("MAIL_SHOW", OnMailOpen)
	WM.TryOn("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, interactionType)
		if Enum and Enum.PlayerInteractionType
				and interactionType == Enum.PlayerInteractionType.MailInfo
				and not sheet:IsShown() then
			OnMailOpen()
		end
	end)
	WM.On("MAIL_CLOSED", function()
		StopCollecting(nil)
		inboxView = nil
		if sheet:IsShown() then sheet:Hide() end
		for _, st in pairs(stacks) do st.ClearView() end
	end)

	WM.On("MAIL_INBOX_UPDATE", function()
		if collector and collector.numToOpen ~= GetInboxNumItems() then
			-- Taking mail slid new messages into the 50-shown window (or a
			-- mail auto-deleted); restart the scan on the fresh indices — the
			-- same re-anchor the default OpenAllMailMixin does.
			collector.mailIndex, collector.attach = 1, MAX_RECEIVE
			collector.numToOpen = GetInboxNumItems()
		end
		RenderTab("inbox")
	end)
	WM.On("MAIL_SEND_SUCCESS", function()
		WM.Print("Mail sent.")
		ClearSendForm()
		RenderTab("send")
	end)
	WM.On("MAIL_FAILED", function(_, itemID)
		if collector and itemID then
			collector.blacklist[itemID] = true -- e.g. unique item already owned
		end
	end)
	WM.TryOn("SEND_MAIL_MONEY_CHANGED", function() RenderTab("send") end)
	WM.TryOn("SEND_MAIL_COD_CHANGED", function() RenderTab("send") end)
	WM.On("PLAYER_MONEY", function() RenderTab(sheet.activeTab) end)
	WM.On("BAG_UPDATE", function() RenderTab("send") end)
	WM.TryOn("CURSOR_CHANGED", function() RenderTab("send") end)
	WM.TryOn("CURSOR_UPDATE", function() RenderTab("send") end)
end)
