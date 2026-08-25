--------------------------------------------------------------------------------
-- WowMobile · Auras
-- Player buffs/debuffs as large rows along the top edge of the world square.
-- Buffs are tap-cancelable through a transparent overlay of secure
-- type="cancelaura" buttons. Constraints handled here:
--   * cancelaura indices are secure attributes, so they can only be re-synced
--     out of combat (coalesced via the combat queue),
--   * the whole cancel overlay is hidden IN combat by a secure visibility
--     state driver — no cancel affordance in combat, and a stale index can
--     never be tapped,
--   * icons are displayed in native aura-index order (never sorted) so the
--     visual position always matches the secure cancel index beneath it.
--------------------------------------------------------------------------------

local _, WM = ...

local MAX_BUFFS = 9
local MAX_DEBUFFS = 9
local ICON = 84
local GAP = 6

local buffCells, debuffCells, cancelButtons = {}, {}, {}
local cancelHeader

--------------------------------------------------------------------------------
-- Display cells (insecure: always updatable, tooltips only)
--------------------------------------------------------------------------------

local function CreateCell(parent, index, isDebuff)
	local cell = CreateFrame("Button", nil, parent)
	cell:SetSize(WM.Px(ICON), WM.Px(ICON))
	cell:SetPoint("TOPLEFT", WM.Px((index - 1) * (ICON + GAP)), 0)
	cell.border = cell:CreateTexture(nil, "BACKGROUND")
	cell.border:SetAllPoints()
	cell.border:SetColorTexture(0.28, 0.28, 0.33, 1)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", WM.Px(3), -WM.Px(3))
	cell.icon:SetPoint("BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
	cell.swipe = CreateFrame("Cooldown", nil, cell, "CooldownFrameTemplate")
	cell.swipe:SetAllPoints(cell.icon)
	cell.swipe:SetReverse(true)
	-- cell.remain renders our own duration text; with countdownForCooldowns
	-- on, the widget's built-in numbers would double it.
	cell.swipe:SetHideCountdownNumbers(true)
	cell.count = WM.CreateText(cell, 26, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", -WM.Px(3), WM.Px(2))
	cell.remain = WM.CreateText(cell, 22, "OUTLINE")
	cell.remain:SetPoint("BOTTOM", 0, -WM.Px(24))
	cell.remain:SetTextColor(1, 0.85, 0.1)
	WM.AttachTooltip(cell, function(tt, self)
		if isDebuff then
			tt:SetUnitDebuff("player", self.auraIndex)
		else
			tt:SetUnitBuff("player", self.auraIndex)
		end
	end)
	cell:Hide()
	return cell
end

local function UpdateCellRow(cells, filter, maxCells)
	local shown = 0
	for i = 1, maxCells do
		local name, icon, count, dispelType, duration, expirationTime = WM.GetAura("player", i, filter)
		if not name then break end
		shown = i
		local cell = cells[i]
		cell.auraIndex = i
		cell.icon:SetTexture(icon)
		cell.count:SetText(count and count > 1 and count or "")
		cell.expirationTime = expirationTime and expirationTime > 0 and expirationTime or nil
		if duration and duration > 0 and expirationTime then
			cell.swipe:SetCooldown(expirationTime - duration, duration)
		else
			cell.swipe:Clear()
		end
		if filter == "HARMFUL" then
			local c = DebuffTypeColor[dispelType or "none"] or DebuffTypeColor["none"]
			cell.border:SetColorTexture(c.r, c.g, c.b, 1)
		end
		cell:Show()
	end
	for i = shown + 1, maxCells do
		cells[i]:Hide()
		cells[i].expirationTime = nil
	end
	return shown
end

--------------------------------------------------------------------------------
-- Secure cancel overlay
--------------------------------------------------------------------------------

local function SyncCancelButtons()
	-- Runs only out of combat (queued): attribute writes and Show/Hide on
	-- protected frames are blocked in lockdown.
	for i = 1, MAX_BUFFS do
		local name = WM.GetAura("player", i, "HELPFUL")
		local btn = cancelButtons[i]
		if name then
			btn:SetAttribute("index", i)
			btn:Show()
		else
			btn:Hide()
		end
	end
end

local function Refresh()
	UpdateCellRow(buffCells, "HELPFUL", MAX_BUFFS)
	UpdateCellRow(debuffCells, "HARMFUL", MAX_DEBUFFS)
	-- Insecure visuals updated above are combat-safe; the secure index sync
	-- coalesces until the fight ends.
	WM.OutOfCombat("aura-cancel-sync", SyncCancelButtons)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Rows are width-limited so they never collide with the minimap in the
	-- top-right corner of the world square.
	local buffRow = CreateFrame("Frame", "WowMobileBuffRow", WM.WorldSquare)
	buffRow:SetPoint("TOPLEFT", WM.Px(10), -WM.Px(10))
	buffRow:SetSize(WM.Px(MAX_BUFFS * (ICON + GAP)), WM.Px(ICON))

	local debuffRow = CreateFrame("Frame", "WowMobileDebuffRow", WM.WorldSquare)
	debuffRow:SetPoint("TOPLEFT", buffRow, "BOTTOMLEFT", 0, -WM.Px(30))
	debuffRow:SetSize(WM.Px(MAX_DEBUFFS * (ICON + GAP)), WM.Px(ICON))

	for i = 1, MAX_BUFFS do
		buffCells[i] = CreateCell(buffRow, i, false)
	end
	for i = 1, MAX_DEBUFFS do
		debuffCells[i] = CreateCell(debuffRow, i, true)
	end

	-- Overlay host whose visibility a secure driver flips: shown out of
	-- combat, hidden in combat. Hiding the parent hides every cancel button
	-- (and its "x" badge) without any insecure Show/Hide in lockdown.
	-- Creation/anchoring/attributes are protected-frame work → queued for the
	-- mid-combat-login case.
	WM.OutOfCombat("aura-cancel-build", function()

	cancelHeader = CreateFrame("Frame", "WowMobileAuraCancelHeader", buffRow, "SecureHandlerBaseTemplate")
	cancelHeader:SetAllPoints()

	for i = 1, MAX_BUFFS do
		local btn = CreateFrame("Button", "WowMobileCancelBuff" .. i, cancelHeader, "SecureActionButtonTemplate")
		btn:SetSize(WM.Px(ICON), WM.Px(ICON))
		btn:SetPoint("TOPLEFT", WM.Px((i - 1) * (ICON + GAP)), 0)
		WM.RegisterSecureClicks(btn) -- CVar-selected click edge, see Core.lua
		btn:SetAttribute("type", "cancelaura")
		btn:SetAttribute("unit", "player")
		btn:SetAttribute("index", i)
		-- Cancel affordance badge: parented to the secure button so it
		-- disappears with the overlay in combat.
		local badge = WM.CreateText(btn, 24, "OUTLINE")
		badge:SetPoint("TOPRIGHT", -WM.Px(2), -WM.Px(1))
		badge:SetText("x")
		badge:SetTextColor(1, 0.4, 0.4)
		-- Tooltip still works from the overlay (it covers the display cell).
		WM.AttachTooltip(btn, function(tt, self)
			tt:SetUnitBuff("player", self:GetAttribute("index"))
		end)
		btn:Hide()
		cancelButtons[i] = btn
	end

	RegisterStateDriver(cancelHeader, "visibility", "[combat] hide; show")
	SyncCancelButtons()

	end) -- WM.OutOfCombat("aura-cancel-build")

	Refresh()
	WM.On("UNIT_AURA", function(_, unit)
		if unit == "player" then Refresh() end
	end)
	WM.On("PLAYER_ENTERING_WORLD", Refresh)

	-- Remaining-duration text (the sanctioned cooldown-text style ticker).
	local cellRows = { buffCells, debuffCells }
	C_Timer.NewTicker(1, function()
		local now = GetTime()
		for _, cells in next, cellRows do
			for i = 1, #cells do
				local cell = cells[i]
				if cell:IsShown() and cell.expirationTime then
					local remain = cell.expirationTime - now
					cell.remain:SetText(remain > 0 and WM.FormatDuration(remain) or "")
				elseif cell:IsShown() then
					cell.remain:SetText("")
				end
			end
		end
	end)
end)
