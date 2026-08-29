--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Mail
-- Mailbox as a deck bottom sheet, replacing the default MailFrame /
-- OpenMailFrame (banished with events unregistered in Blizzard.lua —
-- MailFrame's OnHide calls CloseMail, so the established suppression
-- technique applies).
--
-- 1.12 mail facts this module is built around (vanilla FrameXML MailFrame.lua):
--   * ONE attachment per mail: GetInboxHeaderInfo's hasItem is a flag, not a
--     count, TakeInboxItem(index) takes no attachment sub-index, and the send
--     side has a single slot loaded via ClickSendMailItemButton() (cursor
--     item in -> slot; empty cursor -> picks the slot's item back up). The
--     send sheet therefore has exactly one attachment slot.
--   * NO AutoLootMailItem on this client (a 2.x addition), so "Collect all"
--     is a stepper: ONE Take* call per MAIL_INBOX_UPDATE round-trip. Looping
--     blindly would race the server and, worse, indices SHIFT when an emptied
--     mail auto-deletes — each step rescans from mail 1. COD mails are
--     skipped (never auto-pay); a watchdog stops the run when no update
--     arrives (bags full and the like).
--   * GetInboxHeaderInfo(i) -> packageIcon, stationeryIcon, sender, subject,
--     money, CODAmount, daysLeft, hasItem, wasRead, wasReturned, textCreated,
--     canReply. GetInboxText(i) returns the body (and marks the mail read).
--   * Delete vs return: InboxItemCanDelete(i) gates DeleteInboxItem(i);
--     non-deletable mail (unread with attachments from players) goes back
--     via ReturnInboxItem(i).
--   * Send: SendMail(to, subject, body); money vs COD are mutually exclusive
--     (SetSendMailMoney / SetSendMailCOD); GetSendMailPrice() is the postage.
--     No body composer on the phone — the body argument is sent empty
--     (accepted trade-off; the subject line carries short notes).
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 130
local GAP = 8
local CELL = 114 -- bag-grid cell, same 8-column budget as Bags.lua
local COLS = 8

local sheet, confirm
local inboxArea, sendArea, inboxScroller, sendScroller
local detail, detailScroller
local tabInbox, tabSend, collectBtn
local recipientBox, subjectBox, attachSlot, attachName, postageText, sendBtn
local moneyModeBtns, moneyStepper

local tab = "inbox"       -- "inbox" | "send"
local moneyMode = "none"  -- "none" | "money" | "cod"
local openMail            -- { index, sender, subject } while the detail overlay is up
local collecting = false
local lastStepAt = 0
local lastInboxCheckAt = 0

local inboxRows = {}
local sendCells = {}      -- "bag:slot" -> bag-grid cell
local sendGridTop = 0     -- y where the send bag grid starts (set at init)
local emptyText

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

--------------------------------------------------------------------------------
-- Inbox list
--------------------------------------------------------------------------------

local OpenDetail -- forward

local function AcquireInboxRow(i)
	local row = inboxRows[i]
	if row then return row end
	row = WM.CreateTouchButton(inboxScroller.child, 100, ROW_H, nil, 30)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(84))
	row.icon:SetHeight(WM.Px(84))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(14), 0)
	row.label:Hide()
	row.line1 = WM.CreateText(row, 30)
	row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(116), -WM.Px(20))
	row.line1:SetJustifyH("LEFT")
	row.line1:SetWidth(WM.Px(480))
	WM.SingleLine(row.line1, 30)
	row.line2 = WM.CreateText(row, 24)
	row.line2:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(116), WM.Px(16))
	row.line2:SetJustifyH("LEFT")
	row.line2:SetWidth(WM.Px(480))
	row.line2:SetTextColor(0.7, 0.7, 0.75)
	WM.SingleLine(row.line2, 24)
	row.info = WM.CreateText(row, 26)
	row.info:SetPoint("TOPRIGHT", row, "TOPRIGHT", -WM.Px(16), -WM.Px(22))
	row.info:SetJustifyH("RIGHT")
	row.days = WM.CreateText(row, 22)
	row.days:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -WM.Px(16), WM.Px(16))
	row.days:SetTextColor(0.6, 0.6, 0.65)
	row:SetScript("OnClick", function()
		OpenDetail(this.index)
	end)
	inboxRows[i] = row
	return row
