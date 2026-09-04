--------------------------------------------------------------------------------
-- WowMobile · UnitFrames
-- Big player (left) and target (right) frames in the control deck. Secure
-- unit buttons (tap = target the unit); class-colored health, power-type
-- colored mana/rage/energy, big value texts, and a buff/debuff strip inside
-- the target frame (debuffs first — inspection priority). The target frame's
-- show/hide is handled by RegisterUnitWatch so it stays correct in combat.
--------------------------------------------------------------------------------

local _, WM = ...

local MAX_TARGET_AURAS = 9
local AURA_SIZE = 52

local player, target -- secure unit buttons

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

local function MakeBar(parent, hPx, textPx)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetHeight(WM.Px(hPx))
	bar:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.06, 1)
	bar.text = WM.CreateText(bar, textPx, "OUTLINE")
	bar.text:SetPoint("CENTER")
	return bar
end

local function CreateUnitButton(name, parent, unit)
	local f = CreateFrame("Button", name, parent, "SecureUnitButtonTemplate")
	WM.SkinFrame(f, { 0.07, 0.07, 0.09, 1 })

	f.name = WM.CreateText(f, 30, "OUTLINE")
	f.name:SetPoint("TOPLEFT", WM.Px(10), -WM.Px(6))
	f.name:SetWidth(WM.Px(400))
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false)

	f.level = WM.CreateText(f, 26, "OUTLINE")
	f.level:SetPoint("TOPRIGHT", -WM.Px(10), -WM.Px(8))

	f.health = MakeBar(f, 52, 26)
	f.health:SetPoint("TOPLEFT", WM.Px(6), -WM.Px(42))
	f.health:SetPoint("TOPRIGHT", -WM.Px(6), -WM.Px(42))

	f.power = MakeBar(f, 36, 22)
	f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, -WM.Px(4))
	f.power:SetPoint("TOPRIGHT", f.health, "BOTTOMRIGHT", 0, -WM.Px(4))

	-- Safe here: this factory only runs inside the queued unitframes-build
	-- closure, i.e. guaranteed out of combat.
	WM.RegisterSecureClicks(f) -- CVar-selected click edge, see Core.lua
	f:SetAttribute("unit", unit)
	f:SetAttribute("type1", "target") -- tap = target this unit
	-- Long-press (client-injected right click) = standard unit popup — leave
	-- party, invite, trade, follow, loot method. SecureUnitButtonTemplate
	-- handles "togglemenu" natively on Classic Era.
	f:SetAttribute("type2", "togglemenu")

	WM.AttachTooltip(f, function(tt)
		tt:SetUnit(unit)
	end)

	f.unit = unit
	return f
end

--------------------------------------------------------------------------------
-- State updates
--------------------------------------------------------------------------------

local function UpdateHealth(f)
	local unit = f.unit
	if not UnitExists(unit) then return end
	local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
	f.health:SetMinMaxValues(0, hpMax > 0 and hpMax or 1)
	f.health:SetValue(hp)
	f.health:SetStatusBarColor(WM.UnitColor(unit))
	if UnitIsDeadOrGhost(unit) then
		f.health.text:SetText(UnitIsGhost(unit) and "Ghost" or "Dead")
	elseif hpMax > 0 then
		f.health.text:SetText(string.format("%s / %s  (%d%%)",
			WM.ShortNum(hp), WM.ShortNum(hpMax), hp / hpMax * 100))
	end
end

local function UpdatePower(f)
	local unit = f.unit
	if not UnitExists(unit) then return end
	local pp, ppMax = UnitPower(unit), UnitPowerMax(unit)
	local _, token = UnitPowerType(unit)
	local c = PowerBarColor[token] or PowerBarColor["MANA"]
	f.power:SetStatusBarColor(c.r, c.g, c.b)
	if ppMax > 0 then
		f.power:Show()
		f.power:SetMinMaxValues(0, ppMax)
		f.power:SetValue(pp)
		f.power.text:SetText(WM.ShortNum(pp) .. " / " .. WM.ShortNum(ppMax))
	else
		f.power:Hide()
	end
end

local function UpdateIdentity(f)
	local unit = f.unit
	if not UnitExists(unit) then return end
	f.name:SetText(UnitName(unit) or "")
	f.name:SetTextColor(WM.UnitColor(unit))
	local level = UnitLevel(unit)
	if level and level > 0 then
		local c = GetQuestDifficultyColor(level)
		f.level:SetText(level)
		f.level:SetTextColor(c.r, c.g, c.b)
	else
		f.level:SetText("??") -- boss / skull level
		f.level:SetTextColor(1, 0.2, 0.2)
	end
