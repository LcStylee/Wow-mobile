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
-- new ITEM_TEXT_READY renders it. Bodies come in TWO kinds on this client:
-- plain strings (letters, simple signs) and HTML book markup — the default
-- UI's ItemTextPageText is a SimpleHTML widget (classic_era ItemTextFrame.xml)
-- precisely because books/plaques serve '<HTML><BODY><P>...' pages — so
-- RenderPage routes HTML bodies through a SimpleHTML child with the deck
-- fonts mapped onto P/H1-H3 instead of showing tag soup in a FontString.
-- The parchment material art of the default frame is deliberately dropped —
-- the deck's dark theme with 34 px text is the whole point of a phone reader.
--------------------------------------------------------------------------------

local _, WM = ...

local sheet, scroller, st
local prevBtn, nextBtn, pageText
local htmlView -- SimpleHTML page renderer, placed into the stack via Anchor

-- The default ItemTextFrame decides plain vs HTML the same way SimpleHTML
-- itself does: a body opening with an <HTML> tag is markup, anything else is
-- plain text (SetText on a plain string renders it verbatim).
local function IsHtmlBody(body)
	return body:match("^%s*<[Hh][Tt][Mm][Ll]") ~= nil
end

-- Last-ditch fallback for a client build whose SimpleHTML lacks
-- GetContentHeight (needed to size the widget into the stack flow): strip the
-- markup and render the words plain. Header sizing, alignment and inline
-- <IMG> art are lost — accepted, words beat tag soup — and the path is
-- unused on 1.15, whose 10.x-engine SimpleHTML has GetContentHeight.
local function StripHtml(body)
	body = body:gsub("<[Bb][Rr]%s*/?>", "\n")
	body = body:gsub("</[Pp]>", "\n\n"):gsub("</[Hh][123]>", "\n\n")
	body = body:gsub("<[^>]->", "")
	body = body:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">")
	body = body:gsub("&quot;", "\""):gsub("&amp;", "&")
	return body
end

local function RenderPage()
	if not sheet:IsShown() then return end
	st.Reset()

	local body = ItemTextGetText()
	if body and body ~= "" then
		if IsHtmlBody(body) and htmlView.GetContentHeight then
			-- Book page: SimpleHTML with the deck fonts on every element the
			-- era book markup uses. Fonts/spacing re-applied per render so a
			-- viewport rescale (/wm viewport) re-sizes book text exactly like
			-- st.Text does via WM.SetFont.
			htmlView:SetFont("p", STANDARD_TEXT_FONT, WM.Px(34), "")
			htmlView:SetFont("h1", STANDARD_TEXT_FONT, WM.Px(46), "")
			htmlView:SetFont("h2", STANDARD_TEXT_FONT, WM.Px(42), "")
			htmlView:SetFont("h3", STANDARD_TEXT_FONT, WM.Px(38), "")
			htmlView:SetSpacing("p", WM.Px(6))
			-- Width before SetText (wrapping), height from the laid-out
			-- content after — then hand the measured design-px height to the
			-- stack (the st.Text GetStringHeight technique). Show() first:
			-- st.Reset hid the widget, and while FontString-style widgets
			-- usually lay out lazily on query, nothing guarantees SimpleHTML
			-- computes content height while hidden — showing before the
			-- measurement is free (st.Anchor re-points it anyway) and removes
			-- the assumption. If the measurement still comes back 0, fall
			-- through to the plain-text StripHtml path instead of rendering a
			-- zero-height invisible page.
			htmlView:Show()
			htmlView:SetWidth(scroller.ContentWidth() - WM.Px(8))
			htmlView:SetText(body)
			local hPx = htmlView:GetContentHeight() / WM.Px(1)
			if hPx > 0 then
				htmlView:SetHeight(WM.Px(hPx))
				st.Anchor(htmlView, hPx)
			else
				htmlView:Hide()
				st.Text(StripHtml(body), 34)
			end
		elseif IsHtmlBody(body) then
			st.Text(StripHtml(body), 34)
		else
			-- 34 px body text. (The stack's own 6 px line spacing stays as-is:
			-- changing it after st.Text would invalidate the height the stack
			-- already measured and overlap the lines below.)
			st.Text(body, 34)
		end
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

	-- One persistent SimpleHTML child for book pages (see RenderPage). Placed
	-- through st.Anchor, so st.Reset hides it whenever a render skips it.
	-- Colors are viewport-independent and set once; fonts are per-render.
	htmlView = CreateFrame("SimpleHTML", nil, scroller.child)
	-- Provisional anchor so the widget owns a rect before the first render's
	-- SetText/GetContentHeight measurement (a point-less frame lays out
	-- nothing); st.Anchor ClearAllPoints+re-points it on every render.
	htmlView:SetPoint("TOPLEFT")
	htmlView:SetTextColor("p", 0.92, 0.92, 0.92)
	htmlView:SetTextColor("h1", 1, 0.82, 0)
	htmlView:SetTextColor("h2", 1, 0.82, 0)
	htmlView:SetTextColor("h3", 1, 0.82, 0)
	htmlView:Hide()

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