end

local function RenderInbox()
	if not IsOpen() or tab ~= "inbox" then return end
	local n = GetInboxNumItems()
	for i = 1, n do
		local packageIcon, stationeryIcon, sender, subject, money, cod,
			daysLeft, hasItem, wasRead = GetInboxHeaderInfo(i)
		local row = AcquireInboxRow(i)
		row.index = i
		row.icon:SetTexture(packageIcon or stationeryIcon or WM.TEX_QUESTION)
		row.line1:SetText(sender or "Unknown")
		if wasRead then
			row.line1:SetTextColor(0.65, 0.65, 0.7)
		else
			row.line1:SetTextColor(0.92, 0.92, 0.92)
		end
		row.line2:SetText(subject or "")
		local info = ""
		if money and money > 0 then
			info = WM.FormatMoney(money)
		elseif cod and cod > 0 then
			info = "|cffcc4444COD " .. WM.FormatMoney(cod) .. "|r"
		elseif hasItem then
			info = "|cff33cc33Item|r"
		end
		row.info:SetText(info)
		if daysLeft then
			if daysLeft >= 1 then
				row.days:SetText(string.format("%dd left", math.floor(daysLeft)))
			else
				row.days:SetText("<1d left")
			end
		else
			row.days:SetText("")
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", inboxScroller.child, "TOPLEFT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetPoint("TOPRIGHT", inboxScroller.child, "TOPRIGHT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetHeight(WM.Px(ROW_H))
		row:Show()
	end
	for i = n + 1, table.getn(inboxRows) do
		inboxRows[i]:Hide()
	end
	WM.SetShown(emptyText, n == 0)
	inboxScroller.SetContentHeight(WM.Px(n * (ROW_H + GAP)))
end

--------------------------------------------------------------------------------
-- Detail overlay (read one mail)
--------------------------------------------------------------------------------

local function RefreshDetailButtons()
	if not openMail then return end
	local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(openMail.index)
	if hasItem then
		detail.takeItem.label:SetText((cod and cod > 0)
			and ("Take item (COD " .. WM.FormatMoney(cod) .. ")")
			or "Take item")
		WM.SetButtonEnabled(detail.takeItem, true)
	else
		detail.takeItem.label:SetText("No item")
		WM.SetButtonEnabled(detail.takeItem, false)
	end
	if money and money > 0 then
		detail.takeMoney.label:SetText("Take " .. WM.FormatMoney(money))
		WM.SetButtonEnabled(detail.takeMoney, true)
	else
		detail.takeMoney.label:SetText("No money")
		WM.SetButtonEnabled(detail.takeMoney, false)
	end
	if InboxItemCanDelete(openMail.index) then
		detail.deleteBtn.label:SetText("Delete")
		detail.deleteBtn.isReturn = nil
	else
		detail.deleteBtn.label:SetText("Return to sender")
		detail.deleteBtn.isReturn = true
	end
end

OpenDetail = function(index)
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	if not sender and not subject then return end
	openMail = { index = index, sender = sender, subject = subject }
	detail.title:SetText((sender or "?") .. " — " .. (subject or ""))
	-- GetInboxText marks the mail read server-side, like opening the letter.
	local body = GetInboxText(index)
	detail.body:SetText(body and body ~= "" and body or "|cff9999a3(no text)|r")
	detailScroller.SetContentHeight(detail.body:GetHeight() + WM.Px(24))
	detailScroller.ScrollToTop()
	RefreshDetailButtons()
	detail:Show()
end

local function CloseDetail()
	openMail = nil
	detail:Hide()
end

--------------------------------------------------------------------------------
-- Collect all (see header: one Take* per inbox round-trip, COD skipped)
--------------------------------------------------------------------------------

local function SetCollecting(on)
	collecting = on
	collectBtn.label:SetText(on and "Stop" or "Collect all")
end

local function CollectStep()
	for i = 1, GetInboxNumItems() do
		local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
		if money and money > 0 then
			lastStepAt = GetTime()
			TakeInboxMoney(i)
			return true
		end
		if hasItem and (not cod or cod == 0) then
			lastStepAt = GetTime()
			TakeInboxItem(i)
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Send view
--------------------------------------------------------------------------------

local function RefreshSend()
	if not sendArea then return end
	local itemName, itemTexture, itemCount = GetSendMailItem()
	if itemName then
		attachSlot.icon:SetTexture(itemTexture or WM.TEX_QUESTION)
		attachSlot.icon:SetVertexColor(1, 1, 1)
		attachName:SetText(itemName ..
			(itemCount and itemCount > 1 and (" x" .. itemCount) or ""))
	else
		attachSlot.icon:SetTexture(WM.TEX_WHITE)
		attachSlot.icon:SetVertexColor(0.12, 0.12, 0.14)
		attachName:SetText("|cff9999a3No attachment|r")
	end
	for mode, b in pairs(moneyModeBtns) do
		if mode == moneyMode then
			WM.TintBorder(b, WM.Colors.accent)
		else
			WM.TintBorder(b, WM.Colors.border)
		end
	end
	local ok, price = pcall(GetSendMailPrice)
	postageText:SetText("Postage: " .. WM.FormatMoney(ok and price or 30))
end

local function UpdateSendCell(cell)
	local icon, count, locked = GetContainerItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		cell.icon:SetVertexColor(locked and 0.4 or 1, locked and 0.4 or 1, locked and 0.45 or 1)
		cell.count:SetText(count and count > 1 and count or "")
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
	end
end

-- Load the send slot from a bag slot: return any current attachment home
-- first (Click with empty cursor lifts it; ClearCursor sends a cursor item
-- back to its source bag slot — the MoveMode.Cancel semantics), then place.
local function AttachFromBag(bag, slot)
	if GetSendMailItem() then
		ClickSendMailItemButton()
		ClearCursor()
	end
	PickupContainerItem(bag, slot)
	if CursorHasItem() then
		ClickSendMailItemButton()
		WM.MoveMode.NoteSlotDrop()
	end
	RefreshSend()
end

local function CreateSendCell(bag, slot)
	local cell = CreateFrame("Button", nil, sendScroller.child)
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
			-- Long-press = MoveMode pickup (split a stack, then tap the slot).
			WM.MoveMode.BeginFromBag(this.bag, this.slot)
		else
			AttachFromBag(this.bag, this.slot)
		end
	end)
	WM.MoveMode.MakeTarget(cell, "bag")
	WM.AttachTooltip(cell, function(tt, self)
		tt:SetBagItem(self.bag, self.slot)
	end)
	return cell
