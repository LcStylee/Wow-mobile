--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · UnitFrames
-- Big player (left) and target (right) frames in the control deck. Tap =
-- target the unit; long-press (client-injected right click) = the standard
-- unit popup menu (leave party / invite / trade / follow / loot method),
-- served by the 1.12 FrameXML dropdowns (PlayerFrameDropDown /
-- TargetFrameDropDown — they keep working while their parent frames are
-- banished, because ToggleDropDownMenu renders into the shared DropDownListN
-- frames). Class-colored health, power-type colored mana/rage/energy, big
-- value texts, and a buff/debuff strip inside the target frame (debuffs
-- first — inspection priority).
--------------------------------------------------------------------------------

local WM = WowMobile

local MAX_TARGET_AURAS = 9
local AURA_SIZE = 52

local player, target

-- 1.12 name for the quest-difficulty color function.
local function DifficultyColor(level)
	if GetDifficultyColor then return GetDifficultyColor(level) end
	return { r = 1, g = 0.82, b = 0 }
end

--------------------------------------------------------------------------------
-- Touch-sized dropdown menus (shared by every long-press popup in the addon)
--
-- The DropDownListN frames render at mouse size; they are scaled to 1.6 for
-- touch. That alone would break "cursor"-anchored menus: 1.12's
-- ToggleDropDownMenu computes the cursor anchor as
--     listFrame:SetPoint("TOPLEFT", "UIParent", "BOTTOMLEFT",
--                        cursorX / uiScale, cursorY / uiScale)
-- where uiScale is UIParent:GetScale() — and SetPoint offsets live in the
-- ANCHORED frame's own (scaled) space, which 1.12 never divides by the
-- list's scale. At list scale 1.6 every cursor-anchored menu would open at
-- 1.6x the cursor vector from the screen origin (for the target frame on the
-- right half of the deck that lands past the 1080 px edge, unreachable). So
-- after the original runs, the visible level-1 list is re-anchored with
-- offsets divided by its own effective scale, which puts its TOPLEFT exactly
-- back under the finger. Frame-anchored menus (map dropdowns, submenu
-- levels) need no compensation: they anchor to their (also scaled) buttons
-- with near-zero offsets.
--------------------------------------------------------------------------------

local MENU_SCALE = 1.6

local origToggleDropDownMenu = ToggleDropDownMenu
function ToggleDropDownMenu(level, value, dropDownFrame, anchorName, xOffset, yOffset)
	origToggleDropDownMenu(level, value, dropDownFrame, anchorName, xOffset, yOffset)
	for i = 1, UIDROPDOWNMENU_MAXLEVELS or 2 do
		local list = getglobal("DropDownList" .. i)
		if list and list:GetScale() ~= MENU_SCALE then
			list:SetScale(MENU_SCALE)
		end
	end
	if (level or 1) == 1 and anchorName == "cursor" then
		local list = DropDownList1
		if list and list:IsVisible() then
			local x, y = GetCursorPosition()
			local s = list:GetEffectiveScale()
			list:ClearAllPoints()
			list:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
		end
	end
end

-- Long-press popup helper for unit buttons (also used by Pet.lua's strip).
function WM.OpenUnitMenu(dropdown)
	if not dropdown then return end
	ToggleDropDownMenu(1, nil, dropdown, "cursor", 0, 0)
end

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

local function MakeBar(parent, hPx, textPx)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetHeight(WM.Px(hPx))
	bar:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetTexture(0.05, 0.05, 0.06, 1)
	bar.text = WM.CreateText(bar, textPx, "OUTLINE")
	bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
	return bar
end

local function CreateUnitButton(name, parent, unit, dropdown)
	local f = CreateFrame("Button", name, parent)
	WM.SkinFrame(f, { 0.07, 0.07, 0.09, 1 })

	f.name = WM.CreateText(f, 30, "OUTLINE")
	f.name:SetPoint("TOPLEFT", f, "TOPLEFT", WM.Px(10), -WM.Px(6))
	f.name:SetWidth(WM.Px(400))
	f.name:SetJustifyH("LEFT")
	WM.SingleLine(f.name, 30)

	f.level = WM.CreateText(f, 26, "OUTLINE")
	f.level:SetPoint("TOPRIGHT", f, "TOPRIGHT", -WM.Px(10), -WM.Px(8))

	f.health = MakeBar(f, 52, 26)
	f.health:SetPoint("TOPLEFT", f, "TOPLEFT", WM.Px(6), -WM.Px(42))
	f.health:SetPoint("TOPRIGHT", f, "TOPRIGHT", -WM.Px(6), -WM.Px(42))

	f.power = MakeBar(f, 36, 22)
	f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, -WM.Px(4))
	f.power:SetPoint("TOPRIGHT", f.health, "BOTTOMRIGHT", 0, -WM.Px(4))

	f.unit = unit
	f.dropdown = dropdown
	f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			WM.OpenUnitMenu(this.dropdown)
		else
			TargetUnit(this.unit)
		end
	end)

	WM.AttachTooltip(f, function(tt)
		tt:SetUnit(unit)
	end)

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

