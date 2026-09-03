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

-- Shared module state lives in ONE table, not in individual module-level
-- locals: Lua 5.0 caps a function at 32 upvalues AT COMPILE TIME, and the big
-- OnInit closure below (plus its nested handlers) captured ~39 individual
-- locals — the whole chunk failed to compile ("too many upvalues", field
-- failure at v0.3.3 Mail.lua:686) before the crash guard could even see the
-- module. Every closure now captures just M (and the local helper functions),
-- far below the limit; tools/lua50check.js counts upvalues per function to
-- keep it that way.
local M = {
	-- sheet, confirm, inboxArea, sendArea, inboxScroller, sendScroller,
	-- detail, detailScroller, tabInbox, tabSend, collectBtn, recipientBox,
	-- subjectBox, attachSlot, attachName, postageText, sendBtn,
	-- moneyModeBtns, moneyStepper, emptyText: widgets built in OnInit.
	tab = "inbox",           -- "inbox" | "send"
	moneyMode = "none",      -- "none" | "money" | "cod"
	openMail = nil,          -- { index, sender, subject } while the detail overlay is up
	collecting = false,
	lastStepAt = 0,
	lastInboxCheckAt = 0,
	inboxRows = {},
	sendCells = {},          -- "bag:slot" -> bag-grid cell
	sendGridTop = 0,         -- y where the send bag grid starts (set at init)
}

local function IsOpen()
	return M.sheet ~= nil and M.sheet:IsShown()
end

--------------------------------------------------------------------------------
-- Inbox list
--------------------------------------------------------------------------------

local OpenDetail -- forward

local function AcquireInboxRow(i)
	local row = M.inboxRows[i]
	if row then return row end
	row = WM.CreateTouchButton(M.inboxScroller.child, 100, ROW_H, nil, 30)
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
	M.inboxRows[i] = row
	return row
end

local function RenderInbox()
	if not IsOpen() or M.tab ~= "inbox" then return end
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
		row:SetPoint("TOPLEFT", M.inboxScroller.child, "TOPLEFT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetPoint("TOPRIGHT", M.inboxScroller.child, "TOPRIGHT",
			0, -WM.Px((i - 1) * (ROW_H + GAP)))
		row:SetHeight(WM.Px(ROW_H))
		row:Show()
	end
	for i = n + 1, table.getn(M.inboxRows) do
		M.inboxRows[i]:Hide()
	end
	WM.SetShown(M.emptyText, n == 0)
	M.inboxScroller.SetContentHeight(WM.Px(n * (ROW_H + GAP)))
end

--------------------------------------------------------------------------------
-- Detail overlay (read one mail)
--------------------------------------------------------------------------------

local function RefreshDetailButtons()
	if not M.openMail then return end
	local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(M.openMail.index)
	if hasItem then
		M.detail.takeItem.label:SetText((cod and cod > 0)
			and ("Take item (COD " .. WM.FormatMoney(cod) .. ")")
			or "Take item")
		WM.SetButtonEnabled(M.detail.takeItem, true)
	else
		M.detail.takeItem.label:SetText("No item")
		WM.SetButtonEnabled(M.detail.takeItem, false)
	end
	if money and money > 0 then
		M.detail.takeMoney.label:SetText("Take " .. WM.FormatMoney(money))
		WM.SetButtonEnabled(M.detail.takeMoney, true)
	else
		M.detail.takeMoney.label:SetText("No money")
		WM.SetButtonEnabled(M.detail.takeMoney, false)
	end
	if InboxItemCanDelete(M.openMail.index) then
		M.detail.deleteBtn.label:SetText("Delete")
		M.detail.deleteBtn.isReturn = nil
	else
		M.detail.deleteBtn.label:SetText("Return to sender")
		M.detail.deleteBtn.isReturn = true
	end
end

OpenDetail = function(index)
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	if not sender and not subject then return end
	M.openMail = { index = index, sender = sender, subject = subject }
	M.detail.title:SetText((sender or "?") .. " — " .. (subject or ""))
	-- GetInboxText marks the mail read server-side, like opening the letter.
	local body = GetInboxText(index)
	M.detail.body:SetText(body and body ~= "" and body or "|cff9999a3(no text)|r")
	M.detailScroller.SetContentHeight(M.detail.body:GetHeight() + WM.Px(24))
	M.detailScroller.ScrollToTop()
	RefreshDetailButtons()
	M.detail:Show()
