--------------------------------------------------------------------------------
-- WowMobile · SheetKit
-- Shared infrastructure for the economy interaction sheets (AuctionHouse /
-- Crafting / Mail / Bank / Trade), all of which replace default frames that
-- were only scale-boosted in round 1:
--   * CreateSheet — deck-covering DIALOG sheet wired into Deck's exclusive
--     system with an optional tab row (the BottomSheet.lua pattern, factored),
--   * NewStack — the pooled top-down layout builder (text / big buttons /
--     button rows / 2-column item cells) generalized from BottomSheet.lua,
--     plus Anchor() for placing persistent widgets (steppers, edit boxes)
--     into the same flow,
--   * CreateMoneyStepper / CreateStepper — tap-only numeric entry (the client
--     maps a deck press-and-hold to a right click, ARCHITECTURE §5, so
--     hold-to-repeat is impossible; a step-multiplier cycle button makes
--     large amounts reachable in a few taps),
--   * CreateTextField — big EditBox for the phone-keyboard entry pattern
--     (tap focuses; the streaming client's keyboard delivers real keystrokes
--     into the focused box, same as the rescued chat edit box in Chat.lua),
--   * NewBagList — pooled picker of everything in the player's bags, the
--     "put an item here" source every economy sheet shares with MoveMode.
--------------------------------------------------------------------------------

local _, WM = ...

local Kit = {}
WM.SheetKit = Kit

local TITLE_H = 104 -- matches Deck.CreatePanel / BottomSheet title bars
local TAB_H = 96
local BUTTON_H = 100
local CELL_H = 116
local GAP = 10

function Kit.QualityName(name, quality)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q and name then
		return string.format("|cff%02x%02x%02x%s|r", q.r * 255, q.g * 255, q.b * 255, name)
	end
	return name
end

-- Every economy-sheet cursor mutation funnels through this guard: the move
-- rules (MoveMode.lua) demand item moves never run in combat — notice, no
-- silently queued state, ever.
function Kit.CanMove()
	if InCombatLockdown() then
		UIErrorsFrame:AddMessage("Items can't be moved during combat.", 1, 0.3, 0.3)
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Sheet factory
-- Deck-covering interaction sheet on the DIALOG strata, registered in Deck's
-- exclusive system under `key`. The module sets sheet.OnDismiss to the
-- walk-away API call (CloseMail, CancelTrade, ...); the X button — and any
-- panel/map/other sheet taking the stage — routes through it, and the
-- server's *_CLOSED event is then what actually hides the sheet, exactly
-- like BottomSheet.lua's Dismiss flow.
--------------------------------------------------------------------------------

function Kit.CreateSheet(key, defaultTitle, tabs)
	local sheet = CreateFrame("Frame", "WowMobileSheet_" .. key, UIParent)
	sheet:SetAllPoints(WM.Deck)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true) -- swallow taps meant for the deck below
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	sheet.titleText = WM.CreateText(sheet, 40)
	sheet.titleText:SetPoint("TOPLEFT", WM.Px(24), -WM.Px(26))
	sheet.titleText:SetWidth(WM.Px(860))
	sheet.titleText:SetJustifyH("LEFT")
	sheet.titleText:SetWordWrap(false)

	-- 100x96: >=90 px touch targets (ARCHITECTURE §4).
	local close = WM.CreateTouchButton(sheet, 100, TITLE_H - 8, "X", 44)
	close:SetPoint("TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", function()
		if sheet.OnDismiss then sheet.OnDismiss() end
	end)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(TITLE_H))
	content:SetPoint("BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	sheet.content = content
	sheet.body = content -- the region below the (optional) tab row

	if tabs then
		local row = CreateFrame("Frame", nil, content)
		row:SetPoint("TOPLEFT")
		row:SetPoint("TOPRIGHT")
		row:SetHeight(WM.Px(TAB_H))

		local body = CreateFrame("Frame", nil, content)
		body:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -WM.Px(GAP))
		body:SetPoint("BOTTOMRIGHT")
		sheet.body = body
		sheet.tabFrames = {}

		local buttons = {}
		local n = #tabs
		local w = (1064 - GAP * (n - 1)) / n -- content is 1064 design px wide
		for i = 1, n do
			local tab = tabs[i]
			local f = CreateFrame("Frame", nil, body)
			f:SetAllPoints()
			f:Hide()
			sheet.tabFrames[tab.key] = f
			local b = WM.CreateTouchButton(row, w, TAB_H, tab.label, 30)
			b:SetPoint("TOPLEFT", WM.Px((i - 1) * (w + GAP)), 0)
			b:SetScript("OnClick", function() sheet.SelectTab(tab.key) end)
			buttons[tab.key] = b
		end

		function sheet.SelectTab(k)
			sheet.activeTab = k
			for tk, f in pairs(sheet.tabFrames) do
				f:SetShown(tk == k)
			end
			for tk, b in pairs(buttons) do
				local c = (tk == k) and WM.Colors.accent or WM.Colors.border
				b.borderTex:SetColorTexture(c[1], c[2], c[3], 1)
			end
			if sheet.OnTabShow then sheet.OnTabShow(k) end
		end
	end

	WM.Deck.RegisterExclusive(key, function()
		if sheet:IsShown() and sheet.OnDismiss then sheet.OnDismiss() end
	end)

	function sheet.Open(title)
		WM.Deck.YieldTo(key) -- panels, map and other sheets step aside
		sheet.titleText:SetText(title or defaultTitle)
		sheet:Show()
	end

	return sheet
