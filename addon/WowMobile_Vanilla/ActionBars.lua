--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · ActionBars
-- Large action buttons in the control deck:
--   * main bar — action slots 1..12 as a 2x6 grid (row 1..6 at the very
--     bottom for best thumb reach), page-switched for bars 2..6 and the
--     stance/stealth bonus bars,
--   * second bar — slots 61..72 (MultiBarBottomLeft's slots on 1.12) as one
--     84px row,
--   * a stance/shapeshift column on the left edge of the world square.
-- Cooldown spirals (CooldownFrameTemplate Model + CooldownFrame_SetTimer),
-- stack counts, macro names, usability/range tinting. Updates are
-- event-driven; the only timers are the cooldown-remaining text and the range
-- re-check.
--
-- 1.12 has no secure buttons and no combat lockdown: taps call UseAction
-- directly, and paging is resolved in Lua with the exact arithmetic of
-- FrameXML's ActionButton_GetPagedID —
--   slot = (CURRENT_ACTIONBAR_PAGE - 1) * 12 + i, except on page 1 with a
--   bonus-bar offset (stances/stealth), where
--   slot = (NUM_ACTIONBAR_PAGES + GetBonusBarOffset() - 1) * 12 + i,
-- i.e. offset 1 -> slots 73..84 and so on. CURRENT_ACTIONBAR_PAGE stays
-- authoritative even with MainMenuBar banished: 1.12's ACTIONPAGE/NEXTPAGE
-- key bindings set that global themselves before calling ChangeActionBarPage,
-- independent of any frame's event handlers.
--
-- Exposes WM.ActionBars.CreateButton for QuickBar.lua so all action buttons
-- share one visual/update pipeline.
--------------------------------------------------------------------------------

local WM = WowMobile

local ActionBars = {}
WM.ActionBars = ActionBars

local buttons = {} -- every WowMobile action button, for event fan-out

local function PagedSlot(i)
	local page = CURRENT_ACTIONBAR_PAGE or 1
	local bonus = GetBonusBarOffset and GetBonusBarOffset() or 0
	if page == 1 and bonus > 0 then
		return ((NUM_ACTIONBAR_PAGES or 6) + bonus - 1) * 12 + i
	end
	return (page - 1) * 12 + i
end

--------------------------------------------------------------------------------
-- Per-button visuals + state
--------------------------------------------------------------------------------

local function GetSlot(b)
	if b.pageable then
		return PagedSlot(b.baseIndex)
	end
	return b.slot
end

local function UpdateUsable(b)
	local slot = GetSlot(b)
	if not HasAction(slot) then return end
	local isUsable, noMana = IsUsableAction(slot)
	-- 1.12 IsActionInRange returns 1/0/nil (nil = no range requirement).
	local inRange = IsActionInRange(slot)
	if inRange == 0 then
		b.icon:SetVertexColor(1, 0.25, 0.25)
	elseif noMana then
		b.icon:SetVertexColor(0.35, 0.45, 1)
	elseif not isUsable then
		b.icon:SetVertexColor(0.45, 0.45, 0.45)
	else
		b.icon:SetVertexColor(1, 1, 1)
	end
end

local function UpdateCount(b)
	local slot = GetSlot(b)
	-- 1.12 has IsConsumableAction only (no IsStackableAction).
	if HasAction(slot) and IsConsumableAction(slot) then
		local count = GetActionCount(slot)
		b.count:SetText(count > 9999 and "*" or count)
	else
		b.count:SetText("")
	end
end

local function UpdateCooldown(b)
	local start, duration, enable = GetActionCooldown(GetSlot(b))
	if enable ~= 0 and start > 0 and duration > 0 then
		WM.SetCooldown(b.cooldown, start, duration, enable)
	else
		WM.ClearCooldown(b.cooldown)
		b.cdText:SetText("")
	end
end

local function UpdateChecked(b)
	local slot = GetSlot(b)
	WM.SetShown(b.checkedTex, IsCurrentAction(slot) or IsAutoRepeatAction(slot))
end

local function UpdateAll(b)
	local slot = GetSlot(b)
	if HasAction(slot) then
		b.icon:SetTexture(GetActionTexture(slot) or WM.TEX_QUESTION)
		b.icon:Show()
		b.macroName:SetText(GetActionText(slot) or "")
	else
		b.icon:Hide()
		b.macroName:SetText("")
		WM.ClearCooldown(b.cooldown)
		b.cdText:SetText("")
	end
	UpdateUsable(b)
	UpdateCount(b)
	UpdateCooldown(b)
	UpdateChecked(b)
end

--------------------------------------------------------------------------------
-- Button factory (shared with QuickBar.lua)
-- `pageable` marks the 12 main-bar buttons whose slot follows the action page.
--------------------------------------------------------------------------------

function ActionBars.CreateButton(name, parent, slot, wPx, hPx, pageable)
	local b = CreateFrame("Button", name, parent)
	b:SetWidth(WM.Px(wPx))
	b:SetHeight(WM.Px(hPx))
	WM.SkinFrame(b, { 0.06, 0.06, 0.07, 1 })
	b.slot = slot
	b.baseIndex = slot
	b.pageable = pageable and true or false

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", WM.Px(3), -WM.Px(3))
	b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
	WM.CropIcon(b.icon, wPx, hPx)

	b.cooldown = WM.CreateCooldown(b, b.icon, math.min(wPx, hPx))

	-- Text sits above the spiral so it stays readable.
	local textHost = CreateFrame("Frame", nil, b)
	textHost:SetAllPoints(b)
	textHost:SetFrameLevel(b:GetFrameLevel() + 2)
	b.cdText = WM.CreateText(textHost, 40, "OUTLINE")
	b.cdText:SetPoint("CENTER", textHost, "CENTER", 0, 0)
	b.cdText:SetTextColor(1, 0.85, 0.1)
	b.count = WM.CreateText(textHost, 30, "OUTLINE")
	b.count:SetPoint("BOTTOMRIGHT", textHost, "BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
	b.macroName = WM.CreateText(textHost, 20, "OUTLINE")
	b.macroName:SetPoint("BOTTOM", textHost, "BOTTOM", 0, WM.Px(4))
	b.macroName:SetWidth(WM.Px(wPx - 10))
	WM.SingleLine(b.macroName, 20)

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b)
	hl:SetTexture(1, 1, 1, 0.12)
	-- "checked" overlay managed by UpdateChecked (plain Button, not a
	-- CheckButton — 1.12 SetCheckedTexture wants a file path, not a region).
	b.checkedTex = b:CreateTexture(nil, "OVERLAY")
	b.checkedTex:SetAllPoints(b)
	b.checkedTex:SetTexture(1, 0.82, 0, 0.18)
	b.checkedTex:Hide()

	-- Tap = use (unchanged); long-press (client right click) = lift the
	-- action for MoveMode; while a carry is active every tap drops onto this
	-- slot (PlaceAction places/swaps spells, items and carried actions).
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function()
		local slot = GetSlot(this)
		if WM.MoveMode.IsActive() then
			WM.MoveMode.DropOnAction(slot)
		elseif arg1 == "RightButton" then
			WM.MoveMode.BeginFromAction(slot)
		else
			UseAction(slot)
		end
	end)
	WM.MoveMode.MakeTarget(b, "action")

	WM.AttachTooltip(b, function(tt, self)
		tt:SetAction(GetSlot(self))
	end)

	table.insert(buttons, b)
	return b
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function BuildBars()
	local m = WM.DeckMetrics
	local gap = 6

	-- Second bar container: 12 x 84px, slots 61..72 (MultiBarBottomLeft's
	-- fixed slots on 1.12), no paging.
	local secondBar = CreateFrame("Frame", "WowMobileSecondBar", WM.Deck)
	secondBar:SetPoint("BOTTOMLEFT", WM.Layout.bottomRow, "TOPLEFT", 0, WM.Px(m.gap))
	secondBar:SetPoint("BOTTOMRIGHT", WM.Layout.bottomRow, "TOPRIGHT", 0, WM.Px(m.gap))
	secondBar:SetHeight(WM.Px(m.secondBar))
	WM.Layout.secondBar = secondBar

	-- Main bar container: 2 rows x 6 buttons, slots 1..12 (paged).
	local mainH = m.mainButtonH * 2 + gap
	local mainBar = CreateFrame("Frame", "WowMobileMainBar", WM.Deck)
	mainBar:SetPoint("BOTTOMLEFT", secondBar, "TOPLEFT", 0, WM.Px(m.gap))
	mainBar:SetPoint("BOTTOMRIGHT", secondBar, "TOPRIGHT", 0, WM.Px(m.gap))
	mainBar:SetHeight(WM.Px(mainH))
	WM.Layout.mainBar = mainBar

	local rowW = m.mainButtonW * 6 + gap * 5
	for i = 1, 12 do
		local b = ActionBars.CreateButton("WowMobileActionButton" .. i, mainBar, i,
			m.mainButtonW, m.mainButtonH, true)
		-- Slots 1..6 on the BOTTOM row: primary abilities closest to the thumb.
		local row = (i <= 6) and 0 or 1
		local col = math.mod(i - 1, 6)
		b:SetPoint("BOTTOMLEFT", mainBar, "BOTTOMLEFT",
			WM.Px((1064 - rowW) / 2 + col * (m.mainButtonW + gap)),
			WM.Px(row * (m.mainButtonH + gap)))
	end

	-- Second bar buttons: MultiBarBottomLeft's slots.
	local sw = 84
	local sRowW = sw * 12 + 4 * 11
	for i = 1, 12 do
		local b = ActionBars.CreateButton("WowMobileSecondButton" .. i, secondBar, 60 + i, sw, m.secondBar)
		b:SetPoint("BOTTOMLEFT", secondBar, "BOTTOMLEFT",
			WM.Px((1064 - sRowW) / 2 + (i - 1) * (sw + 4)), 0)
	end