end

local function CloseDetail()
	M.openMail = nil
	-- A confirm raised from this detail must not outlive the mail it refers
	-- to: the confirm overlay is a child of the SHEET (not the detail), so
	-- hiding the detail alone would leave a money-destructive "Pay and take"
	-- or "Delete" confirm standing after MAIL_INBOX_UPDATE has already
	-- decided the index no longer shows the same mail. Belt — the
	-- Confirm-time revalidation in each callback is the braces.
	if M.confirm then M.confirm:Hide() end
	M.detail:Hide()
end

--------------------------------------------------------------------------------
-- Collect all (see header: one Take* per inbox round-trip, COD skipped)
--------------------------------------------------------------------------------

local function SetCollecting(on)
	M.collecting = on
	M.collectBtn.label:SetText(on and "Stop" or "Collect all")
end

local function CollectStep()
	for i = 1, GetInboxNumItems() do
		local _, _, _, _, money, cod, _, hasItem = GetInboxHeaderInfo(i)
		if money and money > 0 then
			M.lastStepAt = GetTime()
			TakeInboxMoney(i)
			return true
		end
		if hasItem and (not cod or cod == 0) then
			M.lastStepAt = GetTime()
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
	if not M.sendArea then return end
	local itemName, itemTexture, itemCount = GetSendMailItem()
	if itemName then
		M.attachSlot.icon:SetTexture(itemTexture or WM.TEX_QUESTION)
		M.attachSlot.icon:SetVertexColor(1, 1, 1)
		M.attachName:SetText(itemName ..
			(itemCount and itemCount > 1 and (" x" .. itemCount) or ""))
	else
		M.attachSlot.icon:SetTexture(WM.TEX_WHITE)
		M.attachSlot.icon:SetVertexColor(0.12, 0.12, 0.14)
		M.attachName:SetText("|cff9999a3No attachment|r")
	end
	for mode, b in pairs(M.moneyModeBtns) do
		if mode == M.moneyMode then
			WM.TintBorder(b, WM.Colors.accent)
		else
			WM.TintBorder(b, WM.Colors.border)
		end
	end
	local ok, price = pcall(GetSendMailPrice)
	M.postageText:SetText("Postage: " .. WM.FormatMoney(ok and price or 30))
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
	local cell = CreateFrame("Button", nil, M.sendScroller.child)
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
	if not IsOpen() or M.tab ~= "send" then return end
	local index = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			index = index + 1
			local key = bag .. ":" .. slot
			local cell = M.sendCells[key]
			if not cell then
				cell = CreateSendCell(bag, slot)
				M.sendCells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", M.sendScroller.child, "TOPLEFT",
				WM.Px(col * (CELL + GAP)), -WM.Px(M.sendGridTop + row * (CELL + GAP)))
			UpdateSendCell(cell)
			cell:Show()
		end
	end
	-- Hide cells whose bag/slot no longer exists (a bag was swapped out).
	for _, cell in pairs(M.sendCells) do
		if cell.slot > GetContainerNumSlots(cell.bag) then
			cell:Hide()
		end
	end
	M.sendScroller.SetContentHeight(
		WM.Px(M.sendGridTop + math.ceil(index / COLS) * (CELL + GAP) + 8))
end

local function DoSend()
	local to = M.recipientBox:GetText()
	if not to or to == "" then
		WM.Print("Mail: enter a recipient first.")
		return
	end
	local itemName = GetSendMailItem()
	local subject = M.subjectBox:GetText()
	if not subject or subject == "" then
		subject = itemName or "(No subject)"
	end
	if M.moneyMode == "cod" then
		if not itemName then
			WM.Print("Mail: COD needs an attached item.")
			return
		end
		if M.moneyStepper.GetCopper() == 0 then
			WM.Print("Mail: set a COD amount first.")
			return
		end
		SetSendMailCOD(M.moneyStepper.GetCopper())
	elseif M.moneyMode == "money" then
		SetSendMailMoney(M.moneyStepper.GetCopper())
	else
		SetSendMailMoney(0)
	end
	SendMail(to, subject, "")
