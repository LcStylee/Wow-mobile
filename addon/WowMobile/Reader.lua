--------------------------------------------------------------------------------
-- WowMobile · Reader
-- Readable world objects, books and letters (the ItemText API) as a
-- deck-covering sheet with large text and big Prev/Next page buttons. The
-- default ItemTextFrame is banished in Blizzard.lua (its OnHide calls
-- CloseItemText — classic_era ItemTextFrame.xml — which would end the
-- reading session; banished it never opens, so this module owns the flow):
--   ITEM_TEXT_BEGIN  → open the sheet, title = ItemTextGetItem()
--   ITEM_TEXT_READY  → render ItemTextGetText() (+ ItemTextGetCreator() for
--                      player-written letters) at the current page
--                      (ItemTextGetPage / ItemTextHasNextPage)
--   ITEM_TEXT_TRANSLATION → "translating" hold (arg = ms), then READY fires
--   ITEM_TEXT_CLOSED → hide
-- Paging is async: ItemTextPrevPage/ItemTextNextPage request the page and a
-- new ITEM_TEXT_READY renders it. The parchment material fonts/colors of the
-- default frame are deliberately dropped — the deck's dark theme with 34 px
-- text is the whole point of a phone reader.
--------------------------------------------------------------------------------

local _, WM = ...

local sheet, scroller, st
local prevBtn, nextBtn, pageText

local function RenderPage()
	if not sheet:IsShown() then return end
	st.Reset()

	local body = ItemTextGetText()
	if body and body ~= "" then
		-- 34 px body text. (The stack's own 6 px line spacing stays as-is:
		-- changing it after st.Text would invalidate the height the stack
		-- already measured and overlap the lines below.)
		st.Text(body, 34)
	else
		st.Text("(This page is empty.)", 30, 0.7, 0.7, 0.75)
	end

	local creator = ItemTextGetCreator and ItemTextGetCreator()
	if creator and creator ~= "" then
		st.Text("— " .. creator, 28, 0.7, 0.7, 0.75)
	end

	local page = (ItemTextGetPage and ItemTextGetPage()) or 1
	local hasNext = ItemTextHasNextPage and ItemTextHasNextPage()
	pageText:SetText("Page " .. page)
	WM.SetButtonEnabled(prevBtn, page > 1)
	WM.SetButtonEnabled(nextBtn, hasNext and true or false)

	-- Every READY is a fresh page: always start reading at the top.
	st.Finish(nil)
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("reader", "Reading")
	sheet.OnDismiss = function()
		CloseItemText() -- ITEM_TEXT_CLOSED then hides the sheet
	end

	-- Page controls pinned at the bottom of the sheet body; the text scroller
	-- gets the region above them.
	local controls = CreateFrame("Frame", nil, sheet.body)
	controls:SetPoint("BOTTOMLEFT")
	controls:SetPoint("BOTTOMRIGHT")
	controls:SetHeight(WM.Px(100))

	prevBtn = WM.CreateTouchButton(controls, 380, 100, "< Previous page", 30)
	prevBtn:SetPoint("LEFT")
	prevBtn:SetScript("OnClick", function()
		ItemTextPrevPage() -- async; the resulting ITEM_TEXT_READY renders
	end)

	pageText = WM.CreateText(controls, 28)
	pageText:SetPoint("CENTER")
	pageText:SetTextColor(0.7, 0.7, 0.75)

	nextBtn = WM.CreateTouchButton(controls, 380, 100, "Next page >", 30)
	nextBtn:SetPoint("RIGHT")
	nextBtn:SetScript("OnClick", function()
		ItemTextNextPage()
	end)

	local textArea = CreateFrame("Frame", nil, sheet.body)
	textArea:SetPoint("TOPLEFT")
	textArea:SetPoint("BOTTOMRIGHT", controls, "TOPRIGHT", 0, WM.Px(10))
	scroller = WM.Deck.CreateScroller(textArea)
	st = Kit.NewStack(scroller)

	WM.On("ITEM_TEXT_BEGIN", function()
		sheet.Open(ItemTextGetItem() or "Reading")
		-- No valid page exists between BEGIN and READY (and on a first-ever
		-- open the buttons default enabled): disable both so a tap cannot
		-- issue a pageless ItemTextPrev/NextPage, as the default UI does.
		WM.SetButtonEnabled(prevBtn, false)
		WM.SetButtonEnabled(nextBtn, false)
		pageText:SetText("")
		st.Reset()
		st.Text("Loading...", 30, 0.7, 0.7, 0.75)
		st.Finish(nil)
	end)
	WM.On("ITEM_TEXT_READY", RenderPage)
	WM.TryOn("ITEM_TEXT_TRANSLATION", function()
		-- Ancient-tongue objects: the server holds the text briefly.
		st.Reset()
		st.Text("Translating...", 30, 0.7, 0.7, 0.75)
		st.Finish(nil)
	end)
	WM.On("ITEM_TEXT_CLOSED", function()
		if sheet:IsShown() then sheet:Hide() end
		st.ClearView()
	end)
end)