end

--------------------------------------------------------------------------------
-- Stance / shapeshift column (left edge of the world square, tap-only — the
-- client maps taps there to left clicks; our frames sit above WorldFrame).
--------------------------------------------------------------------------------

local stanceButtons = {}
local stanceColumn

local function SyncStances()
	local n = GetNumShapeshiftForms()
	for i = 1, n do
		local b = stanceButtons[i]
		if not b then
			b = CreateFrame("Button", "WowMobileStanceButton" .. i, stanceColumn)
			b:SetWidth(WM.Px(88))
			b:SetHeight(WM.Px(88))
			WM.SkinFrame(b, { 0.06, 0.06, 0.07, 0.85 })
			b:SetPoint("TOP", stanceColumn, "TOP", 0, -WM.Px((i - 1) * 94))
			b.icon = b:CreateTexture(nil, "ARTWORK")
			b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", WM.Px(3), -WM.Px(3))
			b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
			b.checkedTex = b:CreateTexture(nil, "OVERLAY")
			b.checkedTex:SetAllPoints(b)
			b.checkedTex:SetTexture(1, 0.82, 0, 0.25)
			b.checkedTex:Hide()
			b.formIndex = i
			-- 1.12: CastShapeshiftForm(index) is the direct stance/aura/form
			-- switch, same as the default ShapeshiftBar's click.
			b:SetScript("OnClick", function()
				CastShapeshiftForm(this.formIndex)
			end)
			stanceButtons[i] = b
		end
		-- 1.12 GetShapeshiftFormInfo: texture, name, isActive, isCastable.
		local texture, _, isActive = GetShapeshiftFormInfo(i)
		b.icon:SetTexture(texture)
		WM.SetShown(b.checkedTex, isActive)
		b:Show()
	end
	for i = n + 1, table.getn(stanceButtons) do
		stanceButtons[i]:Hide()
	end
	WM.SetShown(stanceColumn, n > 0)
