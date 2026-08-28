--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Auras
-- Player buffs/debuffs as large rows near the top of the world square: the
-- buff row hugs the top edge; the debuff row sits below it, indented right of
-- the left-edge button columns (budget math at the row anchors in OnInit).
--
-- 1.12 player auras use the GetPlayerBuff handle API:
--   GetPlayerBuff(i, filter) with i = 0.. returns a buff HANDLE (-1 = none);
--   GetPlayerBuffTexture / GetPlayerBuffApplications /
--   GetPlayerBuffDispelType / GetPlayerBuffTimeLeft read that handle, and
--   CancelPlayerBuff(handle) — NOT the list position — cancels it. Buff rows
--   scan "HELPFUL|PASSIVE" (the default BuffFrame's filter), debuffs
--   "HARMFUL". PLAYER_AURAS_CHANGED is the 1.12 change signal for the player
--   (UNIT_AURA only covers other units reliably).
-- Tapping a buff cell cancels via its stored handle; handles are re-synced on
-- every PLAYER_AURAS_CHANGED so a tap can never act on a stale handle. 1.12
-- has no combat restriction on CancelPlayerBuff, so the cancel affordance
-- stays available in combat.
--------------------------------------------------------------------------------

local WM = WowMobile

local MAX_BUFFS = 9
-- Debuffs get fewer cells than buffs: their row is indented to x=210 to stay
-- clear of the left-edge stance/pet buttons, so only 6 cells + badge fit
-- before the minimap's right-edge budget.
local MAX_DEBUFFS = 6
local ICON = 84
local GAP = 6
local BADGE_W = 56
-- Scan ceiling for the overflow count/tooltip; 1.12 exposes at most 32 player
-- auras per filter, so the handle scan always terminates via -1.
local MAX_SCAN = 32

local FILTER_BUFF = "HELPFUL|PASSIVE"
local FILTER_DEBUFF = "HARMFUL"

local buffCells, debuffCells = {}, {}
local buffOverflow, debuffOverflow

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

local function CreateCell(parent, index, isDebuff)
	local cell = CreateFrame("Button", nil, parent)
	cell:SetWidth(WM.Px(ICON))
	cell:SetHeight(WM.Px(ICON))
	cell:SetPoint("TOPLEFT", parent, "TOPLEFT", WM.Px((index - 1) * (ICON + GAP)), 0)
	cell.border = cell:CreateTexture(nil, "BACKGROUND")
	cell.border:SetAllPoints(cell)
	cell.border:SetTexture(0.28, 0.28, 0.33, 1)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(3), -WM.Px(3))
	cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
	cell.count = WM.CreateText(cell, 26, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(3), WM.Px(2))
	cell.remain = WM.CreateText(cell, 22, "OUTLINE")
	cell.remain:SetPoint("BOTTOM", cell, "BOTTOM", 0, -WM.Px(24))
	cell.remain:SetTextColor(1, 0.85, 0.1)
	WM.AttachTooltip(cell, function(tt, self)
		if self.buffHandle then
			tt:SetPlayerBuff(self.buffHandle)
		end
	end)
	if not isDebuff then
		-- Tap = cancel, via the 1.12 buff handle. Cancel-affordance badge in
		-- the corner.
		local badge = WM.CreateText(cell, 24, "OUTLINE")
		badge:SetPoint("TOPRIGHT", cell, "TOPRIGHT", -WM.Px(2), -WM.Px(1))
		badge:SetText("x")
		badge:SetTextColor(1, 0.4, 0.4)
		cell:SetScript("OnClick", function()
			if this.buffHandle then
				CancelPlayerBuff(this.buffHandle)
			end
		end)
	end
	cell:Hide()
	return cell
end

local function UpdateCellRow(cells, filter, maxCells, badge)
	local shown = 0
	for i = 1, maxCells do
		local handle = GetPlayerBuff(i - 1, filter)
		if handle < 0 then break end
		shown = i
		local cell = cells[i]
		cell.buffHandle = handle
		cell.icon:SetTexture(GetPlayerBuffTexture(handle))
		local count = GetPlayerBuffApplications(handle)
		cell.count:SetText(count and count > 1 and count or "")
		local timeLeft = GetPlayerBuffTimeLeft(handle)
		if timeLeft and timeLeft > 0 then
			cell.expiresAt = GetTime() + timeLeft
		else
			cell.expiresAt = nil
		end
		if filter == FILTER_DEBUFF then
			local dispel = GetPlayerBuffDispelType(handle)
			local c = DebuffTypeColor and (DebuffTypeColor[dispel or "none"] or DebuffTypeColor["none"])
			if c then
				cell.border:SetTexture(c.r, c.g, c.b, 1)
			else
				cell.border:SetTexture(0.85, 0.25, 0.25, 1)
			end
		end
		cell:Show()
	end
	for i = shown + 1, maxCells do
		cells[i]:Hide()
		cells[i].buffHandle = nil
		cells[i].expiresAt = nil
	end
	-- Auras past the visible cells would otherwise be invisible anywhere in
	-- the touch UI (BuffFrame is banished): surface them as a "+N" badge.
	local extra = 0
	if shown == maxCells then
		for i = maxCells + 1, MAX_SCAN do
			if GetPlayerBuff(i - 1, filter) < 0 then break end
			extra = extra + 1
		end
	end
	if extra > 0 then
		badge.label:SetText("+" .. extra)
		badge:Show()
	else
		badge:Hide()
	end