end

local function UpdateFrame(f)
	UpdateIdentity(f)
	UpdateHealth(f)
	UpdatePower(f)
end

--------------------------------------------------------------------------------
-- Target aura strip (debuffs first, then buffs; tooltips via OnEnter which
-- fires from the injected pointer-move preceding each tap)
--------------------------------------------------------------------------------

local auraCells = {}

local function GetAuraCell(i)
	local cell = auraCells[i]
	if cell then return cell end
	cell = CreateFrame("Button", nil, target)
	cell:SetSize(WM.Px(AURA_SIZE), WM.Px(AURA_SIZE))
	cell:SetPoint("BOTTOMLEFT", WM.Px(8 + (i - 1) * (AURA_SIZE + 4)), WM.Px(6))
	cell.border = cell:CreateTexture(nil, "BACKGROUND")
	cell.border:SetAllPoints()
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", WM.Px(2), -WM.Px(2))
	cell.icon:SetPoint("BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	cell.count = WM.CreateText(cell, 22, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	WM.AttachTooltip(cell, function(tt, self)
		if self.auraFilter == "HARMFUL" then
			tt:SetUnitDebuff("target", self.auraIndex)
		else
			tt:SetUnitBuff("target", self.auraIndex)
		end
	end)
	auraCells[i] = cell
	return cell
end

local function ShowAuraCell(cellIndex, filter, auraIndex, icon, count, dispelType)
	local cell = GetAuraCell(cellIndex)
	cell.auraFilter, cell.auraIndex = filter, auraIndex
	cell.icon:SetTexture(icon)
	cell.count:SetText(count and count > 1 and count or "")
	if filter == "HARMFUL" then
		local c = DebuffTypeColor[dispelType or "none"] or DebuffTypeColor["none"]
		cell.border:SetColorTexture(c.r, c.g, c.b, 1)
	else
		cell.border:SetColorTexture(0.28, 0.28, 0.33, 1)
	end
	cell:Show()
end

local function UpdateTargetAuras()
	local shown = 0
	for i = 1, MAX_TARGET_AURAS do
		local _, icon, count, dispelType = WM.GetAura("target", i, "HARMFUL")
		if not icon then break end
		shown = shown + 1
		ShowAuraCell(shown, "HARMFUL", i, icon, count, dispelType)
	end
	for i = 1, MAX_TARGET_AURAS - shown do
		local _, icon, count = WM.GetAura("target", i, "HELPFUL")
		if not icon then break end
		shown = shown + 1
		ShowAuraCell(shown, "HELPFUL", i, icon, count, nil)
	end
	for i = shown + 1, #auraCells do
		auraCells[i]:Hide()
	end
end

--------------------------------------------------------------------------------
-- Combo points (rogue/druid): plain text on the target frame. On Classic Era
-- 1.15 combo points are a power type — earning/spending fires
-- UNIT_POWER_UPDATE("player", "COMBO_POINTS"), which the event wiring below
-- routes here. The dedicated combo events only exist on other build lineages
-- (see the TryOn registrations), so they are optional extras, not the driver.
--------------------------------------------------------------------------------

local comboText