end

local function UpdateStanceChecked()
	for i = 1, table.getn(stanceButtons) do
		local b = stanceButtons[i]
		if b:IsShown() then
			local _, _, isActive = GetShapeshiftFormInfo(i)
			WM.SetShown(b.checkedTex, isActive)
		end
	end
end

--------------------------------------------------------------------------------
-- Events + tickers
--------------------------------------------------------------------------------

local function ForAll(fn)
	for i = 1, table.getn(buttons) do
		fn(buttons[i])
	end
end

WM.OnInit(function()
	BuildBars()

	stanceColumn = CreateFrame("Frame", "WowMobileStanceColumn", WM.WorldSquare)
	-- Left-edge layout budget (full table in Pet.lua, which shares this band):
	-- the client's joystick owns first touches at x <= 486, y >= 594 of the
	-- default 1080 square, so left-edge buttons must end above y = 594. Top at
	-- y = 124 puts button row 5 at 500..588 — 6 px clear. No vanilla class
	-- exceeds 5 forms (druid: bear/aquatic/cat/travel/moonkin). The debuff
	-- aura row shares this band's top (y 124..208) but starts at x=210
	-- (Auras.lua), so the column's x 8..96 is uncontested.
	stanceColumn:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(8), -WM.Px(124))
	stanceColumn:SetWidth(WM.Px(88))
	stanceColumn:SetHeight(WM.Px(94 * 8))
	stanceColumn:Hide()
	SyncStances()

	WM.On("PLAYER_ENTERING_WORLD", function() ForAll(UpdateAll) end)
	WM.On("ACTIONBAR_SLOT_CHANGED", function(_, slot)
		ForAll(function(b)
			if slot == 0 or GetSlot(b) == slot then UpdateAll(b) end
		end)
	end)
	WM.On("ACTIONBAR_UPDATE_COOLDOWN", function() ForAll(UpdateCooldown) end)
	WM.On("ACTIONBAR_UPDATE_STATE", function() ForAll(UpdateChecked) end)
	-- Vanilla's ActionButton also drives the checked state from the combat
	-- and auto-repeat toggles; ACTIONBAR_UPDATE_STATE alone can lag an
	-- Attack/auto-shot toggle on some clients.
	WM.TryOn("PLAYER_ENTER_COMBAT", function() ForAll(UpdateChecked) end)
	WM.TryOn("PLAYER_LEAVE_COMBAT", function() ForAll(UpdateChecked) end)
	WM.TryOn("START_AUTOREPEAT_SPELL", function() ForAll(UpdateChecked) end)
	WM.TryOn("STOP_AUTOREPEAT_SPELL", function() ForAll(UpdateChecked) end)
	WM.On("ACTIONBAR_UPDATE_USABLE", function() ForAll(UpdateUsable) end)
	-- Page/bonus-bar changes remap the 12 pageable buttons' slots.
	WM.On("ACTIONBAR_PAGE_CHANGED", function() ForAll(UpdateAll) end)
	WM.On("UPDATE_BONUS_ACTIONBAR", function() ForAll(UpdateAll) end)
	WM.On("PLAYER_TARGET_CHANGED", function() ForAll(UpdateUsable) end)
	WM.On("BAG_UPDATE", function() ForAll(UpdateCount) end)
	WM.On("UPDATE_SHAPESHIFT_FORMS", function() SyncStances() end)
	WM.TryOn("UPDATE_SHAPESHIFT_FORM", function() UpdateStanceChecked() end)
	-- Stance switches also flip the bonus bar; UPDATE_BONUS_ACTIONBAR above
	-- covers the bar, this covers the column highlight.
	WM.On("UPDATE_BONUS_ACTIONBAR", function() UpdateStanceChecked() end)

	-- Range re-check: IsActionInRange has no event; a coarse ticker (only
	-- meaningful with a target) is the accepted exception to event-driven
	-- updates, alongside the cooldown text below.
	WM.Ticker(0.3, function()
		if UnitExists("target") then
			ForAll(UpdateUsable)
		end
	end)

	-- Cooldown-remaining text; GCD-length cooldowns (<2s) stay text-free.
	WM.Ticker(0.4, function()
		local now = GetTime()
		ForAll(function(b)
			local start, duration, enable = GetActionCooldown(GetSlot(b))
			local remain = start + duration - now
			if enable ~= 0 and duration > 2 and remain > 0 then
				b.cdText:SetText(WM.FormatDuration(remain))
			else
				b.cdText:SetText("")
			end
		end)
	end)
end)
