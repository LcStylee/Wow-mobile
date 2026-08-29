--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · LootSheet
-- Looting as a deck bottom sheet, replacing the default LootFrame (which
-- Blizzard.lua banishes with its events unregistered — the established
-- technique; it matters doubly for loot because LootFrame's OnHide handler
-- calls CloseLoot(), so a merely-hidden frame being Show()n/Hide()n by
-- Blizzard code would kill the loot session server-side).
--
-- 1.12 loot API (verified against vanilla FrameXML LootFrame.lua):
--   LOOT_OPENED / LOOT_SLOT_CLEARED(slot) / LOOT_CLOSED,
--   GetNumLootItems(), GetLootSlotInfo(slot) -> texture, item, quantity,
--   quality (the default 1.12 LootFrame_Update keys coin rows off
--   LootSlotIsCoin(slot) / LootSlotIsItem(slot); this module prefers
--   LootSlotIsCoin too, keeping quantity == 0 only as a belt-and-braces
--   fallback for builds lacking it — coin slots do report quantity 0),
--   LootSlot(slot), CloseLoot(), GameTooltip:SetLootItem(slot).
--   BoP confirmation: LOOT_BIND_CONFIRM(slot) -> the Blizzard "LOOT_BIND"
--   StaticPopup (touch-boosted in Blizzard.lua), whose OnAccept runs
--   LootSlot(data) on 1.12 (ConfirmLootSlot is a 2.x API and does not exist
--   here). UIParent's own LOOT_BIND_CONFIRM handler — untouched by the
--   LootFrame banish — still raises that popup; this module re-raises it
--   with identical data only to guarantee dialog.data holds the slot
--   (BindConfirmParked reads it off the live dialog).
--
-- Every slot is a full-width ~110 px row (icon, quality-colored name, count;
-- coin rows gold-tinted); tap = loot that slot; "Take all" sweeps every slot
-- (BoP slots detour through the confirm popup). The sheet closes on
-- LOOT_CLOSED and closes the loot itself when every slot has been taken.
-- Auto-loot: the sweep in ShowSheet APPROXIMATES the 1.12 client's C-side
-- autoLootCorpse/Shift behavior (1.12's LootFrame_OnShow has no such Lua —
-- the CVar is honored client-side). A client-side auto-loot may run in
-- parallel; the addon's sweep is then redundant but harmless (already
-- cleared slots are skipped).
--
-- MASTER LOOT: with LootFrame's events gone, its GroupLootDropDown is gone
-- too, so assignment is rebuilt as a touch candidate picker. 1.12 flow
-- (vanilla FrameXML LootFrame.lua): the master looter's LootSlot(slot) on an
-- above-threshold item makes the server answer with OPEN_MASTER_LOOT_LIST
-- (no args! — the default UI relies on LootFrame.selectedSlot, set in
-- LootButton_OnClick), candidates change fires UPDATE_MASTER_LOOT_LIST,
-- GetMasterLootCandidate(ci) names them (GroupLootDropDown_Initialize scans
-- party indices 1..MAX_PARTY_MEMBERS+1 / raid 1..MAX_RAID_MEMBERS), and
-- GiveMasterLoot(slot, ci) assigns. This module mirrors that: every LootSlot
-- call records its slot in selectedSlot first, OPEN_MASTER_LOOT_LIST opens
-- the picker for it (falling back to the first uncleared item slot when a
-- sweep advanced selectedSlot past the refused one), a candidate row tap
-- runs GiveMasterLoot. Non-master group members can't loot above-threshold
-- slots at all under master loot — that is the server's refusal, identical
-- in the default UI; nothing to rebuild there.
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 110
local GAP = 8

local sheet, scroller, takeAllBtn
local rows = {}

-- Master loot (see header): picker overlay + the last slot handed to
-- LootSlot, because OPEN_MASTER_LOOT_LIST names no slot on 1.12.
local picker, pickerScroller
local candRows = {}
local selectedSlot

-- A slot counts as "parked on a LOOT_BIND confirm" only while its confirm
-- dialog is actually up. A persistent recorded set would go knowably stale:
-- cancelling the popup, or a Take-all sweep across multiple BoP slots making
-- a later StaticPopup_Show override the earlier same-which LOOT_BIND dialog
-- (1.12 reuses it), leaves no dialog for a slot that stayed flagged — and
-- OpenPicker's fallback would then wrongly skip it for the rest of the
-- corpse. So scan the live dialogs instead: 1.12 StaticPopup frames are
-- StaticPopup1..STATICPOPUP_NUMDIALOGS with .which set by StaticPopup_Show.
-- NOTE: 1.12 StaticPopup_Show NILS dialog.data on every show and its 4th
-- argument feeds only the `multiple`-dialog matching — the explicit
-- `dialog.data = slot` assignment in the LOOT_BIND_CONFIRM handler below is
-- the ONLY thing that puts the slot there.
local function BindConfirmParked(slot)
	for i = 1, STATICPOPUP_NUMDIALOGS or 4 do
		local f = getglobal("StaticPopup" .. i)
		if f and f:IsVisible() and f.which == "LOOT_BIND" and f.data == slot then
			return true
		end
	end
	return false
