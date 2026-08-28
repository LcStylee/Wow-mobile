--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Pet
-- Pet control + status for the pet classes (PetActionBarFrame and PetFrame
-- are banished in Blizzard.lua):
--   * action block — the 10 pet action slots (attack/follow/stay, abilities,
--     autocast modes) as a 2x5 block on the left edge of the world square. It
--     occupies the stance column's spot: no vanilla class natively has both a
--     combat pet and shapeshift forms. Tap = CastPetAction; long-press
--     (client right click) = TogglePetAutocast, exactly the default pet
--     bar's right-click semantics on 1.12.
--   * status strip — compact button over the free bottom band of the player
--     frame: pet name, happiness (hunter pets), health bar. Tap = target
--     pet; long-press = the pet popup menu (PetFrameDropDown: Dismiss,
--     rename, ...) through the shared touch-scaled dropdown wrap in
--     UnitFrames.lua.
--------------------------------------------------------------------------------

local WM = WowMobile

local SLOTS = NUM_PET_ACTION_SLOTS or 10
local COLS = 2
local SIZE = 88
local GAP = 6

local column, strip
local buttons = {}

--------------------------------------------------------------------------------
-- Action block updates
-- 1.12 GetPetActionInfo(i) -> name, subtext, texture, isToken, isActive,
-- autoCastAllowed, autoCastEnabled. Token slots hand back global-string keys;
-- the texture key resolves to the real icon path via getglobal.
--------------------------------------------------------------------------------

local function UpdateButton(i)
	local b = buttons[i]
	local name, _, texture, isToken, isActive, _, autoCastEnabled = GetPetActionInfo(i)
	if isToken then
		texture = getglobal(texture) or texture
	end
	if name then
		b.icon:SetTexture(texture or WM.TEX_QUESTION)
		b.icon:Show()
	else
		b.icon:Hide()
		WM.ClearCooldown(b.cooldown)
	end
	WM.SetShown(b.checkedTex, isActive)
	WM.SetShown(b.autocast, autoCastEnabled)
end

local function UpdateCooldowns()
	for i = 1, SLOTS do
		local start, duration, enable = GetPetActionCooldown(i)
		if enable ~= 0 and start > 0 and duration > 0 then
			WM.SetCooldown(buttons[i].cooldown, start, duration, enable)
		else
			WM.ClearCooldown(buttons[i].cooldown)
		end
	end
end

local function UpdateAllButtons()
	for i = 1, SLOTS do
		UpdateButton(i)
	end
	UpdateCooldowns()
end

--------------------------------------------------------------------------------
-- Status strip updates
--------------------------------------------------------------------------------

local HAPPINESS_COLORS = {
	{ 0.90, 0.25, 0.25 }, -- 1 unhappy
	{ 0.95, 0.80, 0.25 }, -- 2 content
	{ 0.30, 0.80, 0.35 }, -- 3 happy
}

local function UpdateStrip()
	if not UnitExists("pet") then return end
	strip.name:SetText(UnitName("pet") or "")
	local hp, hpMax = UnitHealth("pet"), UnitHealthMax("pet")
	strip.health:SetMinMaxValues(0, hpMax > 0 and hpMax or 1)
	strip.health:SetValue(hp)
	local frac = hpMax > 0 and hp / hpMax or 0
	if frac < 0.25 then
		strip.health:SetStatusBarColor(0.85, 0.25, 0.25)
	elseif frac < 0.5 then
		strip.health:SetStatusBarColor(0.95, 0.80, 0.25)
	else
		strip.health:SetStatusBarColor(0.30, 0.80, 0.35)
	end
	strip.health.text:SetText(hpMax > 0 and (math.floor(frac * 100 + 0.5) .. "%") or "")
	-- Happiness only exists for hunter pets; GetPetHappiness returns nil for
	-- other pets.
	local happiness = GetPetHappiness and GetPetHappiness()
	local c = happiness and HAPPINESS_COLORS[happiness]
	if c then
		strip.mood:SetText("*")
		strip.mood:SetTextColor(c[1], c[2], c[3])
	else
		strip.mood:SetText("")
	end
end