-- 1.12 power colors live in ManaBarColor, indexed by the numeric power type
-- UnitPowerType returns (0 mana, 1 rage, 2 focus, 3 energy); UnitMana reads
-- the active power of any unit.
local function UpdatePower(f)
	local unit = f.unit
	if not UnitExists(unit) then return end
	local pp, ppMax = UnitMana(unit), UnitManaMax(unit)
	local powerType = UnitPowerType(unit)
	local c = (ManaBarColor and ManaBarColor[powerType]) or { r = 0.3, g = 0.5, b = 0.85 }
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
		local c = DifficultyColor(level)
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
-- fires from the injected pointer-move preceding each tap).
-- 1.12 shapes: UnitDebuff(unit, i) -> texture, applications, dispelType;
-- UnitBuff(unit, i) -> texture, applications.
--------------------------------------------------------------------------------

local auraCells = {}

local function GetAuraCell(i)
	local cell = auraCells[i]
	if cell then return cell end
	cell = CreateFrame("Button", nil, target)
	cell:SetWidth(WM.Px(AURA_SIZE))
	cell:SetHeight(WM.Px(AURA_SIZE))
	cell:SetPoint("BOTTOMLEFT", target, "BOTTOMLEFT",
		WM.Px(8 + (i - 1) * (AURA_SIZE + 4)), WM.Px(6))
	cell.border = cell:CreateTexture(nil, "BACKGROUND")
	cell.border:SetAllPoints(cell)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(2), -WM.Px(2))
	cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	cell.count = WM.CreateText(cell, 22, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
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
		local c = DebuffTypeColor and (DebuffTypeColor[dispelType or "none"] or DebuffTypeColor["none"])
		if c then
			cell.border:SetTexture(c.r, c.g, c.b, 1)
		else
			cell.border:SetTexture(0.85, 0.25, 0.25, 1)
		end
	else
		cell.border:SetTexture(0.28, 0.28, 0.33, 1)
	end
	cell:Show()
end

local function UpdateTargetAuras()
	local shown = 0
	for i = 1, MAX_TARGET_AURAS do
		local icon, count, dispelType = UnitDebuff("target", i)
		if not icon then break end
		shown = shown + 1
		ShowAuraCell(shown, "HARMFUL", i, icon, count, dispelType)
	end
	for i = 1, MAX_TARGET_AURAS - shown do
		local icon, count = UnitBuff("target", i)
		if not icon then break end
		shown = shown + 1
		ShowAuraCell(shown, "HELPFUL", i, icon, count, nil)
	end
	for i = shown + 1, table.getn(auraCells) do
		auraCells[i]:Hide()
	end
end

--------------------------------------------------------------------------------
-- Combo points (rogue/druid): plain text on the target frame. 1.12 signals
-- them with PLAYER_COMBO_POINTS and GetComboPoints() takes no arguments.
--------------------------------------------------------------------------------

local comboText

local function UpdateCombo()
	local cp = GetComboPoints()
	if cp and cp > 0 then
		comboText:SetText(string.rep("|cffffcc00*|r", cp))
	else
		comboText:SetText("")
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local function SyncTargetShown()
	WM.SetShown(target, UnitExists("target"))
end

WM.OnInit(function()
	local m = WM.DeckMetrics
	local row = CreateFrame("Frame", "WowMobileUnitRow", WM.Deck)
	row:SetPoint("BOTTOMLEFT", WM.Layout.xpBlock, "TOPLEFT", 0, WM.Px(m.gap))
	row:SetPoint("BOTTOMRIGHT", WM.Layout.xpBlock, "TOPRIGHT", 0, WM.Px(m.gap))
	row:SetHeight(WM.Px(m.unitRow))
	WM.Layout.unitRow = row

	player = CreateUnitButton("WowMobilePlayerFrame", row, "player", PlayerFrameDropDown)
	player:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
	player:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
	player:SetWidth(WM.Px(528))

	target = CreateUnitButton("WowMobileTargetFrame", row, "target", TargetFrameDropDown)
	target:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
	target:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
	target:SetWidth(WM.Px(528))

	comboText = WM.CreateText(target, 34, "OUTLINE")
	comboText:SetPoint("TOP", target, "TOP", 0, -WM.Px(6))

	SyncTargetShown()
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
	WM.On("UNIT_MAXHEALTH", OnUnitEvent(UpdateHealth))
	-- 1.12 has per-power events instead of UNIT_POWER_UPDATE.
	local powerEvents = {
		"UNIT_MANA", "UNIT_MAXMANA", "UNIT_RAGE", "UNIT_MAXRAGE",
		"UNIT_ENERGY", "UNIT_MAXENERGY", "UNIT_FOCUS", "UNIT_MAXFOCUS",
		"UNIT_DISPLAYPOWER",
	}
	for i = 1, table.getn(powerEvents) do
		WM.On(powerEvents[i], OnUnitEvent(UpdatePower))
	end
	WM.On("UNIT_NAME_UPDATE", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_FACTION", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_LEVEL", OnUnitEvent(UpdateIdentity))
	WM.On("UNIT_AURA", function(_, unit)
		if unit == "target" then UpdateTargetAuras() end
	end)
	WM.On("PLAYER_COMBO_POINTS", UpdateCombo)
	WM.On("PLAYER_TARGET_CHANGED", function()
		SyncTargetShown()
		UpdateFrame(target)
		UpdateTargetAuras()
		UpdateCombo()
	end)
	WM.On("PLAYER_ENTERING_WORLD", function()
		SyncTargetShown()
		UpdateFrame(player)
		UpdateFrame(target)
		UpdateTargetAuras()
	end)
end)