end

local function QualityColoredName(name, quality)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		return string.format("|cff%02x%02x%02x%s|r", q.r * 255, q.g * 255, q.b * 255, name)
	end
	return name
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function AcquireRow(i)
	local row = rows[i]
	if row then return row end
	row = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 30)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(WM.Px(84))
	row.icon:SetHeight(WM.Px(84))
	row.icon:SetPoint("LEFT", row, "LEFT", WM.Px(14), 0)
	row.countText = WM.CreateText(row, 24, "OUTLINE")
	row.countText:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row, "LEFT", WM.Px(116), 0)
	row.label:SetJustifyH("LEFT")
	row:SetScript("OnClick", function()
		selectedSlot = this.slot -- for OPEN_MASTER_LOOT_LIST (no args, header)
		LootSlot(this.slot)
	end)
	WM.AttachTooltip(row, function(tt, self)
		if self.isCoin then
			tt:SetText(self.coinName or "")
		else
			tt:SetLootItem(self.slot)
		end
	end)
	rows[i] = row
	return row
end

local function Render()
	if not sheet:IsShown() then return end
	local n = GetNumLootItems()
	local used = 0
	for slot = 1, n do
		local texture, item, quantity, quality = GetLootSlotInfo(slot)
		if texture then
			used = used + 1
			local row = AcquireRow(used)
			row.slot = slot
			row.isCoin = (LootSlotIsCoin and LootSlotIsCoin(slot)) or quantity == 0
			row.icon:SetTexture(texture)
			row.label:SetWidth(scroller.ContentWidth() - WM.Px(136))
			if row.isCoin then
				-- Coin names arrive multi-line ("1 Silver\n20 Copper").
				local coinName = string.gsub(item or "", "\n", " ")
				row.coinName = coinName
				row.label:SetText("|cffffd700" .. coinName .. "|r")
				row.countText:SetText("")
			else
				row.coinName = nil
				row.label:SetText(QualityColoredName(item or "", quality))
				row.countText:SetText(quantity and quantity > 1 and quantity or "")
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetPoint("TOPRIGHT", scroller.child, "TOPRIGHT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetHeight(WM.Px(ROW_H))
			row:Show()
		end
	end
	for i = used + 1, table.getn(rows) do
		rows[i]:Hide()
	end
	scroller.SetContentHeight(WM.Px(used * (ROW_H + GAP)))
	WM.SetButtonEnabled(takeAllBtn, used > 0)
	if used == 0 then
		-- Everything taken (or an empty corpse): end the session; the
		-- LOOT_CLOSED that follows hides the sheet.
		CloseLoot()
	end
end

--------------------------------------------------------------------------------
-- Master-loot candidate picker (replaces GroupLootDropDown — see header)
--------------------------------------------------------------------------------

local function AcquireCandRow(i)
	local row = candRows[i]
	if row then return row end
	row = WM.CreateTouchButton(pickerScroller.child, 100, ROW_H, nil, 32)
	row.label:SetJustifyH("LEFT")
	row.label:ClearAllPoints()
	row.label:SetPoint("LEFT", row, "LEFT", WM.Px(24), 0)
	-- CreateTouchButton sized the label for a 100 px-wide button; widen it to
	-- the real row width (re-set each RenderPicker, like Render does for loot
	-- rows) and keep names on one line so they never overflow the row.
	row.label:SetWidth(pickerScroller.ContentWidth() - WM.Px(48))
	WM.SingleLine(row.label, 32)
	row:SetScript("OnClick", function()
		if picker.slot and this.candidate then
			GiveMasterLoot(picker.slot, this.candidate)
		end
		-- The LOOT_SLOT_CLEARED that follows re-renders the sheet; close the
		-- picker now rather than waiting on it.
		picker:Hide()
	end)
	candRows[i] = row
	return row
end

local function RenderPicker()
	if not picker or not picker:IsShown() then return end
	local slot = picker.slot
	local _, item, _, quality = GetLootSlotInfo(slot)
	picker.title:SetText("Give " .. QualityColoredName(item or "item", quality) .. " to:")
	local used = 0
	-- Vanilla GroupLootDropDown_Initialize scans GetMasterLootCandidate over
	-- 1..MAX_PARTY_MEMBERS+1 in a party and 1..MAX_RAID_MEMBERS in a raid;
	-- scanning 1..40 unconditionally covers both — out-of-range / offline-
	-- ineligible indices return nil and are skipped.
	for ci = 1, MAX_RAID_MEMBERS or 40 do
		local name = GetMasterLootCandidate(ci)
		if name then
			used = used + 1
			local row = AcquireCandRow(used)
			row.candidate = ci
			row.label:SetWidth(pickerScroller.ContentWidth() - WM.Px(48))
			row.label:SetText(name)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", pickerScroller.child, "TOPLEFT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetPoint("TOPRIGHT", pickerScroller.child, "TOPRIGHT",
				0, -WM.Px((used - 1) * (ROW_H + GAP)))
			row:SetHeight(WM.Px(ROW_H))
			row:Show()
		end
	end
	for i = used + 1, table.getn(candRows) do
		candRows[i]:Hide()
	end
	pickerScroller.SetContentHeight(WM.Px(used * (ROW_H + GAP)))
end

local function OpenPicker(slot)
	-- Validate the recorded slot: a Take-all/auto sweep advances selectedSlot
	-- past the slot the server refused, and may have cleared it since. Fall
	-- back to the first uncleared item slot AT/ABOVE GetLootThreshold() (the
	-- function exists on 1.12; UnitPopup.lua reads it) that is NOT
	-- parked on a live LOOT_BIND confirm (BindConfirmParked). Both filters
	-- matter because "uncleared" alone is NOT "master-refused": a BoP slot
	-- parked awaiting its LOOT_BIND confirm (the sweep's other detour) also
	-- stays uncleared, and GiveMasterLoot on it would be refused by the
	-- server. Parked-ness is read off the live dialog, so a slot whose
	-- confirm was cancelled or overridden is eligible again immediately.
	-- This is a heuristic, not a guarantee — the fallback picks the first
	-- surviving item slot, which the server may still rarely refuse; the
	-- title names the item, so the assignment the user confirms is always
	-- the one displayed, and a refused assignment just errors and leaves the
	-- slot on its row.
	local function IsMasterAssignSlot(s)
		if BindConfirmParked(s) then return false end
		local texture, _, quantity, quality = GetLootSlotInfo(s)
		if not texture then return false end
		if LootSlotIsCoin and LootSlotIsCoin(s) then return false end
		if quantity == 0 then return false end
		return (quality or 0) >= GetLootThreshold()
	end
	if not slot or not IsMasterAssignSlot(slot) then
		slot = nil
		for s = 1, GetNumLootItems() do
			if IsMasterAssignSlot(s) then
				slot = s
				break
			end
		end
	end
	if not slot then return end
	picker.slot = slot
	picker:Show()
	pickerScroller.ScrollToTop()
	RenderPicker()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function ShowSheet()
	WM.Deck.YieldTo("loot") -- panels, NPC sheet and world map step aside
	sheet:Show()
	picker:Hide() -- stale picker from a previous corpse never survives
	selectedSlot = nil
	-- No bind-confirm parking set to wipe: parked-ness is read off the live
	-- LOOT_BIND dialog (BindConfirmParked), and HideSheet's LOOT_CLOSED
	-- cleanup hid any dialog from the previous corpse.
	scroller.ScrollToTop()
	Render()
	-- Auto-loot approximation (see header): autoLootCorpse CVar, Shift
	-- inverts; the client's own C-side pass may also run — redundant but
	-- harmless. pcall guards the CVar read against builds that lack it.
	local auto = false
	local ok, v = pcall(GetCVar, "autoLootCorpse")
	if ok and v == "1" then auto = true end
	if IsShiftKeyDown() then auto = not auto end
	if auto then
		-- Reverse order so BoP-confirm detours can't stall earlier slots.
		-- selectedSlot per call: master-loot refusals answer with
		-- OPEN_MASTER_LOOT_LIST after the loop, and OpenPicker re-validates
		-- (falls back to the first uncleared item slot) — see header.
		for slot = GetNumLootItems(), 1, -1 do
			selectedSlot = slot
			LootSlot(slot)
		end
	end
end

local function HideSheet()
	sheet:Hide()
	-- 1.12's LootFrame_OnEvent hid the BoP confirm on LOOT_CLOSED; with the
	-- frame banished that cleanup lives here — otherwise walking away leaves
	-- an orphaned dialog whose accept fires LootSlot into a closed session.
	-- (LOOT_BIND is not a "multiple" dialog on 1.12: one hide suffices.)
	StaticPopup_Hide("LOOT_BIND")
end

local function Dismiss()
	CloseLoot()
	HideSheet()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileLootSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	local titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Loot")

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	takeAllBtn = WM.CreateTouchButton(sheet, 260, 96, "Take all", 32)
	takeAllBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -WM.Px(8), 0)
	takeAllBtn:SetScript("OnClick", function()
		-- Sweep every slot; slots clear via LOOT_SLOT_CLEARED (BoP slots
		-- detour through the LOOT_BIND confirm instead of clearing; master-
		-- loot slots the server refuses answer with OPEN_MASTER_LOOT_LIST
		-- and open the candidate picker — one at a time, remaining refused
		-- slots stay on their rows for individual taps).
		for slot = 1, GetNumLootItems() do
			selectedSlot = slot
			LootSlot(slot)
		end
	end)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	-- Master-loot candidate picker: full-sheet overlay. Child-above-parent
	-- only beats the sheet frame itself: within one strata 1.12 draws and
	-- hit-tests strictly by frame level, and the loot rows / scroller arrows
	-- are DEEPER descendants (scroller.child children, several levels above
	-- the sheet) — a picker at sheet+1 would sit UNDER them, so any loot row
	-- not exactly covered by a candidate row would bleed through and still
	-- take taps (firing LootSlot behind the overlay). Bump the whole overlay
	-- to FULLSCREEN_DIALOG (the WorldMap.lua / Talents.lua close-button
	-- technique) BEFORE creating its children so they inherit the strata. It
	-- stays a child of the sheet, so it still hides with it on LOOT_CLOSED
	-- automatically. Cancel just closes the picker — the refused slot stays
	-- on its loot row for another tap.
	picker = CreateFrame("Frame", "WowMobileMasterLootPicker", sheet)
	picker:SetFrameStrata("FULLSCREEN_DIALOG")
	picker:SetAllPoints(sheet)
	picker:EnableMouse(true)
	WM.SkinFrame(picker, WM.Colors.panel, WM.Colors.accent)
	picker:Hide()

	picker.title = WM.CreateText(picker, 34)
	picker.title:SetPoint("TOPLEFT", picker, "TOPLEFT", WM.Px(24), -WM.Px(30))
	picker.title:SetJustifyH("LEFT")
	picker.title:SetWidth(WM.Px(760))
	WM.SingleLine(picker.title, 34)

	local pickerClose = WM.CreateTouchButton(picker, 180, 96, "Cancel", 30)
	pickerClose:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	pickerClose:SetScript("OnClick", function() picker:Hide() end)

	local pickerContent = CreateFrame("Frame", nil, picker)
	pickerContent:SetPoint("TOPLEFT", picker, "TOPLEFT", WM.Px(8), -WM.Px(104))
	pickerContent:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	pickerScroller = WM.Deck.CreateScroller(pickerContent)

	-- A deck panel / NPC sheet / map taking the stage walks away from the
	-- corpse too (CloseLoot is safe to call with no loot open).
	WM.Deck.RegisterExclusive("loot", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("LOOT_OPENED", ShowSheet)
	WM.On("LOOT_SLOT_CLEARED", function(_, slot)
		-- The picker's slot clearing (assignment landed, or the item was
		-- looted some other way) closes the picker with it.
		if picker:IsShown() and picker.slot == slot then
			picker:Hide()
		end
		Render()
	end)
	WM.On("LOOT_CLOSED", HideSheet)
	-- Master loot (see header): the server answers a refused LootSlot with
	-- OPEN_MASTER_LOOT_LIST (no args on 1.12 — the slot is the one recorded
	-- before the LootSlot call); candidate-roster changes re-render.
	WM.On("OPEN_MASTER_LOOT_LIST", function()
		OpenPicker(selectedSlot)
	end)
	WM.On("UPDATE_MASTER_LOOT_LIST", RenderPicker)
	-- UIParent's own LOOT_BIND_CONFIRM handler still raises the LOOT_BIND
	-- popup (the LootFrame banish does not touch it); the re-raise below is
	-- redundant and exists so dialog.data is GUARANTEED to hold the slot —
	-- BindConfirmParked keys off it. OnAccept runs LootSlot(data) on 1.12.
	-- 1.12 StaticPopup_Show nils dialog.data on every show (its 4th argument
	-- only feeds `multiple` matching), so the explicit assignment below is
	-- what actually stores the slot; the 4-arg call is kept for the
	-- multiple-dialog bookkeeping only.
	WM.On("LOOT_BIND_CONFIRM", function(_, slot)
		local dialog = StaticPopup_Show("LOOT_BIND", nil, nil, slot)
		if dialog then dialog.data = slot end
	end)
end)