local function UpdateCombo()
	local cp = GetComboPoints("player", "target")
	if cp and cp > 0 then
		comboText:SetText(string.rep("|cffffcc00*|r", cp))
	else
		comboText:SetText("")
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- The unit popup opened by "togglemenu" renders at mouse size; scale it
	-- up for touch. Two menu backends exist across builds, and 1.15.5+ ships
	-- BOTH, so each is hooked independently (not either/or):
	--   * Reworked Menu system (retail 10.2.5+, Classic Era 1.15.5+): unit
	--     popups open through Menu.GetManager() into pooled menu frames — NOT
	--     the legacy DropDownListN frames, which a togglemenu tap never
	--     touches there. The open is hooked on the manager (OpenMenu and
	--     OpenContextMenu both, since the unit-popup path enters via the
	--     context variant) and the live frame fetched via GetOpenMenu(). This
	--     scales every context menu, deliberately: all menus on this UI are
	--     touch-operated.
	--   * Legacy UIDropDownMenu: shared DropDownList1..N frames, re-scaled on
	--     every toggle because all dropdown users recycle them.
	-- SetScale touches no UIDropDownMenu/Menu globals or menu internals, so
	-- neither hook can taint the menu code paths (SetClampedToScreen /
	-- SetClampRectInsets are plain widget methods, same reasoning). The band
	-- clamp (WM.Band.Clamp) re-runs on every open — unlike the scale it
	-- depends on the live band metrics AND the menu's effective scale, so it
	-- can't be set-once; it keeps a menu opened from a tap near the band edge
	-- inside the streamed crop instead of merely inside the window.
	local function ClampMenu(menu)
		if WM.Band then WM.Band.Clamp(menu) end
	end
	local manager = Menu and Menu.GetManager and Menu.GetManager()
	if manager then
		-- One treatment per menu WINDOW, root and submenu alike. Submenu
		-- windows are NOT children of the root menu frame: Blizzard_Menu
		-- acquires every level as a separate pooled frame parented to the
		-- same top-level parent (WorldFrame/UIParent) at THAT parent's scale,
		-- so neither the root's SetScale nor its clamp-rect insets reach
		-- them — untreated, a submenu (e.g. Raid Target Icon off the target
		-- menu) renders at mouse size and flips only at the real screen
		-- edge, opening into the cropped rail where the phone can neither
		-- see nor tap it.
		local function TreatMenuWindow(menu)
			if menu:GetScale() ~= 1.6 then
				menu:SetScale(1.6)
			end
			ClampMenu(menu)
		end
		-- Submenus open through the manager's INTERNAL hover path (a private
		-- mouse-event timer), which the addon-facing manager proxy does not
		-- expose — there is no submenu method to hooksecurefunc. Instead a
		-- watcher ticks while any menu is open and treats new menu windows
		-- as they appear. Identification is by construction, read-only:
		-- every menu window is a sibling of the root (same top-level
		-- parent), carries the ScrollBox child MenuTemplateBase installs in
		-- OnLoad, and the ID (1000) the manager stamps on acquisition. If a
		-- future build drops those markers the scan simply finds nothing and
		-- behavior degrades to today's root-only treatment — never worse.
		-- Blizzard opens submenus only after its own 0.33 s hover timer, so
		-- the 0.1 s scan period treats each window before a finger can reach
		-- it. The watcher runs ONLY while a menu is open, and uses the same
		-- plain widget reads/writes as above, so the taint reasoning holds
		-- for it too; forbidden siblings (nameplate frames also live under
		-- WorldFrame on some builds) are skipped before any other access.
		local watcher = CreateFrame("Frame")
		watcher:Hide()
		local treated = {}
		local sinceScan = 0
		watcher:SetScript("OnUpdate", function(self, elapsed)
			sinceScan = sinceScan + elapsed
			if sinceScan < 0.1 then return end
			sinceScan = 0
			local root = manager.GetOpenMenu and manager:GetOpenMenu()
			if not root then
				for k in next, treated do treated[k] = nil end
				self:Hide()
				return
			end
			local host = root:GetParent()
			if not host then return end
			-- Menu windows are pooled: a submenu released back to the pool can
			-- be re-acquired for a DIFFERENT submenu within the same open root
			-- (hover a second submenu item) — and whether the pool resets its
			-- state or not, a hidden frame's treatment is stale. Evicting
			-- non-shown entries makes both pool behaviors safe: the recycled
			-- window is re-treated on its next appearance (TreatMenuWindow is
			-- idempotent — GetScale guard + recomputed clamp — so cheap).
			for k in next, treated do
				if not k:IsShown() then treated[k] = nil end
			end
			for _, child in next, { host:GetChildren() } do
				if not treated[child]
					and not (child.IsForbidden and child:IsForbidden())
					and child ~= root
					and child:IsShown()
					and child.ScrollBox
					and child:GetID() == 1000 then
					treated[child] = true
					TreatMenuWindow(child)
				end
			end
		end)
		local function ScaleOpenMenu(mgr)
			local menu = mgr.GetOpenMenu and mgr:GetOpenMenu()
			if not menu then return end
			TreatMenuWindow(menu)
			-- Menu windows are pooled and recycled with default state, so a
			-- fresh open must forget what the last one treated; scan on the
			-- very next tick in case submenus were force-opened at open time.
			for k in next, treated do treated[k] = nil end
			sinceScan = 0.1
			watcher:Show()
		end
		for _, method in next, { "OpenMenu", "OpenContextMenu" } do
			if type(manager[method]) == "function" then
				hooksecurefunc(manager, method, ScaleOpenMenu)
			end
		end
	end
	if ToggleDropDownMenu then
		hooksecurefunc("ToggleDropDownMenu", function()
			for i = 1, UIDROPDOWNMENU_MAXLEVELS or 3 do
				local list = _G["DropDownList" .. i]
				if list then
					if list:GetScale() ~= 1.6 then
						list:SetScale(1.6)
					end
					ClampMenu(list)
				end
			end
		end)
	end

	local m = WM.DeckMetrics
	local row = CreateFrame("Frame", "WowMobileUnitRow", WM.Deck)
	row:SetPoint("BOTTOMLEFT", WM.Layout.xpBlock, "TOPLEFT", 0, WM.Px(m.gap))
	row:SetPoint("BOTTOMRIGHT", WM.Layout.xpBlock, "TOPRIGHT", 0, WM.Px(m.gap))
	row:SetHeight(WM.Px(m.unitRow))
	WM.Layout.unitRow = row

	-- The unit buttons are protected frames: creation, anchoring and the unit
	-- watch are queued as one unit for the mid-combat-login case. Event
	-- registration lives inside so handlers never see nil frames.
	WM.OutOfCombat("unitframes-build", function()

	player = CreateUnitButton("WowMobilePlayerFrame", row, "player")
	player:SetPoint("TOPLEFT")
	player:SetPoint("BOTTOMLEFT")
	player:SetWidth(WM.Px(528))

	target = CreateUnitButton("WowMobileTargetFrame", row, "target")
	target:SetPoint("TOPRIGHT")
	target:SetPoint("BOTTOMRIGHT")
	target:SetWidth(WM.Px(528))

	comboText = WM.CreateText(target, 34, "OUTLINE")
	comboText:SetPoint("TOP", 0, -WM.Px(6))

	-- Secure show/hide with target existence (combat-safe).
	RegisterUnitWatch(target)

	UpdateFrame(player)

	local function OnUnitEvent(update)
		return function(_, unit)
			if unit == "player" then
				update(player)
			elseif unit == "target" then
				update(target)
			end
		end
	end

	WM.On("UNIT_HEALTH", OnUnitEvent(UpdateHealth))
	WM.TryOn("UNIT_HEALTH_FREQUENT", OnUnitEvent(UpdateHealth)) -- classic-only, smoother ticks
	WM.On("UNIT_MAXHEALTH", OnUnitEvent(UpdateHealth))
	-- 1.15's combo-point signal is UNIT_POWER_UPDATE with powerType
	-- "COMBO_POINTS" (PLAYER_COMBO_POINTS was removed with 3.0 and there is
	-- no UNIT_COMBO_POINTS event on this client), so the combat-time combo
	-- refresh must ride the power handler.
	WM.On("UNIT_POWER_UPDATE", function(_, unit, powerType)
		if unit == "player" then
			UpdatePower(player)
			if powerType == "COMBO_POINTS" then UpdateCombo() end
		elseif unit == "target" then
			UpdatePower(target)
		end
	end)
	WM.On("UNIT_MAXPOWER", OnUnitEvent(UpdatePower))
	WM.On("UNIT_DISPLAYPOWER", OnUnitEvent(UpdatePower))
	WM.On("UNIT_NAME_UPDATE", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_FACTION", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_LEVEL", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_AURA", function(_, unit)
		if unit == "target" then UpdateTargetAuras() end
	end)
	WM.On("PLAYER_TARGET_CHANGED", function()
		UpdateFrame(target)
		UpdateTargetAuras()
		UpdateCombo()
	end)
	-- Combo events from other build lineages (PLAYER_COMBO_POINTS pre-3.0,
	-- UNIT_COMBO_POINTS on 3.x-derived clients). Neither exists on 1.15 —
	-- TryOn's pcall drops them silently there — they only matter if this
	-- addon is ever run on such a client, where UNIT_POWER_UPDATE may not
	-- carry COMBO_POINTS.
	WM.TryOn("PLAYER_COMBO_POINTS", UpdateCombo)
	WM.TryOn("UNIT_COMBO_POINTS", UpdateCombo)
	WM.On("PLAYER_ENTERING_WORLD", function()
		UpdateFrame(player)
		UpdateFrame(target)
		UpdateTargetAuras()
	end)

	end) -- WM.OutOfCombat("unitframes-build")
end)
