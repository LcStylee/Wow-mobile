--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · RollFrames
-- Group need/greed rolls as big touch rows pinned above the deck, replacing
-- GroupLootFrame1..4 (banished in Blizzard.lua). Each row: item icon (tap =
-- tooltip via the injected hover), quality-colored name, a draining timer
-- bar, and NEED / GREED / PASS buttons.
--
-- 1.12 roll API (verified against vanilla FrameXML LootFrame.lua — all
-- roll/master-loot Lua lives there; no GroupLootFrame.lua exists in 1.12 — AND
-- UIParent.lua — the split matters: UIParent registers/handles
-- START_LOOT_ROLL and calls GroupLootFrame_OpenNewFrame(arg1, arg2); the
-- GroupLootFrames themselves only register CANCEL_LOOT_ROLL in OnLoad.
-- Blizzard.lua therefore unregisters START_LOOT_ROLL on UIParent as part of
-- the banish; this module listens for it on the addon dispatcher):
--   START_LOOT_ROLL(rollID, rollTime-ms) starts a roll; CANCEL_LOOT_ROLL
--   (rollID) ends it (fires when the roll resolves or expires).
--   GetLootRollItemInfo(rollID) -> texture, name, count, quality;
--   GameTooltip:SetLootRollItem(rollID); RollOnLoot(rollID, rollType) with
--   0 = pass, 1 = need, 2 = greed — the exact values the default frame's
--   Pass/Need/Greed buttons pass. Rows track their own deadline from the
--   event's rollTime (defaulting to 60 s if a build omits arg2) instead of
--   polling GetLootRollTimeLeft, and also hide themselves locally when the
--   deadline passes in case the server's CANCEL is dropped.
--   NOTE: 1.12.1 DOES have CONFIRM_LOOT_ROLL (UIParent.lua registers and
--   handles it via StaticPopupDialogs["CONFIRM_LOOT_ROLL"], whose OnAccept
--   calls ConfirmLootRoll) — UIParent still raises that (boosted) popup, so
--   this module wires nothing extra. What it MUST do is keep the row alive
--   after a Need/Greed tap on a BoP item: if the confirm popup is cancelled
--   or evicted, the player needs the row to retry, exactly like the default
--   frame, which stays up until CANCEL_LOOT_ROLL. Rows therefore hide
--   immediately only on Pass or for non-BoP items (GetLootRollItemInfo's
--   5th return, bindOnPickUp); BoP rows mark the chosen button and wait for
--   CANCEL_LOOT_ROLL / the local deadline.
--
-- Layout (design px): rows stack bottom-up in the square's bottom-right,
-- above the carry-bar lane MoveMode.lua owns (bottom offsets 0..130 — rows
-- start at 140). MoveMode's split stepper is taller (offsets 130..430, same
-- x band): while it is open, rows hop up to offset 438 (Move.SplitShown /
-- Move.onSplitToggle wiring below) so Need/Greed/Pass are never buried under
-- the stepper's DIALOG strata. Width 580 keeps every button at x >= 492,
-- clear of the client joystick's first-touch capture zone (x <= 486,
-- y >= 594; budget tables in Pet.lua / QuickBar.lua). Four simultaneous rows
-- top out at 140 + 3*(172+8) + 172 = 852 px above the square's bottom —
-- still below the debuff row (y 124..208 from the top, i.e. bottom edge 872
-- px up on the default 1080 square, per Auras.lua), though only by 20 px.
-- That budget only holds at the DEFAULT square: viewport.height is a knob
-- (Config bounds 648..~1130, per QuickBar.lua), and at 648 row 3 (500..672)
-- would poke past the square's top and row 4 (680..852) would sit entirely
-- off-screen — as would the hopped lane's row 4 even at 1080. Relayout
-- therefore clamps every row's bottom offset so its top never leaves the
-- square: overflow rows pin at the top and overlap. To make the overlap
-- hit-test DETERMINISTIC, CreateRow assigns each row an explicitly
-- ascending frame level (i * 5, set before its children are created so
-- the buttons inherit it) — z-order among equal strata+level frames is
-- unspecified on 1.12, so without this a covered row's buttons could take
-- the tap. With it, the later pinned row genuinely covers earlier ones,
-- and each covered row surfaces as the ones above it resolve (the local-
-- deadline auto-hide is the backstop), so no roll ever ends up with
-- unreachable buttons.
--------------------------------------------------------------------------------

local WM = WowMobile

local MAX_ROWS = NUM_GROUP_LOOT_FRAMES or 4
local ROW_W = 580
local ROW_H = 172
local GAP = 8
local LANE = 140       -- bottom offset; MoveMode's carry bar owns 0..130
local LANE_SPLIT = 438 -- while MoveMode's split stepper (130..430) is open

