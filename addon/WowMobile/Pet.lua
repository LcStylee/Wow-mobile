--------------------------------------------------------------------------------
-- WowMobile · Pet
-- Pet control + status for the pet classes (PetActionBarFrame and PetFrame are
-- banished in Blizzard.lua):
--   * action block — the 10 pet action slots (attack/follow/stay, abilities,
--     autocast modes) as secure type="pet" buttons in a 2x5 block on the left
--     edge of the world square. It occupies the stance column's spot: no
--     Classic Era class natively has both a combat pet and shapeshift forms.
--     The one overlap is possession while a stance column is populated (e.g.
--     shadow-priest Mind Control with Shadowform known): both surfaces show
--     at the same anchor and the pet block — created later, higher frame
--     level — intentionally wins taps for the duration of the possession.
--     All 10 buttons stay laid out while a pet exists
--     (empty slots render as sockets) because per-slot Show/Hide on protected
--     buttons would be blocked in combat.
--   * status strip — compact secure unit button over the free bottom band of
--     the player frame: pet name, happiness (hunter loyalty API; hidden for
--     pets without it), health bar. Tap = target pet; long-press = the pet
--     popup menu (Dismiss, rename, ...).
-- Both surfaces show/hide through secure drivers (visibility state driver /
-- RegisterUnitWatch), so they stay correct in combat.
--------------------------------------------------------------------------------

local _, WM = ...

local SLOTS = NUM_PET_ACTION_SLOTS or 10
local COLS = 2
local SIZE = 88
local GAP = 6

local column, strip
local buttons = {}

-- GetPetActionInfo differs across builds: legacy clients return
-- (name, subtext, texture, isToken, isActive, autoCastAllowed,
-- autoCastEnabled); newer ones drop subtext. A boolean 3rd value marks the
-- modern shape.
local function PetActionInfo(i)
	local a, b, c, d, e, f, g = GetPetActionInfo(i)
	if type(c) == "boolean" then
		return a, b, c, d, e, f -- name, texture, isToken, isActive, allowed, enabled
	end
	return a, c, d, e, f, g
end

--------------------------------------------------------------------------------
-- Action block updates
--------------------------------------------------------------------------------

local function UpdateButton(i)
	local b = buttons[i]
	local name, texture, isToken, isActive, _, autoCastEnabled = PetActionInfo(i)
	if isToken then
		-- Token slots (attack/follow/aggressive/...) hand back global-string
		-- keys; the texture key resolves to the real icon path.
		texture = _G[texture] or texture
	end
	if name then
		b.icon:SetTexture(texture or WM.TEX_QUESTION)
		b.icon:Show()
	else
		b.icon:Hide()
		b.cooldown:Clear()
	end
	b:SetChecked(isActive and true or false)
	b.autocast:SetShown(autoCastEnabled and true or false)
end

local function UpdateCooldowns()
	for i = 1, SLOTS do
		local start, duration, enable = GetPetActionCooldown(i)
		if enable ~= 0 and start > 0 and duration > 0 then
			buttons[i].cooldown:SetCooldown(start, duration)
		else
			buttons[i].cooldown:Clear()
		end
	end
end

local function UpdateAllButtons()
	for i = 1, SLOTS do
		UpdateButton(i)
	end
	UpdateCooldowns()
end

-- macrotext2 rewrites are secure attribute writes → out-of-combat only
-- (coalesced through the queue by callers). Long-press (client right click)
-- then toggles autocast exactly like the default pet bar's right click.
local function SyncAutocastAttributes()
	for i = 1, SLOTS do
		local b = buttons[i]
		local name, _, isToken, _, autoCastAllowed = PetActionInfo(i)
		if isToken then
			name = _G[name] or name
		end
		if name and autoCastAllowed then
			b:SetAttribute("macrotext2", "/petautocasttoggle " .. name)
		else
			b:SetAttribute("macrotext2", "")
		end
	end
end