end

-- Overflow badge: tooltip-only (lists the hidden auras).
local function CreateOverflowBadge(parent, filter, maxCells, title)
	local badge = CreateFrame("Button", nil, parent)
	badge:SetWidth(WM.Px(BADGE_W))
	badge:SetHeight(WM.Px(ICON))
	badge:SetPoint("TOPLEFT", parent, "TOPLEFT", WM.Px(maxCells * (ICON + GAP)), 0)
	WM.SkinFrame(badge, { 0.07, 0.07, 0.09, 0.92 })
	badge.label = WM.CreateText(badge, 26, "OUTLINE")
	badge.label:SetPoint("CENTER", badge, "CENTER", 0, 0)
	badge.label:SetTextColor(1, 0.85, 0.1)
	WM.AttachTooltip(badge, function(tt)
		tt:SetText(title)
		for i = maxCells + 1, MAX_SCAN do
			local handle = GetPlayerBuff(i - 1, filter)
			if handle < 0 then break end
			-- 1.12 exposes no aura NAME outside tooltips; list remaining time
			-- instead, which is what the badge is for.
			local timeLeft = GetPlayerBuffTimeLeft(handle)
			if timeLeft and timeLeft > 0 then
				tt:AddLine(WM.FormatDuration(timeLeft) .. " remaining", 0.9, 0.9, 0.9)
			else
				tt:AddLine("no duration", 0.9, 0.9, 0.9)
			end
		end
	end)
	badge:Hide()
	return badge
end

local function Refresh()
	UpdateCellRow(buffCells, FILTER_BUFF, MAX_BUFFS, buffOverflow)
	UpdateCellRow(debuffCells, FILTER_DEBUFF, MAX_DEBUFFS, debuffOverflow)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Buff row along the square's top edge (y 10..94), width-limited so it
	-- never collides with the minimap in the top-right corner: 9 cells span
	-- screen x 10..814 (10 inset + 8*90 + 84), the badge x 820..876, and the
	-- minimap holder starts at x=880 (budget table in Minimap.lua).
	local buffRow = CreateFrame("Frame", "WowMobileBuffRow", WM.WorldSquare)
	buffRow:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(10), -WM.Px(10))
	buffRow:SetWidth(WM.Px(MAX_BUFFS * (ICON + GAP) + BADGE_W))
	buffRow:SetHeight(WM.Px(ICON))

	-- Debuff row at y 124..208 (buff-row bottom 94 + 30 gap). That y band is
	-- shared with the tap-critical left-edge columns — the stance column
	-- (ActionBars.lua, x 8..96) and the 2x5 pet action block (Pet.lua,
	-- x 8..190), both topped at y=124 — so the row starts at x=210, past the
	-- pet block (the same clearance lane the quest tracker uses,
	-- QuestLog.lua). Width: 6 cells end at screen x 744, the badge at
	-- 750..806 — clear of the minimap zoom buttons (x>=844, y 206..298) and
	-- holder (x>=880); debuffs past 6 fold into the "+N" badge.
	local debuffRow = CreateFrame("Frame", "WowMobileDebuffRow", WM.WorldSquare)
	debuffRow:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(210), -WM.Px(124))
	debuffRow:SetWidth(WM.Px(MAX_DEBUFFS * (ICON + GAP) + BADGE_W))
	debuffRow:SetHeight(WM.Px(ICON))

	for i = 1, MAX_BUFFS do
		buffCells[i] = CreateCell(buffRow, i, false)
	end
	for i = 1, MAX_DEBUFFS do
		debuffCells[i] = CreateCell(debuffRow, i, true)
	end
	buffOverflow = CreateOverflowBadge(buffRow, FILTER_BUFF, MAX_BUFFS, "More buffs")
	debuffOverflow = CreateOverflowBadge(debuffRow, FILTER_DEBUFF, MAX_DEBUFFS, "More debuffs")

	Refresh()
	WM.On("PLAYER_AURAS_CHANGED", Refresh)
	WM.On("PLAYER_ENTERING_WORLD", Refresh)

	-- Remaining-duration text (the sanctioned cooldown-text style ticker).
	local cellRows = { buffCells, debuffCells }
	WM.Ticker(1, function()
		local now = GetTime()
		for r = 1, 2 do
			local cells = cellRows[r]
			for i = 1, table.getn(cells) do
				local cell = cells[i]
				if cell:IsShown() and cell.expiresAt then
					local remain = cell.expiresAt - now
					cell.remain:SetText(remain > 0 and WM.FormatDuration(remain) or "")
				elseif cell:IsShown() then
					cell.remain:SetText("")
				end
			end
		end
	end)
end)