local function SyncVisibility()
	WM.SetShown(column, UnitExists("pet") and PetHasActionBar())
	WM.SetShown(strip, UnitExists("pet"))
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	column = CreateFrame("Frame", "WowMobilePetActionBlock", WM.WorldSquare)
	-- Left-edge layout budget (mirror of QuickBar.lua's right-edge table): the
	-- phone client claims the square's bottom-left corner for the virtual
	-- joystick before any tap can land (client input.js JOY_ZONE_FRAC = 0.45 —
	-- a first touch at x <= 486 with y >= 594, default 1080 viewport, always
	-- begins the joystick, never a click). Interactive frames on the left edge
	-- must therefore end above y = 594. This 2x5 block is 182x464; anchoring
	-- its top at y = 124 puts it in the exact band the stance column uses
	-- (ActionBars.lua, 124..588), clearing the joystick zone by 6 px. The
	-- debuff aura row shares y 124..208 but starts at x=210 (Auras.lua), so
	-- the block's x 8..190 is uncontested.
	column:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(8), -WM.Px(124))
	column:SetWidth(WM.Px(COLS * (SIZE + GAP) - GAP))
	column:SetHeight(WM.Px(math.ceil(SLOTS / COLS) * (SIZE + GAP) - GAP))
	column:SetAlpha(0.92) -- keep the world readable behind the block
	column:Hide()

	local unitRow = WM.Layout.unitRow

	for i = 1, SLOTS do
		local b = CreateFrame("Button", "WowMobilePetButton" .. i, column)
		b:SetWidth(WM.Px(SIZE))
		b:SetHeight(WM.Px(SIZE))
		WM.SkinFrame(b, { 0.06, 0.06, 0.07, 0.85 })
		local col = math.mod(i - 1, COLS)
		local row = math.floor((i - 1) / COLS)
		b:SetPoint("TOPLEFT", column, "TOPLEFT",
			WM.Px(col * (SIZE + GAP)), -WM.Px(row * (SIZE + GAP)))
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", WM.Px(3), -WM.Px(3))
		b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
		b.cooldown = WM.CreateCooldown(b, b.icon, SIZE)
		b.checkedTex = b:CreateTexture(nil, "OVERLAY")
		b.checkedTex:SetAllPoints(b)
		b.checkedTex:SetTexture(1, 0.82, 0, 0.25)
		b.checkedTex:Hide()
		-- Green corner chip = autocast enabled (long-press toggles it).
		b.autocast = b:CreateTexture(nil, "OVERLAY")
		b.autocast:SetWidth(WM.Px(16))
		b.autocast:SetHeight(WM.Px(16))
		b.autocast:SetPoint("TOPLEFT", b, "TOPLEFT", WM.Px(4), -WM.Px(4))
		b.autocast:SetTexture(0.30, 0.90, 0.40, 0.95)
		b.autocast:Hide()
		b.actionIndex = i
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function()
			if arg1 == "RightButton" then
				TogglePetAutocast(this.actionIndex)
			else
				CastPetAction(this.actionIndex)
			end
		end)
		WM.AttachTooltip(b, function(tt, self)
			tt:SetPetAction(self.actionIndex)
		end)
		buttons[i] = b
	end

	-- Status strip over the free band under the player frame's power bar
	-- (unit row is 180 px; player bars end 134 px down).
	strip = CreateFrame("Button", "WowMobilePetStrip", unitRow)
	strip:SetWidth(WM.Px(516))
	strip:SetHeight(WM.Px(42))
	strip:SetPoint("BOTTOMLEFT", unitRow, "BOTTOMLEFT", WM.Px(6), WM.Px(2))
	strip:SetFrameLevel(unitRow:GetFrameLevel() + 20) -- above the player button it overlays
	WM.SkinFrame(strip, { 0.05, 0.05, 0.07, 1 })
	strip:Hide()

	strip.name = WM.CreateText(strip, 24, "OUTLINE")
	strip.name:SetPoint("LEFT", strip, "LEFT", WM.Px(12), 0)
	strip.name:SetWidth(WM.Px(190))
	strip.name:SetJustifyH("LEFT")
	WM.SingleLine(strip.name, 24)

	strip.mood = WM.CreateText(strip, 24, "OUTLINE")
	strip.mood:SetPoint("LEFT", strip, "LEFT", WM.Px(206), 0)

	strip.health = CreateFrame("StatusBar", nil, strip)
	strip.health:SetStatusBarTexture(WM.TEX_WHITE)
	strip.health:SetPoint("TOPRIGHT", strip, "TOPRIGHT", -WM.Px(6), -WM.Px(6))
	strip.health:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
	strip.health:SetPoint("LEFT", strip, "LEFT", WM.Px(240), 0)
	local hbg = strip.health:CreateTexture(nil, "BACKGROUND")
	hbg:SetAllPoints(strip.health)
	hbg:SetTexture(0.03, 0.03, 0.04, 1)
	strip.health.text = WM.CreateText(strip.health, 20, "OUTLINE")
	strip.health.text:SetPoint("CENTER", strip.health, "CENTER", 0, 0)

	strip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	strip:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			-- PetFrameDropDown works while PetFrame itself is banished; the
			-- shared wrap in UnitFrames.lua scales the list and fixes the
			-- "cursor" anchor for the 1.6 menu scale.
			WM.OpenUnitMenu(PetFrameDropDown)
		else
			TargetUnit("pet")
		end
	end)
	WM.AttachTooltip(strip, function(tt)
		tt:SetUnit("pet")
	end)

	SyncVisibility()
	UpdateAllButtons()
	UpdateStrip()

	WM.On("PET_BAR_UPDATE", function()
		for i = 1, SLOTS do
			UpdateButton(i)
		end
		SyncVisibility()
	end)
	WM.On("PET_BAR_UPDATE_COOLDOWN", UpdateCooldowns)
	WM.On("UNIT_PET", function(_, unit)
		if unit ~= "player" then return end
		SyncVisibility()
		for i = 1, SLOTS do
			UpdateButton(i)
		end
		UpdateStrip()
	end)
	WM.On("UNIT_HEALTH", function(_, unit)
		if unit == "pet" then UpdateStrip() end
	end)
	WM.On("UNIT_MAXHEALTH", function(_, unit)
		if unit == "pet" then UpdateStrip() end
	end)
	WM.On("UNIT_NAME_UPDATE", function(_, unit)
		if unit == "pet" then UpdateStrip() end
	end)
	WM.TryOn("UNIT_HAPPINESS", function(_, unit)
		if unit == "pet" then UpdateStrip() end
	end)
	WM.On("PLAYER_ENTERING_WORLD", function()
		SyncVisibility()
		UpdateAllButtons()
		UpdateStrip()
	end)
end)
