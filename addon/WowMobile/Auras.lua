--------------------------------------------------------------------------------
-- WowMobile · Auras
-- Player buffs/debuffs as large rows near the top of the world square: the
-- buff row hugs the top edge; the debuff row sits below it, indented right of
-- the left-edge secure columns (budget math at the row anchors in OnInit).
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
-- Debuffs get fewer cells than buffs: their row is indented to x=210 to stay
-- clear of the left-edge stance/pet buttons (anchor comments in OnInit), so
-- only 6 cells + badge fit before the minimap's right-edge budget.
local MAX_DEBUFFS = 6
local ICON = 84
local GAP = 6
-- Overflow badge ("+N") appended after the last cell, at row-local
-- x = maxCells*(ICON+GAP); the per-row screen budgets are recomputed at the
-- row anchors in OnInit.
local BADGE_W = 56
-- Scan ceiling for the overflow count/tooltip; the 1.15 client exposes at
-- most 32 buffs / 16 debuffs per unit, so 40 always terminates via nil.
local MAX_SCAN = 40

local buffCells, debuffCells, cancelButtons = {}, {}, {}
local buffOverflow, debuffOverflow
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

local function UpdateCellRow(cells, filter, maxCells, badge)
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
	-- Auras past the visible cells would otherwise be invisible anywhere in
	-- the touch UI (BuffFrame is banished): surface them as a "+N" badge.
	local extra = 0
	if shown == maxCells then
		for i = maxCells + 1, MAX_SCAN do
			if not WM.GetAura("player", i, filter) then break end
			extra = extra + 1
		end
	end
	if extra > 0 then
		badge.label:SetText("+" .. extra)
		badge:Show()
	else
		badge:Hide()
	end
	return shown
end

-- Overflow badge: insecure, tooltip-only (lists the hidden auras). Cancel by
-- tap is intentionally not offered past the secure overlay's 9 slots.
local function CreateOverflowBadge(parent, filter, maxCells, title)
	local badge = CreateFrame("Button", nil, parent)
	badge:SetSize(WM.Px(BADGE_W), WM.Px(ICON))
	badge:SetPoint("TOPLEFT", WM.Px(maxCells * (ICON + GAP)), 0)
	WM.SkinFrame(badge, { 0.07, 0.07, 0.09, 0.92 })
	badge.label = WM.CreateText(badge, 26, "OUTLINE")
	badge.label:SetPoint("CENTER")
	badge.label:SetTextColor(1, 0.85, 0.1)
	WM.AttachTooltip(badge, function(tt)
		tt:SetText(title)
		for i = maxCells + 1, MAX_SCAN do
			local name, _, count = WM.GetAura("player", i, filter)
			if not name then break end
			tt:AddLine(count and count > 1 and (name .. " (" .. count .. ")") or name,
				0.9, 0.9, 0.9)
		end
	end)
	badge:Hide()
	return badge
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
	UpdateCellRow(buffCells, "HELPFUL", MAX_BUFFS, buffOverflow)
	UpdateCellRow(debuffCells, "HARMFUL", MAX_DEBUFFS, debuffOverflow)
	-- Insecure visuals updated above are combat-safe; the secure index sync
	-- coalesces until the fight ends.
	WM.OutOfCombat("aura-cancel-sync", SyncCancelButtons)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Buff row along the square's top edge (y 10..94), width-limited so it
	-- never collides with the minimap in the top-right corner: 9 cells span
	-- screen x 10..814 (10 inset + 8*90 + 84), the badge x 820..876
	-- (10 + 9*90 .. +56), and the minimap holder starts at x=880 (budget
	-- table in Minimap.lua).
	local buffRow = CreateFrame("Frame", "WowMobileBuffRow", WM.WorldSquare)
	buffRow:SetPoint("TOPLEFT", WM.Px(10), -WM.Px(10))
	buffRow:SetSize(WM.Px(MAX_BUFFS * (ICON + GAP) + BADGE_W), WM.Px(ICON))

	-- Debuff row at y 124..208 (buff-row bottom 94 + 30 gap). That y band is
	-- shared with the tap-critical left-edge secure columns — the stance
	-- column (ActionBars.lua, x 8..96) and the 2x5 pet action block (Pet.lua,
	-- x 8..190), both topped at y=124 — so the row starts at x=210, past the
	-- pet block (the same clearance lane the quest tracker uses,
	-- QuestLog.lua). Width: 6 cells end at screen x 744 (210 + 5*90 + 84),
	-- the badge at 750..806 (210 + 6*90 .. +56) — clear of the minimap zoom
	-- buttons (x>=844, y 206..298) and holder (x>=880); debuffs past 6 fold
	-- into the "+N" badge.
	local debuffRow = CreateFrame("Frame", "WowMobileDebuffRow", WM.WorldSquare)
	debuffRow:SetPoint("TOPLEFT", WM.Px(210), -WM.Px(124))
	debuffRow:SetSize(WM.Px(MAX_DEBUFFS * (ICON + GAP) + BADGE_W), WM.Px(ICON))

	for i = 1, MAX_BUFFS do
		buffCells[i] = CreateCell(buffRow, i, false)
	end
	for i = 1, MAX_DEBUFFS do
		debuffCells[i] = CreateCell(debuffRow, i, true)
	end
	buffOverflow = CreateOverflowBadge(buffRow, "HELPFUL", MAX_BUFFS, "More buffs")
	debuffOverflow = CreateOverflowBadge(debuffRow, "HARMFUL", MAX_DEBUFFS, "More debuffs")

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