--------------------------------------------------------------------------------
-- Status strip updates (insecure visuals, combat-safe)
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
	-- Happiness only exists for hunter pets on Classic Era; GetPetHappiness
	-- returns nil for other pets (and is absent on some builds entirely).
	local happiness = GetPetHappiness and GetPetHappiness()
	local c = happiness and HAPPINESS_COLORS[happiness]
	if c then
		strip.mood:SetText("●")
		strip.mood:SetTextColor(c[1], c[2], c[3])
	else
		strip.mood:SetText("")
	end
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
	-- the block's x 8..190 is uncontested. A
	-- reduced /wm viewport raises the boundary (0.55 x viewport height) toward
	-- the lower slots — the trade-off SETUP.md documents next to the command.
	column:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(8), -WM.Px(124))
	column:SetSize(
		WM.Px(COLS * (SIZE + GAP) - GAP),
		WM.Px(math.ceil(SLOTS / COLS) * (SIZE + GAP) - GAP))
	column:SetAlpha(0.92) -- keep the world readable behind the block
	column:Hide() -- the visibility driver below takes over once registered

	local unitRow = WM.Layout.unitRow

	-- Secure button/strip creation, anchoring and attributes: queued as one
	-- unit for the mid-combat-login case (same pattern as the other modules).
	WM.OutOfCombat("pet-build", function()

	for i = 1, SLOTS do
		local b = CreateFrame("CheckButton", "WowMobilePetButton" .. i, column, "SecureActionButtonTemplate")
		b:SetSize(WM.Px(SIZE), WM.Px(SIZE))
		WM.SkinFrame(b, { 0.06, 0.06, 0.07, 0.85 })
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		b:SetPoint("TOPLEFT", WM.Px(col * (SIZE + GAP)), -WM.Px(row * (SIZE + GAP)))
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", WM.Px(3), -WM.Px(3))
		b.icon:SetPoint("BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
		b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
		b.cooldown:SetAllPoints(b.icon)
		-- No cdText on these small cells; the swipe alone reads fine, and the
		-- built-in numbers would be illegibly small.
		b.cooldown:SetHideCountdownNumbers(true)
		local checked = b:CreateTexture(nil, "OVERLAY")
		checked:SetAllPoints()
		checked:SetColorTexture(1, 0.82, 0, 0.25)
		b:SetCheckedTexture(checked)
		-- Green corner chip = autocast enabled (long-press toggles it).
		b.autocast = b:CreateTexture(nil, "OVERLAY")
		b.autocast:SetSize(WM.Px(16), WM.Px(16))
		b.autocast:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(4))
		b.autocast:SetColorTexture(0.30, 0.90, 0.40, 0.95)
		b.autocast:Hide()
		WM.RegisterSecureClicks(b) -- CVar-selected click edge, see Core.lua
		b:SetAttribute("type", "pet")     -- tap = the pet action in this slot
		b:SetAttribute("action", i)
		b:SetAttribute("type2", "macro")  -- long-press = autocast toggle (macrotext2 synced below)
		WM.AttachTooltip(b, function(tt, self)
			tt:SetPetAction(self:GetAttribute("action"))
		end)
		buttons[i] = b
	end

	-- Secure show/hide with pet existence, combat-safe ("visibility" drivers
	-- work on plain frames).
	RegisterStateDriver(column, "visibility", "[@pet,exists] show; hide")

	-- Status strip over the free band under the player frame's power bar
	-- (unit row is 180 px; player bars end 134 px down).
	strip = CreateFrame("Button", "WowMobilePetStrip", unitRow, "SecureUnitButtonTemplate")
	strip:SetSize(WM.Px(516), WM.Px(42))
	strip:SetPoint("BOTTOMLEFT", unitRow, "BOTTOMLEFT", WM.Px(6), WM.Px(2))
	strip:SetFrameLevel(unitRow:GetFrameLevel() + 20) -- above the player button it overlays
	WM.SkinFrame(strip, { 0.05, 0.05, 0.07, 1 })

	strip.name = WM.CreateText(strip, 24, "OUTLINE")
	strip.name:SetPoint("LEFT", WM.Px(12), 0)
	strip.name:SetWidth(WM.Px(190))
	strip.name:SetJustifyH("LEFT")
	strip.name:SetWordWrap(false)

	strip.mood = WM.CreateText(strip, 24, "OUTLINE")
	strip.mood:SetPoint("LEFT", WM.Px(206), 0)

	strip.health = CreateFrame("StatusBar", nil, strip)
	strip.health:SetStatusBarTexture(WM.TEX_WHITE)
	strip.health:SetPoint("TOPRIGHT", -WM.Px(6), -WM.Px(6))
	strip.health:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
	strip.health:SetPoint("LEFT", WM.Px(240), 0)
	local hbg = strip.health:CreateTexture(nil, "BACKGROUND")
	hbg:SetAllPoints()
	hbg:SetColorTexture(0.03, 0.03, 0.04, 1)
	strip.health.text = WM.CreateText(strip.health, 20, "OUTLINE")
	strip.health.text:SetPoint("CENTER")

	WM.RegisterSecureClicks(strip) -- CVar-selected click edge, see Core.lua
	strip:SetAttribute("unit", "pet")
	strip:SetAttribute("type1", "target")     -- tap = target the pet
	strip:SetAttribute("type2", "togglemenu") -- long-press = pet popup (Dismiss, ...)
	WM.AttachTooltip(strip, function(tt)
		tt:SetUnit("pet")
	end)
	RegisterUnitWatch(strip)

	UpdateAllButtons()
	SyncAutocastAttributes() -- in-queue = guaranteed out of combat
	UpdateStrip()

	WM.On("PET_BAR_UPDATE", function()
		for i = 1, SLOTS do
			UpdateButton(i)
		end
		WM.OutOfCombat("pet-autocast-sync", SyncAutocastAttributes)
	end)
	WM.On("PET_BAR_UPDATE_COOLDOWN", UpdateCooldowns)
	WM.On("UNIT_PET", function(_, unit)
		if unit ~= "player" then return end
		for i = 1, SLOTS do
			UpdateButton(i)
		end
		WM.OutOfCombat("pet-autocast-sync", SyncAutocastAttributes)
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
		UpdateAllButtons()
		UpdateStrip()
	end)

	end) -- WM.OutOfCombat("pet-build")
end)