local rows = {}

local function QualityColoredName(name, quality)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		return string.format("|cff%02x%02x%02x%s|r", q.r * 255, q.g * 255, q.b * 255, name)
	end
	return name
end

-- Restack the visible rows bottom-up above the carry lane — or above the
-- split stepper while it is open (see the layout note in the header).
local function Relayout()
	local lane = LANE
	if WM.MoveMode and WM.MoveMode.SplitShown and WM.MoveMode.SplitShown() then
		lane = LANE_SPLIT
	end
	-- Clamp each row's top to the square (see the layout note in the header:
	-- reduced viewport.height, or the hopped lane, can't fit the full stack).
	-- Overflow rows pin at the top and overlap; rows[] is in creation order
	-- and CreateRow gives row i the explicit frame level i*5, so a later
	-- pinned row genuinely covers an earlier one and wins the hit-test until
	-- it resolves and Relayout re-runs.
	local maxOff = ((WM.Viewport and WM.Viewport.HeightPx()) or 1080) - ROW_H
	local idx = 0
	for i = 1, table.getn(rows) do
		local row = rows[i]
		if row:IsShown() then
			local off = lane + idx * (ROW_H + GAP)
			if off > maxOff then off = maxOff end
			row:ClearAllPoints()
			row:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT",
				-WM.Px(8), WM.Px(off))
			idx = idx + 1
		end
	end
end

local function HideRow(row)
	row.rollID = nil
	row.iconBtn.rollID = nil
	row:Hide()
	Relayout()
end

-- GetLootRollItemInfo's 5th return is bindOnPickUp on 1.12 (the default
-- LootFrame code reads the same position).
local function RollIsBoP(rollID)
	local _, _, _, _, bop = GetLootRollItemInfo(rollID)
	return bop and bop ~= 0
end

-- Grey the unchosen buttons so a BoP row waiting on its confirm popup reads
-- as "answered". Buttons stay live: a cancelled confirm can be retried, and
-- ShowRoll restores every base color when the row is reused.
local function MarkChosen(row, rollType)
	for j = 1, 3 do
		local b = row.rollButtons[j]
		if b.rollType == rollType then
			b.label:SetTextColor(b.baseColor[1], b.baseColor[2], b.baseColor[3])
		else
			b.label:SetTextColor(0.45, 0.45, 0.5)
		end
	end
end

-- Draining timer; frame-granularity SetValue only — no allocations.
local function RowOnUpdate()
	local remain = this.endTime - GetTime()
	if remain <= 0 then
		HideRow(this)
	else
		this.timer:SetValue(remain)
	end
end