end

--------------------------------------------------------------------------------
-- Stack builder
-- Pooled top-down layout over a Deck scroller — BottomSheet.lua's
-- text/button/cell machinery factored out so each economy sheet does not
-- re-implement it. All coordinates in design px; rebuilds are event-driven
-- and reuse the pools, so steady state allocates nothing.
--------------------------------------------------------------------------------

function Kit.NewStack(scroller)
	local st = {}
	local pools = { text = {}, button = {}, cell = {} }
	local used = { text = 0, button = 0, cell = 0 }
	local placed = {} -- persistent widgets positioned by Anchor this render
	local y = 0
	local lastView

	local function WidthPx()
		return scroller.ContentWidth() / WM.Px(1)
	end

	function st.Y() return y end
	function st.Skip(px) y = y + px end

	function st.Reset()
		used.text, used.button, used.cell = 0, 0, 0
		for _, pool in pairs(pools) do
			for i = 1, #pool do pool[i]:Hide() end
		end
		for i = #placed, 1, -1 do
			local w = placed[i]
			-- Never Hide() a focused EditBox: hiding drops keyboard focus and
			-- folds the phone keyboard, and event-driven re-renders (BAG_UPDATE,
			-- PLAYER_MONEY, CURSOR_* ...) land mid-typing. The next Anchor()
			-- call re-positions the widget anyway, so leaving it shown for the
			-- one synchronous rebuild frame is invisible.
			if not (w.HasFocus and w:HasFocus()) then
				w:Hide()
			end
			placed[i] = nil
		end
		y = 0
	end

	function st.Text(text, sizePx, r, g, b)
		used.text = used.text + 1
		local fs = pools.text[used.text]
		if not fs then
			fs = WM.CreateText(scroller.child, 30)
			fs:SetJustifyH("LEFT")
			fs:SetWordWrap(true)
			fs:SetSpacing(WM.Px(6))
			pools.text[used.text] = fs
		end
		WM.SetFont(fs, sizePx or 30)
		fs:SetTextColor(r or 0.92, g or 0.92, b or 0.92)
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(y))
		fs:SetWidth(scroller.ContentWidth() - WM.Px(8))
		fs:SetText(text)
		fs:Show()
		y = y + fs:GetStringHeight() / WM.Px(1) + GAP
		return fs
	end

	-- Pooled button acquire: resets everything a previous render customized.
	local function NextButton()
		used.button = used.button + 1
		local b = pools.button[used.button]
		if not b then
			b = WM.CreateTouchButton(scroller.child, 100, BUTTON_H, nil, 32)
			b.icon = b:CreateTexture(nil, "ARTWORK")
			b.icon:SetSize(WM.Px(56), WM.Px(56))
			b.icon:SetPoint("LEFT", WM.Px(18), 0)
			pools.button[used.button] = b
		end
		local bd = WM.Colors.border
		b.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
		WM.SetButtonEnabled(b, true)
		b:SetScript("OnEnter", nil)
		b:SetScript("OnLeave", nil)
		return b
	end

	function st.Button(label, icon, onTap, tooltip)
		local b = NextButton()
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 0, -WM.Px(y))
		b:SetPoint("TOPRIGHT", 0, -WM.Px(y))
		b:SetHeight(WM.Px(BUTTON_H))
		b.label:ClearAllPoints()
		b.label:SetPoint("LEFT", WM.Px(icon and 92 or 24), 0)
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
		y = y + BUTTON_H + GAP
		return b
	end

	-- N equal-width buttons on one row.
	-- spec: { label, onTap, selected, disabled, green, red }
	function st.Row(specs)
		local n = #specs
		local w = (WidthPx() - GAP * (n - 1)) / n
		local out = {}
		for i = 1, n do
			local spec = specs[i]
			local b = NextButton()
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", WM.Px((i - 1) * (w + GAP)), -WM.Px(y))
			b:SetSize(WM.Px(w), WM.Px(BUTTON_H))
			b.icon:Hide()
			b.label:ClearAllPoints()
			b.label:SetPoint("CENTER")
			b.label:SetJustifyH("CENTER")
			b.label:SetWidth(WM.Px(w - 24))
			b.label:SetText(spec.label)
			local c
			if spec.selected then
				c = WM.Colors.accent
			elseif spec.green then
				c = WM.Colors.green
			elseif spec.red then
				c = WM.Colors.red
			end
			if c then
				b.borderTex:SetColorTexture(c[1], c[2], c[3], 1)
			end
			b:SetScript("OnClick", spec.onTap)
			if spec.disabled then
				WM.SetButtonEnabled(b, false)
			end
			b:Show()
			out[i] = b
		end
		y = y + BUTTON_H + GAP
		return out
	end

	-- Item cells in a 2-column grid. Item shape:
	--   { icon, count, label (pre-colored), selected, dropTarget, disabled,
	--     tooltip(tt), ... }
	-- icon == nil renders the empty-slot look (dark fill, like Bags.lua).
	-- Border priority: selected (accent) > dropTarget (green) > default —
	-- dropTarget is how the sheets paint MoveMode drop cues on POOLED cells
	-- (a permanent MoveMode.RegisterTarget overlay would light up wrongly
	-- when the pool renders a different view; the sheets re-render on
	-- CURSOR_CHANGED instead, so the cue tracks the carry).
	function st.Grid(items, onTap)
		local colW = (WidthPx() - GAP) / 2
		local rows = math.ceil(#items / 2)
		for i = 1, #items do
			local item = items[i]
			used.cell = used.cell + 1
			local cell = pools.cell[used.cell]
			if not cell then
				cell = WM.CreateTouchButton(scroller.child, 100, CELL_H, nil, 26)
				cell.icon = cell:CreateTexture(nil, "ARTWORK")
				cell.icon:SetSize(WM.Px(80), WM.Px(80))
				cell.icon:SetPoint("LEFT", WM.Px(14), 0)
				cell.countText = WM.CreateText(cell, 24, "OUTLINE")
				cell.countText:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
				cell.label:ClearAllPoints()
				cell.label:SetPoint("LEFT", WM.Px(106), 0)
				cell.label:SetJustifyH("LEFT")
				pools.cell[used.cell] = cell
			end
			local col = (i - 1) % 2
			local row = math.floor((i - 1) / 2)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", WM.Px(col * (colW + GAP)), -WM.Px(y + row * (CELL_H + GAP)))
			cell:SetSize(WM.Px(colW), WM.Px(CELL_H))
			if item.icon then
				cell.icon:SetTexture(item.icon)
				cell.icon:SetVertexColor(1, 1, 1)
			else
				cell.icon:SetTexture(WM.TEX_WHITE)
				cell.icon:SetVertexColor(0.12, 0.12, 0.14)
			end
			cell.countText:SetText(item.count and item.count > 1 and item.count or "")
			cell.label:SetWidth(WM.Px(colW - 120))
			cell.label:SetText(item.label or "")
			local c
			if item.selected then
				c = WM.Colors.accent
			elseif item.dropTarget then
				c = WM.Colors.green
			else
				c = WM.Colors.border
			end
			cell.borderTex:SetColorTexture(c[1], c[2], c[3], 1)
			if onTap and not item.disabled then
				cell:SetScript("OnClick", function() onTap(item, i) end)
			else
				cell:SetScript("OnClick", nil)
			end
			if item.tooltip then
				WM.AttachTooltip(cell, function(tt) item.tooltip(tt) end)
			else
				cell:SetScript("OnEnter", nil)
				cell:SetScript("OnLeave", nil)
			end
			cell:Show()
		end
		y = y + rows * (CELL_H + GAP)
	end

	-- Place a persistent widget (stepper, edit box — created once, parented to
	-- scroller.child) into the flow at the current position.
	function st.Anchor(frame, hPx)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", 0, -WM.Px(y))
		frame:Show()
		placed[#placed + 1] = frame
		y = y + hPx + GAP
	end

	-- Same scroll-keeping contract as BottomSheet.lua's FinishLayout: a
	-- rebuild landing on the view key of the previous render preserves the
	-- scroll offset; nil / a changed key starts at the top. ClearView on
	-- sheet hide makes the next session start fresh.
	function st.Finish(viewKey)
		scroller.SetContentHeight(WM.Px(y + 8))
		if viewKey == nil or viewKey ~= lastView then
			scroller.ScrollToTop()
		end
		lastView = viewKey
	end

	function st.ClearView()
		lastView = nil
	end

	return st
end

--------------------------------------------------------------------------------
-- Steppers
--------------------------------------------------------------------------------

-- Plain number stepper: [-] value [+] with >=90 px buttons. minFn/maxFn are
-- re-evaluated on every tap so bounds can track live data (stack sizes,
-- availability counts). Set() clamps.
function Kit.CreateStepper(parent, wPx, label)
	local f = CreateFrame("Frame", nil, parent)
	local bw = 110
	f:SetSize(WM.Px(wPx), WM.Px(140))
	f.value = 1

	local title = WM.CreateText(f, 26)
	title:SetPoint("TOPLEFT")
	title:SetText(label or "")
	title:SetTextColor(0.75, 0.75, 0.8)

	local valueText = WM.CreateText(f, 36)
	valueText:SetPoint("TOPLEFT", WM.Px(bw), -WM.Px(38))
	valueText:SetSize(WM.Px(wPx - 2 * bw), WM.Px(96))
	valueText:SetJustifyH("CENTER")

	local function Clamp(v)
		local lo = f.minFn and f.minFn() or 1
		local hi = f.maxFn and f.maxFn() or 999
		if hi < lo then hi = lo end
		if v < lo then v = lo end
		if v > hi then v = hi end
		return v
	end

	-- onChange fires only when the clamped value actually CHANGED (same guard
	-- as CreateMoneyStepper.SetCopper): render code parks steppers with Set(1)
	-- from inside the very render that onChange re-enters, so an unconditional
	-- fire would recurse Render -> Set -> onChange -> Render to a stack
	-- overflow (non-stackable sell items, recipes with missing reagents).
	function f.Set(v)
		v = Clamp(v)
		if v ~= f.value then
			f.value = v
			valueText:SetText(v)
			if f.onChange then f.onChange(v) end
		else
			valueText:SetText(v)
		end
	end

	-- Silent parking for render code: normalizes the stepper with NO onChange,
	-- so a render that resets its own stepper (non-stackable sell item,
	-- recipe with missing reagents) can never re-enter itself — even the
	-- guarded Set() would nest one full render when the value does change,
	-- leaving the outer render to append duplicate rows below it.
	function f.SetSilent(v)
		f.value = Clamp(v)
		valueText:SetText(f.value)
	end

	function f.Get()
		f.value = Clamp(f.value) -- re-clamp against live bounds at read time
		return f.value
	end

	local minus = WM.CreateTouchButton(f, bw, 96, "-", 44)
	minus:SetPoint("TOPLEFT", 0, -WM.Px(38))
	minus:SetScript("OnClick", function() f.Set(f.value - 1) end)
	local plus = WM.CreateTouchButton(f, bw, 96, "+", 44)
	plus:SetPoint("TOPLEFT", WM.Px(wPx - bw), -WM.Px(38))
	plus:SetScript("OnClick", function() f.Set(f.value + 1) end)

	f.Set(1)
	return f
end

-- Money entry as three tap-stepper groups (g/s/c) plus a step-multiplier
-- cycle button (x1 -> x10 -> x100). 956 px wide (three 282 px unit groups +
-- the 110 px cycle button: 3*282 + 110), 150 high; fits the 966 px scroller
-- viewport every sheet uses.
--
-- Cap = MAXIMUM_BID_PRICE (2,000,000,000 copper on classic builds,
-- Blizzard_AuctionData.lua) so every posting the default UI can represent is
-- reachable; hard fallback matches that constant.
local MAX_COPPER = MAXIMUM_BID_PRICE or 2000000000

function Kit.CreateMoneyStepper(parent, label)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(WM.Px(956), WM.Px(150))
	f.copper = 0
	local step = 1

	local title = WM.CreateText(f, 26)
	title:SetPoint("TOPLEFT")

	local UNIT_COPPER = { g = 10000, s = 100, c = 1 }
	local groups = {}

	local function UnitValue(unit)
		if unit == "g" then
			return math.floor(f.copper / 10000)
		elseif unit == "s" then
			return math.floor(f.copper / 100) % 100
		end
		return f.copper % 100
	end

	local function Refresh()
		title:SetText((label or "") .. "   " .. WM.FormatMoney(f.copper))
		for i = 1, #groups do
			local grp = groups[i]
			grp.text:SetText(UnitValue(grp.unit) .. grp.unit)
		end
	end

	function f.SetCopper(copper)
		if copper < 0 then copper = 0 end
		if copper > MAX_COPPER then copper = MAX_COPPER end
		if copper ~= f.copper then
			f.copper = copper
			Refresh()
			if f.onChange then f.onChange(copper) end
		else
			Refresh()
		end
	end

	function f.GetCopper()
		return f.copper
	end

	local x = 0
	local UNITS = { "g", "s", "c" }
	for i = 1, #UNITS do
		local unit = UNITS[i]
		local minus = WM.CreateTouchButton(f, 92, 96, "-", 44)
		minus:SetPoint("TOPLEFT", WM.Px(x), -WM.Px(44))
		minus:SetScript("OnClick", function()
			f.SetCopper(f.copper - UNIT_COPPER[unit] * step)
		end)
		local text = WM.CreateText(f, 30)
		text:SetPoint("TOPLEFT", WM.Px(x + 92), -WM.Px(44))
		text:SetSize(WM.Px(86), WM.Px(96))
		text:SetJustifyH("CENTER")
		local plus = WM.CreateTouchButton(f, 92, 96, "+", 44)
		plus:SetPoint("TOPLEFT", WM.Px(x + 92 + 86), -WM.Px(44))
		plus:SetScript("OnClick", function()
			f.SetCopper(f.copper + UNIT_COPPER[unit] * step)
		end)
		groups[#groups + 1] = { unit = unit, text = text }
		x = x + 92 + 86 + 92 + 12
	end

	local stepBtn = WM.CreateTouchButton(f, 110, 96, "x1", 28)
	stepBtn:SetPoint("TOPLEFT", WM.Px(x), -WM.Px(44))
	stepBtn:SetScript("OnClick", function()
		step = (step == 1 and 10) or (step == 10 and 100) or 1
		stepBtn.label:SetText("x" .. step)
	end)

	Refresh()
	return f
end

--------------------------------------------------------------------------------
-- Text field (phone-keyboard entry pattern)
--------------------------------------------------------------------------------

-- Big EditBox: tap focuses it, and the streaming client's keyboard (edge-rail
-- Aa) then delivers real keystrokes into the focused box — the same keystroke
-- stream the rescued chat edit box receives (Chat.lua). The client brackets
-- every keyboard submission with two VK_RETURN taps (client keyboard.js:
-- "opens the chat box" / "sends the line"), so Enter here is stateful to
-- speak that protocol: an Enter arriving before anything has been typed
-- since focus (the opening bracket) is consumed — it only selects the
-- field's old text so the incoming characters replace it — while an Enter
-- after typing (the closing bracket) commits (f.onEnter) and drops focus so
-- the phone keyboard can fold. Escape just drops focus.
function Kit.CreateTextField(parent, wPx, placeholder, maxLetters)
	local f = CreateFrame("EditBox", nil, parent)
	f:SetSize(WM.Px(wPx), WM.Px(96))
	f:SetAutoFocus(false)
	f:SetFont(STANDARD_TEXT_FONT, WM.Px(34), "")
	f:SetTextColor(0.92, 0.92, 0.92)
	f:SetTextInsets(WM.Px(20), WM.Px(20), 0, 0)
	if maxLetters then f:SetMaxLetters(maxLetters) end
	WM.SkinFrame(f, { 0.08, 0.08, 0.10, 1 })

	local hint = WM.CreateText(f, 30)
	hint:SetPoint("LEFT", WM.Px(20), 0)
	hint:SetTextColor(0.5, 0.5, 0.55)
	hint:SetText(placeholder or "")

	local function UpdateHint()
		hint:SetShown(f:GetText() == "" and not f:HasFocus())
	end

	local typed = false -- user keystrokes since focus gain (Enter protocol above)
	f:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f:SetScript("OnEnterPressed", function(self)
		if not typed then
			-- The keyboard's opening RETURN: consume it, select the old text
			-- so the incoming characters replace it.
			self:HighlightText()
			return
		end
		typed = false
		self:ClearFocus()
		if f.onEnter then f.onEnter(self:GetText()) end
	end)
	f:SetScript("OnEditFocusGained", function()
		typed = false
		UpdateHint()
	end)
	f:SetScript("OnEditFocusLost", UpdateHint)
	f:SetScript("OnTextChanged", function(self, userInput)
		if userInput then typed = true end
		UpdateHint()
		if f.onChanged then f.onChanged(f:GetText()) end
	end)
	UpdateHint()
	return f
end

--------------------------------------------------------------------------------
-- Bag list
-- Pooled 2-column picker of everything in the player's bags, rendered into a
-- sheet's scroller below the caller's own stack content. Tap = onTap(bag,
-- slot); long-press (right-click) enters MoveMode with the slot, so every
-- economy sheet keeps the same pickup gesture the Bags panel has (stacks get
-- MoveMode's quantity stepper that way).
--------------------------------------------------------------------------------

function Kit.NewBagList(scroller)
	local list = {}
	local cells = {}

	-- Renders at vertical offset yPx (design px); returns the height used.
	function list.Render(yPx, onTap)
		local colW = (scroller.ContentWidth() / WM.Px(1) - GAP) / 2
		local shown = 0
		for bag = 0, NUM_BAG_SLOTS or 4 do
			for slot = 1, WM.Container.GetNumSlots(bag) do
				local icon, count, locked, quality = WM.Container.GetItemInfo(bag, slot)
				if icon then
					shown = shown + 1
					local cell = cells[shown]
					if not cell then
						cell = WM.CreateTouchButton(scroller.child, 100, CELL_H, nil, 26)
						cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
						cell.icon = cell:CreateTexture(nil, "ARTWORK")
						cell.icon:SetSize(WM.Px(80), WM.Px(80))
						cell.icon:SetPoint("LEFT", WM.Px(14), 0)
						cell.countText = WM.CreateText(cell, 24, "OUTLINE")
						cell.countText:SetPoint("BOTTOMRIGHT", cell.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
						cell.label:ClearAllPoints()
						cell.label:SetPoint("LEFT", WM.Px(106), 0)
						cell.label:SetJustifyH("LEFT")
						cells[shown] = cell
					end
					local col = (shown - 1) % 2
					local rowI = math.floor((shown - 1) / 2)
					cell:ClearAllPoints()
					cell:SetPoint("TOPLEFT", WM.Px(col * (colW + GAP)), -WM.Px(yPx + rowI * (CELL_H + GAP)))
					cell:SetSize(WM.Px(colW), WM.Px(CELL_H))
					cell.icon:SetTexture(icon)
					cell.icon:SetDesaturated(locked and true or false)
					cell.countText:SetText(count and count > 1 and count or "")
					local link = WM.Container.GetItemLink(bag, slot)
					local name = link and link:match("%[(.-)%]") or RETRIEVING_ITEM_INFO
					cell.label:SetWidth(WM.Px(colW - 120))
					cell.label:SetText(Kit.QualityName(name, quality))
					local b, s = bag, slot
					cell:SetScript("OnClick", function(_, mouseButton)
						if mouseButton == "RightButton" then
							WM.MoveMode.Begin({ kind = "bag", bag = b, slot = s })
						elseif onTap then
							onTap(b, s)
						end
					end)
					WM.AttachTooltip(cell, function(tt) tt:SetBagItem(b, s) end)
					cell:Show()
				end
			end
		end
		for i = shown + 1, #cells do
			cells[i]:Hide()
		end
		return math.ceil(shown / 2) * (CELL_H + GAP)
	end

	-- For renders of a view that does not include the bag list.
	function list.Clear()
		for i = 1, #cells do cells[i]:Hide() end
	end

	return list
end
