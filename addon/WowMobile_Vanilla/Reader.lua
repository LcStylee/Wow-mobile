--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Reader
-- Readable world objects, books, plaques and player letters (the ItemText
-- flow) as a deck bottom sheet with large text and big Prev / Next page
-- buttons — replacing the default ItemTextFrame (banished with events
-- unregistered in Blizzard.lua; its OnHide calls CloseItemText, so the
-- established suppression technique applies).
--
-- 1.12 ItemText API (vanilla FrameXML ItemTextFrame.lua — all of these are
-- core on this client):
--   ITEM_TEXT_BEGIN        — a readable object was opened; ItemTextGetItem()
--                            names it.
--   ITEM_TEXT_READY        — the current page's text is available:
--                            ItemTextGetText() (body, may embed |c colors),
--                            ItemTextGetCreator() (player letters),
--                            ItemTextHasNextPage() gates the Next button.
--   ITEM_TEXT_TRANSLATION  — arg1 = delay while a "translation" runs (some
--                            plaques); shown as a holding line.
--   ITEM_TEXT_CLOSED       — session over (walked away / server closed).
--   ItemTextPrevPage()/ItemTextNextPage() flip pages; a new ITEM_TEXT_READY
--   follows each flip. ItemTextGetPage() EXISTS on 1.12 (the FrameXML
--   ITEM_TEXT_READY handler calls it) and is the page-number authority here —
--   robust across re-reads like ITEM_TEXT_TRANSLATION; a local counter is
--   kept only as a fallback for odd builds lacking the call.
--   CloseItemText() ends the session (our X / exclusive hand-off).
--------------------------------------------------------------------------------

local WM = WowMobile

local sheet, scroller, titleText, bodyText, creatorText
local prevBtn, nextBtn, pageText
local page = 1

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

local function Layout()
	-- Single width-constrained FontString; its GetHeight() is the wrapped
	-- text height (the 1.12 idiom used by every text panel in this addon).
	scroller.SetContentHeight(bodyText:GetHeight() + WM.Px(24))
	scroller.ScrollToTop()
end

local function RenderReady()
	-- ItemTextGetPage() is authoritative on 1.12 (see header); the local
	-- counter kept by the page buttons is only the fallback.
	if ItemTextGetPage then
		page = ItemTextGetPage() or page
	end
	titleText:SetText(ItemTextGetItem() or "")
	local creator = ItemTextGetCreator and ItemTextGetCreator() or nil
	if creator and creator ~= "" then
		creatorText:SetText("written by " .. creator)
	else
		creatorText:SetText("")
	end
	bodyText:SetText(ItemTextGetText() or "")
	local hasNext = ItemTextHasNextPage()
	WM.SetButtonEnabled(nextBtn, hasNext and true or false)
	WM.SetButtonEnabled(prevBtn, page > 1)
	if page > 1 or hasNext then
		pageText:SetText("Page " .. page)
	else
		pageText:SetText("")
	end
	Layout()
end

local function Dismiss()
	CloseItemText()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileReaderSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetWidth(WM.Px(760))
	titleText:SetJustifyH("LEFT")
	WM.SingleLine(titleText, 40)

	creatorText = WM.CreateText(sheet, 24)
	creatorText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -WM.Px(2))
	creatorText:SetTextColor(0.65, 0.65, 0.7)

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	-- Text area above the page-button row (row height 96 + insets).
	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(132))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(116))
	scroller = WM.Deck.CreateScroller(content)

	-- Large-type body: 34 px physical — comfortable phone reading size.
	bodyText = WM.CreateText(scroller.child, 34)
	bodyText:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px(6), -WM.Px(6))
	bodyText:SetJustifyH("LEFT")
	bodyText:SetWidth(WM.Px(940))

	prevBtn = WM.CreateTouchButton(sheet, 330, 96, "< Prev page", 30)
	prevBtn:SetPoint("BOTTOMLEFT", sheet, "BOTTOMLEFT", WM.Px(8), WM.Px(10))
	prevBtn:SetScript("OnClick", function()
		if page > 1 then
			page = page - 1
			ItemTextPrevPage()
			-- ITEM_TEXT_READY renders the new page.
		end
	end)

	nextBtn = WM.CreateTouchButton(sheet, 330, 96, "Next page >", 30)
	nextBtn:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(10))
	nextBtn:SetScript("OnClick", function()
		if ItemTextHasNextPage() then
			page = page + 1
			ItemTextNextPage()
		end
	end)

	pageText = WM.CreateText(sheet, 28)
	pageText:SetPoint("BOTTOM", sheet, "BOTTOM", 0, WM.Px(42))
	pageText:SetTextColor(0.7, 0.7, 0.75)

	-- A deck panel / NPC sheet / map taking the stage closes the book too
	-- (CloseItemText is safe with no text open).
	WM.Deck.RegisterExclusive("reader", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("ITEM_TEXT_BEGIN", function()
		WM.Deck.YieldTo("reader")
		page = 1
		titleText:SetText(ItemTextGetItem() or "")
		creatorText:SetText("")
		bodyText:SetText("Loading...")
		pageText:SetText("")
		WM.SetButtonEnabled(prevBtn, false)
		WM.SetButtonEnabled(nextBtn, false)
		sheet:Show()
		Layout()
	end)
	WM.On("ITEM_TEXT_READY", function()
		if IsOpen() then RenderReady() end
	end)
	WM.TryOn("ITEM_TEXT_TRANSLATION", function()
		if IsOpen() then
			bodyText:SetText("Translating...")
			Layout()
		end
	end)
	WM.On("ITEM_TEXT_CLOSED", function()
		sheet:Hide()
	end)
end)