local function CreateRow(i)
	local row = CreateFrame("Frame", "WowMobileRollRow" .. i, UIParent)
	row:SetWidth(WM.Px(ROW_W))
	row:SetHeight(WM.Px(ROW_H))
	row:SetFrameStrata("HIGH")
	-- Explicit ascending level so overlapping pinned rows (Relayout's
	-- overflow clamp) have a DEFINED z-order: equal strata+level hit-testing
	-- is unspecified on 1.12 and can reshuffle across Hide/Show cycles. Set
	-- BEFORE the children are created so the buttons inherit level+1 of the
	-- raised level deterministically.
	row:SetFrameLevel(row:GetFrameLevel() + i * 5)
	row:EnableMouse(true) -- swallow stray taps between the buttons
	WM.SkinFrame(row, WM.Colors.panel)
	row:Hide()

	local iconBtn = CreateFrame("Button", nil, row)
	iconBtn:SetWidth(WM.Px(92))
	iconBtn:SetHeight(WM.Px(92))
	iconBtn:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(10), -WM.Px(10))
	WM.SkinFrame(iconBtn, { 0.06, 0.06, 0.07, 1 })
	iconBtn.icon = iconBtn:CreateTexture(nil, "ARTWORK")
	iconBtn.icon:SetPoint("TOPLEFT", iconBtn, "TOPLEFT", WM.Px(3), -WM.Px(3))
	iconBtn.icon:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -WM.Px(3), WM.Px(3))
	iconBtn.count = WM.CreateText(iconBtn, 24, "OUTLINE")
	iconBtn.count:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	-- Tooltip on tap: the injected hover preceding every tap fires OnEnter,
	-- anchored above the finger (Core helper).
	WM.AttachTooltip(iconBtn, function(tt, self)
		if self.rollID then
			tt:SetLootRollItem(self.rollID)
		end
	end)
	row.iconBtn = iconBtn

	row.name = WM.CreateText(row, 28)
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(114), -WM.Px(14))
	row.name:SetJustifyH("LEFT")
	row.name:SetWidth(WM.Px(ROW_W - 128))
	WM.SingleLine(row.name, 28)

	row.timer = CreateFrame("StatusBar", nil, row)
	row.timer:SetStatusBarTexture(WM.TEX_WHITE)
	row.timer:SetStatusBarColor(1, 0.82, 0)
	row.timer:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(114), -WM.Px(56))
	row.timer:SetPoint("TOPRIGHT", row, "TOPRIGHT", -WM.Px(12), -WM.Px(56))
	row.timer:SetHeight(WM.Px(12))
	local tbg = row.timer:CreateTexture(nil, "BACKGROUND")
	tbg:SetAllPoints(row.timer)
	tbg:SetTexture(0.05, 0.05, 0.06, 1)

	local defs = {
		{ label = "Need",  rollType = 1, color = { 0.30, 0.80, 0.35 } },
		{ label = "Greed", rollType = 2, color = { 1.00, 0.82, 0.00 } },
		{ label = "Pass",  rollType = 0, color = { 0.70, 0.70, 0.75 } },
	}
	local bw = (ROW_W - 20 - 2 * GAP) / 3
	local prev
	for j = 1, 3 do
		local d = defs[j]
		local b = WM.CreateTouchButton(row, bw, 90, d.label, 30)
		if prev then
			b:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", WM.Px(GAP), 0)
		else
			b:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(10), WM.Px(10))
		end
		b.label:SetTextColor(d.color[1], d.color[2], d.color[3])
		b.rollType = d.rollType
		b.baseColor = d.color
		b.row = row
		row.rollButtons = row.rollButtons or {}
		row.rollButtons[j] = b
		b:SetScript("OnClick", function()
			local row = this.row
			if not row.rollID then
				HideRow(row)
				return
			end
			RollOnLoot(row.rollID, this.rollType)
			-- Pass never confirms, and non-BoP need/greed registers
			-- server-side without a popup — safe to drop the row at once.
			-- BoP need/greed raises UIParent's CONFIRM_LOOT_ROLL popup: keep
			-- the row so a cancelled/evicted confirm can be retried (the
			-- server's CANCEL_LOOT_ROLL, or the local deadline, closes it).
			if this.rollType == 0 or not RollIsBoP(row.rollID) then
				HideRow(row)
			else
				MarkChosen(row, this.rollType)
			end
		end)
		prev = b
	end

	row:SetScript("OnUpdate", RowOnUpdate)
	rows[i] = row
	return row
end

local function ShowRoll(rollID, rollTime)
	-- First free row; like the default UI, at most MAX_ROWS simultaneous
	-- rolls are displayed.
	local row
	for i = 1, MAX_ROWS do
		local r = rows[i] or CreateRow(i)
		if not r:IsShown() then
			row = r
			break
		end
	end
	if not row then return end
	local texture, name, count, quality = GetLootRollItemInfo(rollID)
	row.rollID = rollID
	row.iconBtn.rollID = rollID
	-- Reused rows may carry a previous BoP roll's MarkChosen dimming.
	for j = 1, 3 do
		local b = row.rollButtons[j]
		b.label:SetTextColor(b.baseColor[1], b.baseColor[2], b.baseColor[3])
	end
	row.iconBtn.icon:SetTexture(texture or WM.TEX_QUESTION)
	row.iconBtn.count:SetText(count and count > 1 and count or "")
	row.name:SetText(QualityColoredName(name or "", quality))
	local secs = (rollTime and rollTime > 0 and rollTime / 1000) or 60
	row.endTime = GetTime() + secs
	row.timer:SetMinMaxValues(0, secs)
	row.timer:SetValue(secs)
	row:Show()
	Relayout()
end

WM.OnInit(function()
	-- Re-lane the rows whenever MoveMode's split stepper opens/closes
	-- (MoveMode.lua loads earlier, so WM.MoveMode exists by init time).
	if WM.MoveMode then
		WM.MoveMode.onSplitToggle = Relayout
	end

	-- Re-clamp against the new square height if viewport.height changes
	-- while rolls are visible (Relayout's maxOff reads WM.Viewport.HeightPx).
	WM.Viewport.OnApply(Relayout)

	WM.On("START_LOOT_ROLL", function(_, rollID, rollTime)
		ShowRoll(rollID, rollTime)
	end)
	WM.On("CANCEL_LOOT_ROLL", function(_, rollID)
		for i = 1, table.getn(rows) do
			if rows[i].rollID == rollID then
				HideRow(rows[i])
			end
		end
	end)
end)