end

--------------------------------------------------------------------------------
-- Tabs / lifecycle
--------------------------------------------------------------------------------

local function SetTab(t)
	M.tab = t
	M.recipientBox:ClearFocus()
	M.subjectBox:ClearFocus()
	WM.SetShown(M.inboxArea, t == "inbox")
	WM.SetShown(M.sendArea, t == "send")
	WM.SetShown(M.collectBtn, t == "inbox")
	WM.TintBorder(M.tabInbox, t == "inbox" and WM.Colors.accent or WM.Colors.border)
	WM.TintBorder(M.tabSend, t == "send" and WM.Colors.accent or WM.Colors.border)
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
	M.sheet:Hide()
end

WM.OnInit(function()
	M.sheet = CreateFrame("Frame", "WowMobileMailSheet", UIParent)
	M.sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	M.sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	M.sheet:SetFrameStrata("DIALOG")
	M.sheet:EnableMouse(true)
	WM.SkinFrame(M.sheet, WM.Colors.panel)
	M.sheet:Hide()

	local titleText = WM.CreateText(M.sheet, 40)
	titleText:SetPoint("TOPLEFT", M.sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Mail")

	local close = WM.CreateTouchButton(M.sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", M.sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	local content = CreateFrame("Frame", nil, M.sheet)
	content:SetPoint("TOPLEFT", M.sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", M.sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))

	-- Tab row + Collect all.
	M.tabInbox = WM.CreateTouchButton(content, 280, 96, "Inbox", 30)
	M.tabInbox:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
	M.tabInbox:SetScript("OnClick", function() SetTab("inbox") end)
	M.tabSend = WM.CreateTouchButton(content, 280, 96, "Send", 30)
	M.tabSend:SetPoint("LEFT", M.tabInbox, "RIGHT", WM.Px(8), 0)
	M.tabSend:SetScript("OnClick", function() SetTab("send") end)
	M.collectBtn = WM.CreateTouchButton(content, 340, 96, "Collect all", 30)
	M.collectBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
	M.collectBtn:SetScript("OnClick", function()
		if M.collecting then
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
	M.inboxArea = CreateFrame("Frame", nil, content)
	M.inboxArea:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -WM.Px(108))
	M.inboxArea:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
	M.inboxScroller = WM.Deck.CreateScroller(M.inboxArea)
	M.emptyText = WM.CreateText(M.inboxArea, 30)
	M.emptyText:SetPoint("TOPLEFT", M.inboxArea, "TOPLEFT", WM.Px(8), -WM.Px(20))
	M.emptyText:SetText("No mail.")
	M.emptyText:SetTextColor(0.7, 0.7, 0.75)
	M.emptyText:Hide()

	-- Send area: every control lives in the scroller so the bag grid below
	-- stays reachable on short decks.
	M.sendArea = CreateFrame("Frame", nil, content)
	M.sendArea:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -WM.Px(108))
	M.sendArea:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
	M.sendArea:Hide()
	M.sendScroller = WM.Deck.CreateScroller(M.sendArea)
	local sc = M.sendScroller.child

	local toLabel = WM.CreateText(sc, 30)
	toLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(30))
	toLabel:SetText("To")
	M.recipientBox = WM.CreateEditBox(sc, 780, 90, 12) -- character names cap at 12
	M.recipientBox:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(170), 0)

	local subjLabel = WM.CreateText(sc, 30)
	subjLabel:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(130))
	subjLabel:SetText("Subject")
	M.subjectBox = WM.CreateEditBox(sc, 780, 90, 64)
	M.subjectBox:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(170), -WM.Px(100))

	-- The one attachment slot (see header). Carry-tap places; a plain tap on
	-- a filled slot returns the item to its bag.
	M.attachSlot = CreateFrame("Button", nil, sc)
	M.attachSlot:SetWidth(WM.Px(130))
	M.attachSlot:SetHeight(WM.Px(130))
	M.attachSlot:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(210))
	WM.SkinFrame(M.attachSlot, { 0.07, 0.07, 0.09, 1 })
	local ahl = M.attachSlot:CreateTexture(nil, "HIGHLIGHT")
	ahl:SetAllPoints(M.attachSlot)
	ahl:SetTexture(1, 1, 1, 0.10)
	M.attachSlot.icon = M.attachSlot:CreateTexture(nil, "ARTWORK")
	M.attachSlot.icon:SetPoint("TOPLEFT", M.attachSlot, "TOPLEFT", WM.Px(6), -WM.Px(6))
	M.attachSlot.icon:SetPoint("BOTTOMRIGHT", M.attachSlot, "BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
	M.attachSlot:SetScript("OnClick", function()
		if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
			ClickSendMailItemButton()
			WM.MoveMode.NoteSlotDrop()
		elseif GetSendMailItem() then
			ClickSendMailItemButton() -- lift it off the mail...
			ClearCursor()             -- ...and home to its bag slot
		end
		RefreshSend()
	end)
	WM.MoveMode.MakeTarget(M.attachSlot, "bag")
	WM.AttachTooltip(M.attachSlot, function(tt)
		if GetSendMailItem() then
			tt:SetSendMailItem()
		else
			tt:SetText("Attachment — one item per mail on 1.12")
		end
	end)

	M.attachName = WM.CreateText(sc, 28)
	M.attachName:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(240))
	M.attachName:SetJustifyH("LEFT")
	M.attachName:SetWidth(WM.Px(700))
	WM.SingleLine(M.attachName, 28)

	local hint = WM.CreateText(sc, 22)
	hint:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(150), -WM.Px(288))
	hint:SetJustifyH("LEFT")
	hint:SetWidth(WM.Px(700))
	hint:SetTextColor(0.6, 0.6, 0.65)
	hint:SetText("Tap a bag item below to attach it (long-press to split a stack first).")

	-- Money vs COD (mutually exclusive on 1.12).
	M.moneyModeBtns = {}
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
			M.moneyMode = spec.key
			RefreshSend()
		end)
		M.moneyModeBtns[spec.key] = b
	end

	M.moneyStepper = WM.CreateMoneyStepper(sc)
	M.moneyStepper:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -WM.Px(470))

	M.postageText = WM.CreateText(sc, 28)
	M.postageText:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(610))
	M.sendBtn = WM.CreateTouchButton(sc, 400, 110, "Send", 34)
	M.sendBtn:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, -WM.Px(586))
	M.sendBtn:SetScript("OnClick", DoSend)

	local bagsHeader = WM.CreateText(sc, 30)
	bagsHeader:SetPoint("TOPLEFT", sc, "TOPLEFT", WM.Px(4), -WM.Px(724))
	bagsHeader:SetTextColor(1, 0.82, 0)
	bagsHeader:SetText("Your bags")
	M.sendGridTop = 776

	-- Detail overlay (reads one mail); FULLSCREEN_DIALOG via the shared
	-- overlay technique, built by hand because it needs its own scroller.
	M.detail = CreateFrame("Frame", "WowMobileMailDetail", M.sheet)
	M.detail:SetFrameStrata("FULLSCREEN_DIALOG")
	M.detail:SetAllPoints(M.sheet)
	M.detail:EnableMouse(true)
	WM.SkinFrame(M.detail, WM.Colors.panel, WM.Colors.accent)
	M.detail:Hide()

	M.detail.title = WM.CreateText(M.detail, 34)
	M.detail.title:SetPoint("TOPLEFT", M.detail, "TOPLEFT", WM.Px(24), -WM.Px(30))
	M.detail.title:SetJustifyH("LEFT")
	M.detail.title:SetWidth(WM.Px(860))
	WM.SingleLine(M.detail.title, 34)

	local back = WM.CreateTouchButton(M.detail, 160, 96, "Back", 30)
	back:SetPoint("TOPRIGHT", M.detail, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	back:SetScript("OnClick", CloseDetail)

	local detailContent = CreateFrame("Frame", nil, M.detail)
	detailContent:SetPoint("TOPLEFT", M.detail, "TOPLEFT", WM.Px(8), -WM.Px(104))
	detailContent:SetPoint("BOTTOMRIGHT", M.detail, "BOTTOMRIGHT", -WM.Px(8), WM.Px(248))
	M.detailScroller = WM.Deck.CreateScroller(detailContent)
	M.detail.body = WM.CreateText(M.detailScroller.child, 28)
	M.detail.body:SetPoint("TOPLEFT", M.detailScroller.child, "TOPLEFT", WM.Px(4), -WM.Px(4))
	M.detail.body:SetJustifyH("LEFT")
	M.detail.body:SetWidth(WM.Px(940))

	M.detail.takeItem = WM.CreateTouchButton(M.detail, 516, 110, "Take item", 30)
	M.detail.takeItem:SetPoint("BOTTOMLEFT", M.detail, "BOTTOMLEFT", WM.Px(12), WM.Px(130))
	M.detail.takeItem:SetScript("OnClick", function()
		if not M.openMail then return end
		local index, sender, subject = M.openMail.index, M.openMail.sender, M.openMail.subject
		local _, _, _, _, _, cod = GetInboxHeaderInfo(index)
		if cod and cod > 0 then
			M.confirm.Ask("Taking this item pays the sender " ..
				WM.FormatMoney(cod) .. " (cash on delivery). Continue?",
				"Pay and take", function()
					-- Confirm-time revalidation (the AuctionHouse.lua pattern):
					-- inbox indices shift while the confirm is up — an emptied
					-- mail auto-deletes, a background collect-all step removes
					-- mails, and the 10 s CheckInbox re-request surfaces newly
					-- delivered mail at the top of the newest-first list. Pay
					-- only if this index still holds the SAME mail with the
					-- SAME COD amount; otherwise abort with nothing spent.
					local _, _, sNow, jNow, _, codNow = GetInboxHeaderInfo(index)
					if sNow ~= sender or jNow ~= subject or codNow ~= cod then
						WM.Print("Mail: inbox changed — nothing was paid. Reopen the mail and retry.")
						CloseDetail()
						return
					end
					TakeInboxItem(index)
				end)
		else
			TakeInboxItem(index)
		end
	end)
	M.detail.takeMoney = WM.CreateTouchButton(M.detail, 516, 110, "Take money", 30)
	M.detail.takeMoney:SetPoint("BOTTOMRIGHT", M.detail, "BOTTOMRIGHT", -WM.Px(12), WM.Px(130))
	M.detail.takeMoney:SetScript("OnClick", function()
		if not M.openMail then return end
		-- Same confirm-time revalidation as take-item/delete: an index shift
		-- (auto-deleted emptied mail, background collect, the 10 s refresh)
		-- must not loot a different letter's money.
		local index = M.openMail.index
		local _, _, sender, subject = GetInboxHeaderInfo(index)
		if sender ~= M.openMail.sender or subject ~= M.openMail.subject then
			WM.Print("Your inbox changed — reopen the mail and retry.")
			return
		end
		TakeInboxMoney(index)
	end)
	M.detail.deleteBtn = WM.CreateTouchButton(M.detail, 516, 110, "Delete", 30)
	M.detail.deleteBtn:SetPoint("BOTTOMLEFT", M.detail, "BOTTOMLEFT", WM.Px(12), WM.Px(12))
	M.detail.deleteBtn:SetScript("OnClick", function()
		if not M.openMail then return end
		local index, sender, subject = M.openMail.index, M.openMail.sender, M.openMail.subject
		if this.isReturn then
			ReturnInboxItem(index)
			CloseDetail()
		else
			local _, _, _, _, money, _, _, hasItem = GetInboxHeaderInfo(index)
			local warn = (money and money > 0 or hasItem)
				and " Its money/item is destroyed with it!" or ""
			M.confirm.Ask("Delete this mail?" .. warn, "Delete", function()
				-- Confirm-time revalidation — same rationale as the COD path
				-- above: indices shift while the confirm is up, and a blind
				-- DeleteInboxItem would destroy a DIFFERENT mail's money/item.
				-- money/hasItem are compared too: sender+subject alone can't
				-- tell apart look-alike mails (two AH sale notices), same as
				-- the AH cancel path comparing prices, not just names.
				local _, _, sNow, jNow, mNow, _, _, hNow = GetInboxHeaderInfo(index)
				if sNow ~= sender or jNow ~= subject
					or mNow ~= money or (not hNow) ~= (not hasItem) then
					WM.Print("Mail: inbox changed — nothing was deleted. Reopen the mail and retry.")
					CloseDetail()
					return
				end
				DeleteInboxItem(index)
				CloseDetail()
			end)
		end
	end)
	local closeDetail2 = WM.CreateTouchButton(M.detail, 516, 110, "Back to inbox", 30)
	closeDetail2:SetPoint("BOTTOMRIGHT", M.detail, "BOTTOMRIGHT", -WM.Px(12), WM.Px(12))
	closeDetail2:SetScript("OnClick", CloseDetail)

	M.confirm = WM.CreateConfirmOverlay(M.sheet)

	WM.Deck.RegisterExclusive("mail", function()
		if M.sheet:IsShown() then Dismiss() end
	end)

	WM.On("MAIL_SHOW", function()
		WM.Deck.YieldTo("mail")
		M.sheet:Show()
		SetCollecting(false)
		-- On 1.12 the inbox list only arrives in response to CheckInbox()
		-- (CMSG_GET_MAIL_LIST); the default UI's sole caller is MailFrame's
		-- MAIL_SHOW handler, which Blizzard.lua banishes with its events
		-- unregistered — so this sheet must request the list itself, or
		-- GetInboxNumItems() stays 0 and MAIL_INBOX_UPDATE never fires.
		M.lastInboxCheckAt = GetTime()
		CheckInbox()
		SetTab("inbox")
		M.inboxScroller.ScrollToTop()
		RenderInbox() -- renders whatever is cached; the update event re-renders
	end)
	WM.On("MAIL_CLOSED", function()
		SetCollecting(false)
		CloseDetail()
		M.sheet:Hide()
	end)
	WM.On("MAIL_INBOX_UPDATE", function()
		if not IsOpen() then return end
		RenderInbox()
		if M.openMail then
			-- Indices shift when an emptied mail auto-deletes; keep the
			-- overlay only while it still shows the same mail.
			local _, _, sender, subject = GetInboxHeaderInfo(M.openMail.index)
			if sender == M.openMail.sender and subject == M.openMail.subject then
				RefreshDetailButtons()
			else
				CloseDetail()
			end
		end
		if M.collecting and not CollectStep() then
			SetCollecting(false)
		end
	end)
	WM.On("MAIL_SEND_SUCCESS", function()
		M.recipientBox:SetText("")
		M.subjectBox:SetText("")
		M.moneyStepper.SetCopper(0)
		M.moneyMode = "none"
		RefreshSend()
		WM.Print("Mail sent.")
	end)
	WM.TryOn("MAIL_SEND_INFO_UPDATE", function()
		if IsOpen() then RefreshSend() end
	end)
	WM.On("BAG_UPDATE", function()
		if IsOpen() and M.tab == "send" then RenderSendBags() end
	end)
	WM.On("ITEM_LOCK_CHANGED", function()
		if IsOpen() and M.tab == "send" then RenderSendBags() end
	end)

	-- Collect-all watchdog: a step that never answers (bags full, server
	-- refusal — no MAIL_INBOX_UPDATE arrives) would leave the run armed
	-- forever; stop it after 3 s of silence. The same ticker re-requests the
	-- inbox on a coarse 10 s cadence while the sheet is open, so mail
	-- delivered while standing at the box surfaces (the CheckInbox rationale
	-- in the MAIL_SHOW handler; a fresh list answers with MAIL_INBOX_UPDATE).
	WM.Ticker(1, function()
		if not IsOpen() then return end
		if M.collecting and GetTime() - M.lastStepAt > 3 then
			SetCollecting(false)
			WM.Print("Mail: collect-all stopped (bags full?).")
		end
		if GetTime() - M.lastInboxCheckAt > 10 then
			M.lastInboxCheckAt = GetTime()
			CheckInbox()
		end
	end)
end)