end

local function RenderSendBags()
	if not IsOpen() or tab ~= "send" then return end
	local index = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			index = index + 1
			local key = bag .. ":" .. slot
			local cell = sendCells[key]
			if not cell then
				cell = CreateSendCell(bag, slot)
				sendCells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", sendScroller.child, "TOPLEFT",
				WM.Px(col * (CELL + GAP)), -WM.Px(sendGridTop + row * (CELL + GAP)))
			UpdateSendCell(cell)
			cell:Show()
		end
	end
	-- Hide cells whose bag/slot no longer exists (a bag was swapped out).
	for _, cell in pairs(sendCells) do
		if cell.slot > GetContainerNumSlots(cell.bag) then
			cell:Hide()
		end
	end
	sendScroller.SetContentHeight(
		WM.Px(sendGridTop + math.ceil(index / COLS) * (CELL + GAP) + 8))
end

local function DoSend()
	local to = recipientBox:GetText()
	if not to or to == "" then
		WM.Print("Mail: enter a recipient first.")
		return
	end
	local itemName = GetSendMailItem()
	local subject = subjectBox:GetText()
	if not subject or subject == "" then
		subject = itemName or "(No subject)"
	end
	if moneyMode == "cod" then
		if not itemName then
			WM.Print("Mail: COD needs an attached item.")
			return
		end
		if moneyStepper.GetCopper() == 0 then
			WM.Print("Mail: set a COD amount first.")
			return
		end
		SetSendMailCOD(moneyStepper.GetCopper())
	elseif moneyMode == "money" then
		SetSendMailMoney(moneyStepper.GetCopper())
	else
		SetSendMailMoney(0)
	end
	SendMail(to, subject, "")
end

--------------------------------------------------------------------------------
-- Tabs / lifecycle
--------------------------------------------------------------------------------

