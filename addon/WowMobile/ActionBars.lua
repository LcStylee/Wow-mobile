--------------------------------------------------------------------------------
-- WowMobile · ActionBars
-- Large secure action buttons in the control deck:
--   * main bar — action slots 1..12 as a 2x6 grid (row 1..6 at the very
--     bottom of the grid for best thumb reach), page-switched for stances /
--     shapeshift / bonus bars by a SecureHandlerStateTemplate driver so the
--     remap keeps working in combat,
--   * second bar — slots 61..72 (MultiBarBottomLeft's slots) as one 84px row,
--   * a stance/shapeshift column on the left edge of the world square
--     (created only for classes with forms).
-- Cooldown swipes (CooldownFrameTemplate), stack counts, macro names,
-- usability/range tinting. Updates are event-driven; the only timers are the
-- cooldown-remaining text and the range re-check, both C_Timer tickers.
--
-- Exposes WM.ActionBars.CreateButton for QuickBar.lua so all action buttons
-- share one visual/update pipeline.
--------------------------------------------------------------------------------

local _, WM = ...

local ActionBars = {}
WM.ActionBars = ActionBars

local buttons = {} -- every WowMobile action button, for event fan-out

-- Classic Era page driver: bars 2-6 via ActionBarPage, bonus bars 7-10 for
-- stances/shapeshift/stealth. Evaluated by the restricted environment, so
-- paging works in combat.
local PAGE_DRIVER = "[bar:2] 2; [bar:3] 3; [bar:4] 4; [bar:5] 5; [bar:6] 6; " ..
	"[bonusbar:1] 7; [bonusbar:2] 8; [bonusbar:3] 9; [bonusbar:4] 10; 1"

--------------------------------------------------------------------------------
-- Per-button visuals + state
--------------------------------------------------------------------------------

local function GetSlot(b)
	-- The secure page handler rewrites the "action" attribute; reading
	-- attributes from insecure code is always allowed.
	return b:GetAttribute("action")
end

local function UpdateUsable(b)
	local slot = GetSlot(b)
	if not HasAction(slot) then return end
	local isUsable, noMana = IsUsableAction(slot)
	local inRange = IsActionInRange(slot) -- nil = no range requirement
	if inRange == false then
		b.icon:SetVertexColor(1, 0.25, 0.25)
		b.icon:SetDesaturated(false)
	elseif noMana then
		b.icon:SetVertexColor(0.35, 0.45, 1)
		b.icon:SetDesaturated(false)
	elseif not isUsable then
		b.icon:SetVertexColor(0.55, 0.55, 0.55)
		b.icon:SetDesaturated(true)
	else
		b.icon:SetVertexColor(1, 1, 1)
		b.icon:SetDesaturated(false)
	end
end

local function UpdateCount(b)
	local slot = GetSlot(b)
	if HasAction(slot) and (IsConsumableAction(slot) or IsStackableAction(slot)) then
		local count = GetActionCount(slot)
		b.count:SetText(count > 9999 and "*" or count)
	else
		b.count:SetText("")
	end
end

local function UpdateCooldown(b)
	local start, duration, enable = GetActionCooldown(GetSlot(b))
	if enable ~= 0 and start > 0 and duration > 0 then
		b.cooldown:SetCooldown(start, duration)
	else
		b.cooldown:Clear()
		b.cdText:SetText("")
	end
end

local function UpdateChecked(b)
	local slot = GetSlot(b)
	b:SetChecked(IsCurrentAction(slot) or IsAutoRepeatAction(slot))
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
		b.cooldown:Clear()
		b.cdText:SetText("")
	end
	UpdateUsable(b)
	UpdateCount(b)
	UpdateCooldown(b)
	UpdateChecked(b)
end

--------------------------------------------------------------------------------
-- Button factory (shared with QuickBar.lua)
--------------------------------------------------------------------------------

function ActionBars.CreateButton(name, parent, slot, wPx, hPx)
	local b = CreateFrame("CheckButton", name, parent, "SecureActionButtonTemplate")
	b:SetSize(WM.Px(wPx), WM.Px(hPx))
	WM.SkinFrame(b, { 0.06, 0.06, 0.07, 1 })

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", WM.Px(3), -WM.Px(3))
	b.icon:SetPoint("BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
	WM.CropIcon(b.icon, wPx, hPx)

	b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints(b.icon)
	-- We render our own remaining-time text (b.cdText); with the
	-- countdownForCooldowns CVar on, the widget's built-in numbers would
	-- double it.
	b.cooldown:SetHideCountdownNumbers(true)

	-- Cooldown text sits above the swipe so it stays readable.
	local textHost = CreateFrame("Frame", nil, b)
	textHost:SetAllPoints()
	textHost:SetFrameLevel(b.cooldown:GetFrameLevel() + 1)
	b.cdText = WM.CreateText(textHost, 40, "OUTLINE")
	b.cdText:SetPoint("CENTER")
	b.cdText:SetTextColor(1, 0.85, 0.1)
	b.count = WM.CreateText(textHost, 30, "OUTLINE")
	b.count:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
	b.macroName = WM.CreateText(textHost, 20, "OUTLINE")
	b.macroName:SetPoint("BOTTOM", 0, WM.Px(4))
	b.macroName:SetWidth(WM.Px(wPx - 10))
	b.macroName:SetWordWrap(false)

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.12)
	local checked = b:CreateTexture(nil, "OVERLAY")
	checked:SetAllPoints()
	checked:SetColorTexture(1, 0.82, 0, 0.18)
	b:SetCheckedTexture(checked)

	-- Attribute writes on protected frames are combat-blocked; init normally
	-- runs out of combat, but logging in mid-combat must not error.
	WM.OutOfCombat(function()
		WM.RegisterSecureClicks(b) -- CVar-selected click edge, see Core.lua
		b:SetAttribute("type", "action")
		b:SetAttribute("action", slot)
	end)

	-- Fires when the secure page handler rewrites "action" (also mid-combat;
	-- visual updates from insecure code are fine).
	b:HookScript("OnAttributeChanged", function(self, attr)
		if attr == "action" then UpdateAll(self) end
	end)

	WM.AttachTooltip(b, function(tt, self)
		tt:SetAction(GetSlot(self))
	end)

	buttons[#buttons + 1] = b
	return b
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function BuildBars()
	local m = WM.DeckMetrics
	local gap = 6

	-- Second bar container: 12 x 84px, slots 61..72, no paging.
	local secondBar = CreateFrame("Frame", "WowMobileSecondBar", WM.Deck)
	secondBar:SetPoint("BOTTOMLEFT", WM.Layout.bottomRow, "TOPLEFT", 0, WM.Px(m.gap))
	secondBar:SetPoint("BOTTOMRIGHT", WM.Layout.bottomRow, "TOPRIGHT", 0, WM.Px(m.gap))
	secondBar:SetHeight(WM.Px(m.secondBar))
	WM.Layout.secondBar = secondBar

	-- Main bar container: 2 rows x 6 buttons, slots 1..12.
	local mainH = m.mainButtonH * 2 + gap
	local mainBar = CreateFrame("Frame", "WowMobileMainBar", WM.Deck)
	mainBar:SetPoint("BOTTOMLEFT", secondBar, "TOPLEFT", 0, WM.Px(m.gap))
	mainBar:SetPoint("BOTTOMRIGHT", secondBar, "TOPRIGHT", 0, WM.Px(m.gap))
	mainBar:SetHeight(WM.Px(mainH))
	WM.Layout.mainBar = mainBar

	-- Everything below creates/anchors protected frames and writes secure
	-- attributes — queued as one unit so a mid-combat login builds the bars
	-- the moment combat drops instead of tripping the lockdown.
	WM.OutOfCombat("actionbars-build", function()
	local mainButtons = {}
	local rowW = m.mainButtonW * 6 + gap * 5
	for i = 1, 12 do
		local b = ActionBars.CreateButton("WowMobileActionButton" .. i, mainBar, i, m.mainButtonW, m.mainButtonH)
		-- Slots 1..6 on the BOTTOM row: primary abilities closest to the thumb.
		local row = (i <= 6) and 0 or 1
		local col = (i - 1) % 6
		b:SetPoint("BOTTOMLEFT", mainBar, "BOTTOMLEFT",
			WM.Px((1064 - rowW) / 2 + col * (m.mainButtonW + gap)),
			WM.Px(row * (m.mainButtonH + gap)))
		mainButtons[i] = b
	end

	-- Secure paging header: rewrites the 12 main buttons' action slots when
	-- the page state changes ((page-1)*12 + i), entirely inside the secure
	-- environment so it works during combat.
	local header = CreateFrame("Frame", "WowMobileMainBarHeader", nil, "SecureHandlerStateTemplate")
	for i = 1, 12 do
		header:SetFrameRef("mainbtn" .. i, mainButtons[i])
	end
	header:SetAttribute("_onstate-page", [=[
		local page = tonumber(newstate) or 1
		for i = 1, 12 do
			local button = self:GetFrameRef("mainbtn" .. i)
			button:SetAttribute("action", (page - 1) * 12 + i)
		end
	]=])
	RegisterStateDriver(header, "page", PAGE_DRIVER)

	-- Second bar buttons: MultiBarBottomLeft's slots.
	local sw = 84
	local sRowW = sw * 12 + 4 * 11
	for i = 1, 12 do
		local b = ActionBars.CreateButton("WowMobileSecondButton" .. i, secondBar, 60 + i, sw, m.secondBar)
		b:SetPoint("BOTTOMLEFT", secondBar, "BOTTOMLEFT",
			WM.Px((1064 - sRowW) / 2 + (i - 1) * (sw + 4)), 0)
	end
	end) -- WM.OutOfCombat("actionbars-build")
end

--------------------------------------------------------------------------------
-- Stance / shapeshift column (left edge of the world square, tap-only — the
-- client maps taps there to left clicks; our frames sit above WorldFrame).
--------------------------------------------------------------------------------

local stanceButtons = {}
local stanceColumn

-- GetShapeshiftFormInfo differs across builds: classic returns
-- (texture, name, isActive, isCastable); newer clients return
-- (texture, isActive, isCastable, spellID) with no name.
local function FormInfo(i)
	local a, b, c, d = GetShapeshiftFormInfo(i)
	if type(b) == "string" then
		return a, b, nil, c and true or false
	end
	return a, nil, d, b and true or false
end

local function SyncStances()
	WM.OutOfCombat("stances", function()
		local n = GetNumShapeshiftForms()
		for i = 1, n do
			local b = stanceButtons[i]
			if not b then
				b = CreateFrame("CheckButton", "WowMobileStanceButton" .. i, stanceColumn, "SecureActionButtonTemplate")
				b:SetSize(WM.Px(88), WM.Px(88))
				WM.SkinFrame(b, { 0.06, 0.06, 0.07, 0.85 })
				b:SetPoint("TOP", 0, -WM.Px((i - 1) * 94))
				b.icon = b:CreateTexture(nil, "ARTWORK")
				b.icon:SetPoint("TOPLEFT", WM.Px(3), -WM.Px(3))
				b.icon:SetPoint("BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
				local checked = b:CreateTexture(nil, "OVERLAY")
				checked:SetAllPoints()
				checked:SetColorTexture(1, 0.82, 0, 0.25)
				b:SetCheckedTexture(checked)
				WM.RegisterSecureClicks(b) -- CVar-selected click edge, see Core.lua
				b:SetAttribute("type", "spell")
				stanceButtons[i] = b
			end
			local texture, name, spellID, isActive = FormInfo(i)
			b.icon:SetTexture(texture)
			-- "spell" accepts a name (classic) or a spell ID (newer builds).
			b:SetAttribute("spell", name or spellID)
			b:SetChecked(isActive)
			b:Show()
		end
		for i = n + 1, #stanceButtons do
			stanceButtons[i]:Hide()
		end
		stanceColumn:SetShown(n > 0)
	end)
end

local function UpdateStanceChecked()
	for i = 1, #stanceButtons do
		local b = stanceButtons[i]
		if b:IsShown() then
			local _, _, _, isActive = FormInfo(i)
			b:SetChecked(isActive)
		end
	end
end

--------------------------------------------------------------------------------
-- Events + tickers
--------------------------------------------------------------------------------

local function ForAll(fn)
	for i = 1, #buttons do
		fn(buttons[i])
	end
end

WM.OnInit(function()
	BuildBars()

	stanceColumn = CreateFrame("Frame", "WowMobileStanceColumn", WM.WorldSquare)
	-- Left-edge layout budget (full table in Pet.lua, which shares this band):
	-- the client's joystick owns first touches at x <= 486, y >= 594 of the
	-- default 1080 square (input.js JOY_ZONE_FRAC = 0.45), so left-edge
	-- buttons must end above y = 594. Top at y = 124 puts button row 5 at
	-- 500..588 — 6 px clear. Rows 6..8 of this frame would breach the zone,
	-- but no Classic Era class exceeds 5 forms (druid: bear/aquatic/cat/
	-- travel/moonkin); re-check before porting to a client with more.
	stanceColumn:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(8), -WM.Px(124))
	stanceColumn:SetSize(WM.Px(88), WM.Px(94 * 8))
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
	WM.On("ACTIONBAR_UPDATE_USABLE", function() ForAll(UpdateUsable) end)
	WM.TryOn("SPELL_UPDATE_USABLE", function() ForAll(UpdateUsable) end)
	WM.On("PLAYER_TARGET_CHANGED", function() ForAll(UpdateUsable) end)
	WM.On("BAG_UPDATE", function() ForAll(UpdateCount) end)
	WM.On("UPDATE_SHAPESHIFT_FORMS", function() SyncStances() end)
	WM.TryOn("UPDATE_SHAPESHIFT_FORM", function() UpdateStanceChecked() end)

	-- Range re-check: IsActionInRange has no event; a coarse ticker (only
	-- meaningful with a target) is the accepted exception to event-driven
	-- updates, alongside the cooldown text below.
	C_Timer.NewTicker(0.3, function()
		if UnitExists("target") then
			ForAll(UpdateUsable)
		end
	end)

	-- Cooldown-remaining text; GCD-length cooldowns (<2s) stay text-free.
	C_Timer.NewTicker(0.4, function()
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