local function SetTab(t)
	tab = t
	recipientBox:ClearFocus()
	subjectBox:ClearFocus()
	WM.SetShown(inboxArea, t == "inbox")
	WM.SetShown(sendArea, t == "send")
	WM.SetShown(collectBtn, t == "inbox")
	WM.TintBorder(tabInbox, t == "inbox" and WM.Colors.accent or WM.Colors.border)
	WM.TintBorder(tabSend, t == "send" and WM.Colors.accent or WM.Colors.border)
	if t == "inbox" then
		RenderInbox()
	else
		CloseDetail()
		RefreshSend()
		RenderSendBags()
	end
end

local function Dismiss()
	SetCollecting(false)
	CloseDetail()
	CloseMail()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileMailSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	local titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Mail")

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))

	-- Tab row + Collect all.
	tabInbox = WM.CreateTouchButton(content, 280, 96, "Inbox", 30)
	tabInbox:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	tabInbox:SetScript("OnClick", function() SetTab("inbox") end)
	tabSend = WM.CreateTouchButton(content, 280, 96, "Send", 30)
	tabSend:SetPoint("LEFT", tabInbox, "RIGHT", WM.Px(8), 0)
	tabSend:SetScript("OnClick", function() SetTab("send") end)
	collectBtn = WM.CreateTouchButton(content, 340, 96, "Collect all", 30)
	collectBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
	collectBtn:SetScript("OnClick", function()
		if collecting then
			SetCollecting(false)
		else
			SetCollecting(true)
			if not CollectStep() then
				SetCollecting(false)
				WM.Print("Mail: nothing collectible (COD mail is skipped).")
			end
		end
	end)

	-- Inbox area.
	inboxArea = CreateFrame("Frame", nil, content)
	inboxArea:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -WM.Px(108))
	inboxArea:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
	inboxScroller = WM.Deck.CreateScroller(inboxArea)
	emptyText = WM.CreateText(inboxArea, 30)
	emptyText:SetPoint("TOPLEFT", inboxArea, "TOPLEFT", WM.Px(8), -WM.Px(20))
	emptyText:SetText("No mail.")
	emptyText:SetTextColor(0.7, 0.7, 0.75)
	emptyText:Hide()

	-- Send area: every control lives in the scroller so the bag grid below
	-- stays reachable on short decks.
	sendArea = CreateFrame("Frame", nil, content)
	sendArea:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -WM.Px(108))
	sendArea:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
	sendArea:Hide()
	sendScroller = WM.Deck.CreateScroller(sendArea)
	local sc = sendScroller.child

	local toLabel = WM.CreateText(sc, 30)
	toLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(30))
	toLabel:SetText("To")
	recipientBox = WM.CreateEditBox(sc, 780, 90, 12) -- character names cap at 12
	recipientBox:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(170), 0)

	local subjLabel = WM.CreateText(sc, 30)
	subjLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(130))
	subjLabel:SetText("Subject")
	subjectBox = WM.CreateEditBox(sc, 780, 90, 64)
	subjectBox:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(170), -WM.Px(100))

	-- The one attachment slot (see header). Carry-tap places; a plain tap on
	-- a filled slot returns the item to its bag.
	attachSlot = CreateFrame("Button", nil, sc)
	attachSlot:SetWidth(WM.Px(130))
	attachSlot:SetHeight(WM.Px(130))
	attachSlot:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(210))
	WM.SkinFrame(attachSlot, { 0.07, 0.07, 0.09, 1 })
	local ahl = attachSlot:CreateTexture(nil, "HIGHLIGHT")
	ahl:SetAllPoints(attachSlot)
	ahl:SetTexture(1, 1, 1, 0.10)
	attachSlot.icon = attachSlot:CreateTexture(nil, "ARTWORK")
	attachSlot.icon:SetPoint("TOPLEFT", attachSlot, "TOPLEFT", WM.Px(6), -WM.Px(6))
	attachSlot.icon:SetPoint("BOTTOMRIGHT", attachSlot, "BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
	attachSlot:SetScript("OnClick", function()
		if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
			ClickSendMailItemButton()
			WM.MoveMode.NoteSlotDrop()
		elseif GetSendMailItem() then
			ClickSendMailItemButton() -- lift it off the mail...
			ClearCursor()             -- ...and home to its bag slot
		end
		RefreshSend()
	end)
	WM.MoveMode.MakeTarget(attachSlot, "bag")
	WM.AttachTooltip(attachSlot, function(tt)
		if GetSendMailItem() then
			tt:SetSendMailItem()
		else
			tt:SetText("Attachment — one item per mail on 1.12")
		end
	end)

	attachName = WM.CreateText(sc, 28)
	attachName:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(240))
	attachName:SetJustifyH("LEFT")
	attachName:SetWidth(WM.Px(700))
	WM.SingleLine(attachName, 28)

	local hint = WM.CreateText(sc, 22)
	hint:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(288))
	hint:SetJustifyH("LEFT")
	hint:SetWidth(WM.Px(700))
	hint:SetTextColor(0.6, 0.6, 0.65)
	hint:SetText("Tap a bag item below to attach it (long-press to split a stack first).")

	-- Money vs COD (mutually exclusive on 1.12).
	moneyModeBtns = {}
	local modes = {
		{ key = "none", label = "No money" },
		{ key = "money", label = "Send money" },
		{ key = "cod", label = "Request COD" },
	}
	for i = 1, 3 do
		local spec = modes[i]
		local b = WM.CreateTouchButton(sc, 312, 96, spec.label, 28)
		b:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px((i - 1) * 322), -WM.Px(360))
		b:SetScript("OnClick", function()
			moneyMode = spec.key
			RefreshSend()
		end)
		moneyModeBtns[spec.key] = b
	end

	moneyStepper = WM.CreateMoneyStepper(sc)
	moneyStepper:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -WM.Px(470))

	postageText = WM.CreateText(sc, 28)
	postageText:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(610))
	sendBtn = WM.CreateTouchButton(sc, 400, 110, "Send", 34)
	sendBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -WM.Px(586))
	sendBtn:SetScript("OnClick", DoSend)

	local bagsHeader = WM.CreateText(sc, 30)
	bagsHeader:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(724))
	bagsHeader:SetTextColor(1, 0.82, 0)
	bagsHeader:SetText("Your bags")
	sendGridTop = 776

	-- Detail overlay (reads one mail); FULLSCREEN_DIALOG via the shared
	-- overlay technique, built by hand because it needs its own scroller.
	detail = CreateFrame("Frame", "WowMobileMailDetail", sheet)
	detail:SetFrameStrata("FULLSCREEN_DIALOG")
	detail:SetAllPoints(sheet)
	detail:EnableMouse(true)
	WM.SkinFrame(detail, WM.Colors.panel, WM.Colors.accent)
	detail:Hide()

	detail.title = WM.CreateText(detail, 34)
	detail.title:SetPoint("TOPLEFT", detail, "TOPLEFT", WM.Px(24), -WM.Px(30))
	detail.title:SetJustifyH("LEFT")
	detail.title:SetWidth(WM.Px(860))
	WM.SingleLine(detail.title, 34)

	local back = WM.CreateTouchButton(detail, 160, 96, "Back", 30)
	back:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	back:SetScript("OnClick", CloseDetail)

	local detailContent = CreateFrame("Frame", nil, detail)
	detailContent:SetPoint("TOPLEFT", detail, "TOPLEFT", WM.Px(8), -WM.Px(104))
	detailContent:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -WM.Px(8), WM.Px(248))
	detailScroller = WM.Deck.CreateScroller(detailContent)
	detail.body = WM.CreateText(detailScroller.child, 28)
	detail.body:SetPoint("TOPLEFT", detailScroller.child, "TOPLEFT", WM.Px(4), -WM.Px(4))
	detail.body:SetJustifyH("LEFT")
	detail.body:SetWidth(WM.Px(940))

	detail.takeItem = WM.CreateTouchButton(detail, 516, 110, "Take item", 30)
	detail.takeItem:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", WM.Px(12), WM.Px(130))
	detail.takeItem:SetScript("OnClick", function()
		if not openMail then return end
		local index = openMail.index
		local _, _, _, _, _, cod = GetInboxHeaderInfo(index)
		if cod and cod > 0 then
			confirm.Ask("Taking this item pays the sender " ..
				WM.FormatMoney(cod) .. " (cash on delivery). Continue?",
				"Pay and take", function()
					TakeInboxItem(index)
				end)
		else
			TakeInboxItem(index)
		end
	end)
	detail.takeMoney = WM.CreateTouchButton(detail, 516, 110, "Take money", 30)
	detail.takeMoney:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -WM.Px(12), WM.Px(130))
	detail.takeMoney:SetScript("OnClick", function()
		if openMail then TakeInboxMoney(openMail.index) end
	end)
	detail.deleteBtn = WM.CreateTouchButton(detail, 516, 110, "Delete", 30)
	detail.deleteBtn:SetPoint("BOTTOMLEFT", detail, "BOTTOMLEFT", WM.Px(12), WM.Px(12))
	detail.deleteBtn:SetScript("OnClick", function()
		if not openMail then return end
		local index = openMail.index
		if this.isReturn then
			ReturnInboxItem(index)
			CloseDetail()
		else
			local _, _, _, _, money, _, _, hasItem = GetInboxHeaderInfo(index)
			local warn = (money and money > 0 or hasItem)
				and " Its money/item is destroyed with it!" or ""
			confirm.Ask("Delete this mail?" .. warn, "Delete", function()
				DeleteInboxItem(index)
				CloseDetail()
			end)
		end
	end)
	local closeDetail2 = WM.CreateTouchButton(detail, 516, 110, "Back to inbox", 30)
	closeDetail2:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -WM.Px(12), WM.Px(12))
	closeDetail2:SetScript("OnClick", CloseDetail)

	confirm = WM.CreateConfirmOverlay(sheet)

	WM.Deck.RegisterExclusive("mail", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("MAIL_SHOW", function()
		WM.Deck.YieldTo("mail")
		sheet:Show()
		SetCollecting(false)
		-- On 1.12 the inbox list only arrives in response to CheckInbox()
		-- (CMSG_GET_MAIL_LIST); the default UI's sole caller is MailFrame's
		-- MAIL_SHOW handler, which Blizzard.lua banishes with its events
		-- unregistered — so this sheet must request the list itself, or
		-- GetInboxNumItems() stays 0 and MAIL_INBOX_UPDATE never fires.
		lastInboxCheckAt = GetTime()
		CheckInbox()
		SetTab("inbox")
		inboxScroller.ScrollToTop()
		RenderInbox() -- renders whatever is cached; the update event re-renders
	end)
	WM.On("MAIL_CLOSED", function()
		SetCollecting(false)
		CloseDetail()
		sheet:Hide()
	end)
	WM.On("MAIL_INBOX_UPDATE", function()
		if not IsOpen() then return end
		RenderInbox()
		if openMail then
			-- Indices shift when an emptied mail auto-deletes; keep the
			-- overlay only while it still shows the same mail.
			local _, _, sender, subject = GetInboxHeaderInfo(openMail.index)
			if sender == openMail.sender and subject == openMail.subject then
				RefreshDetailButtons()
			else
				CloseDetail()
			end
		end
		if collecting and not CollectStep() then
			SetCollecting(false)
		end
	end)
	WM.On("MAIL_SEND_SUCCESS", function()
		recipientBox:SetText("")
		subjectBox:SetText("")
		moneyStepper.SetCopper(0)
		moneyMode = "none"
		RefreshSend()
		WM.Print("Mail sent.")
	end)
	WM.TryOn("MAIL_SEND_INFO_UPDATE", function()
		if IsOpen() then RefreshSend() end
	end)
	WM.On("BAG_UPDATE", function()
		if IsOpen() and tab == "send" then RenderSendBags() end
	end)
	WM.On("ITEM_LOCK_CHANGED", function()
		if IsOpen() and tab == "send" then RenderSendBags() end
	end)

	-- Collect-all watchdog: a step that never answers (bags full, server
	-- refusal — no MAIL_INBOX_UPDATE arrives) would leave the run armed
	-- forever; stop it after 3 s of silence. The same ticker re-requests the
	-- inbox on a coarse 10 s cadence while the sheet is open, so mail
	-- delivered while standing at the box surfaces (the CheckInbox rationale
	-- in the MAIL_SHOW handler; a fresh list answers with MAIL_INBOX_UPDATE).
	WM.Ticker(1, function()
		if not IsOpen() then return end
		if collecting and GetTime() - lastStepAt > 3 then
			SetCollecting(false)
			WM.Print("Mail: collect-all stopped (bags full?).")
		end
		if GetTime() - lastInboxCheckAt > 10 then
			lastInboxCheckAt = GetTime()
			CheckInbox()
		end
	end)
end)
