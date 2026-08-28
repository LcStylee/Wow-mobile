--------------------------------------------------------------------------------
-- WowMobile · LootSheet
-- Touch loot window, replacing the (previously boosted) default LootFrame:
-- LOOT_OPENED fills a deck-covering bottom sheet with one big row per loot
-- slot (icon, quality-colored name, count — coin slots arrive from
-- GetLootSlotInfo with their own coin icon/text), tap = loot that slot,
-- "Take all" loots everything; LOOT_SLOT_CLEARED prunes rows and LOOT_CLOSED
-- dismisses the sheet.
--
-- The default LootFrame is suppressed in Blizzard.lua with the established
-- banish technique (unregister events + reparent hidden): its OnHide calls
-- CloseLoot(), so hiding an OPEN default frame would end the loot session —
-- never letting it open sidesteps that entirely, the same way the NPC frames
-- are handled for BottomSheet.lua. Because its events are gone, this module
-- also takes over the three flows the default frame drove:
--   * auto-loot (the LOOT_OPENED autoLoot argument),
--   * LOOT_BIND_CONFIRM → a StaticPopup (boosted by Blizzard.lua) whose
--     accept calls ConfirmLootSlot,
--   * master-looter distribution: under GetLootMethod() == "master",
--     LootSlot() cannot take a slot at/above GetLootThreshold() — the master
--     looter assigns it, so tapping such a slot opens a candidate picker
--     (GetMasterLootCandidate → GiveMasterLoot) instead. Non-masters see
--     Blizzard's own "not the master looter" error from their LootSlot call,
--     same as the default UI. The quality-vs-threshold routing matches the
--     common case but is not exhaustively verified against the live client
--     for edge slots (quest items are the plausible exemption the server may
--     allow through LootSlot); a slot for which GetMasterLootCandidate names
--     NO candidates therefore falls back to a plain LootSlot() attempt
--     instead of a dead-end empty picker (see OpenPicker).
--
-- The sheet sits on FULLSCREEN_DIALOG, above the NPC bottom sheet's DIALOG:
-- loot can arrive while a merchant/gossip sheet is open (chest next to a
-- vendor, mid-fight corpse) and must never dismiss that interaction, so it
-- deliberately stays OUT of the deck's exclusive system and just covers
-- whatever is below until the transient loot session ends. It covers only the
-- deck's UPPER band (chat / unit row / xp block), stopping above the main
-- action bar: mid-combat looting is a supported flow and the bottom band is
-- the region the architecture reserves for thumb-reach combat controls, so
-- both action bars and the bottom row stay tappable while the sheet is up.
-- All of this is insecure UI, so mid-combat looting works untouched.
--------------------------------------------------------------------------------

local _, WM = ...

local ROW_H = 110
local GAP = 8

local sheet, scroller, titleText, takeAllButton
local rows = {} -- pooled row buttons

local picker, pickerScroller, pickerTitle -- master-loot candidate list
local pickerRows = {}
local pickerSlot -- loot slot the open picker is assigning; nil when closed

-- True when tapping this slot must go through master-looter assignment: we
-- are the master looter (GetLootMethod's second return is the master's party
-- index, 0 = the local player) and the slot's quality is at/above the group
-- threshold, which LootSlot() refuses to take. Coin/low slots stay free
-- LootSlot pickups for everyone.
local function NeedsMasterAssign(slot)
	local method, mlPartyIndex = GetLootMethod()
	if method ~= "master" or mlPartyIndex ~= 0 then return false end
	local _, _, _, _, quality = GetLootSlotInfo(slot)
	return (quality or 0) >= GetLootThreshold()
end

local function TakeAll()
	-- Loot slot indices are stable for the whole session: a looted slot fires
	-- LOOT_SLOT_CLEARED and simply reads empty from then on — nothing
	-- renumbers, so iteration order is free (reverse kept as convention only).
	-- Master-assign slots are skipped: they need a per-slot candidate choice,
	-- so "Take all" sweeps the freely lootable ones and leaves the rest listed.
	for i = GetNumLootItems(), 1, -1 do
		if not NeedsMasterAssign(i) then
			LootSlot(i)
		end
	end
end

local function HidePicker()
	pickerSlot = nil
	if picker then picker:Hide() end
end

-- Master-loot candidate picker: one big row per eligible group member, tap =
-- GiveMasterLoot. API shape: GiveMasterLoot(slot, candidateIndex) and
-- GetMasterLootCandidate(slot, index) take the loot slot as their first
-- argument on every modern client — the per-slot two-argument form replaced
-- the 1.x one-argument candidate list in retail 7.x and is what Classic
-- 1.13+ (and so Era 1.15) ships; Blizzard's own MasterLooterFrame calls it
-- this way. Candidate indices run 1..MAX_RAID_MEMBERS with holes (members
-- out of loot range return nil), so the loop scans the whole range.
-- (Re)build the candidate rows for pickerSlot. Split out of OpenPicker so
-- UPDATE_MASTER_LOOT_LIST can re-render the roster live while the picker is
-- up — in a moving group, members enter/leave loot range mid-choice, and a
-- stale roster would show untappable rows / hide new eligible ones. Returns
-- the row count so OpenPicker can detect a candidate-less slot.
local function RefreshPicker()
	local slot = pickerSlot
	if not slot then return 0 end
	local shown = 0
	for ci = 1, MAX_RAID_MEMBERS or 40 do
		local candidate = GetMasterLootCandidate(slot, ci)
		if candidate then
			shown = shown + 1
			local row = pickerRows[shown]
			if not row then
				row = WM.CreateTouchButton(pickerScroller.child, 100, ROW_H, nil, 30)
				row.label:SetJustifyH("LEFT")
				row.label:ClearAllPoints()
				row.label:SetPoint("LEFT", WM.Px(24), 0)
				pickerRows[shown] = row
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -WM.Px((shown - 1) * (ROW_H + GAP)))
			row:SetPoint("TOPRIGHT", 0, -WM.Px((shown - 1) * (ROW_H + GAP)))
			row:SetHeight(WM.Px(ROW_H))
			row.label:SetWidth(pickerScroller.ContentWidth() - WM.Px(48))
			row.label:SetText(candidate)
			local s, c = slot, ci
			row:SetScript("OnClick", function()
				GiveMasterLoot(s, c) -- success clears the slot → LOOT_SLOT_CLEARED closes us
			end)
			row:Show()
		end
	end
	for i = shown + 1, #pickerRows do
		pickerRows[i]:Hide()
	end
	pickerScroller.SetContentHeight(WM.Px(shown * (ROW_H + GAP)))
	return shown
end

local function OpenPicker(slot)
	pickerSlot = slot
	local _, name, _, _, quality = GetLootSlotInfo(slot)
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	pickerTitle:SetText(q and string.format("Give |cff%02x%02x%02x%s|r to:",
		q.r * 255, q.g * 255, q.b * 255, name or "?") or ("Give " .. (name or "?") .. " to:"))
	if RefreshPicker() == 0 then
		-- No candidates for this slot: an empty picker could never assign it
		-- (see header — the server may exempt some slots from master
		-- assignment, quest items being the plausible case). Try the plain
		-- take; at worst the server refuses with its own error and the row
		-- stays for another tap.
		pickerSlot = nil
		LootSlot(slot)
		return
	end
	pickerScroller.ScrollToTop()
	picker:Show()
end

local function Rebuild()
	if not sheet:IsShown() then return end
	local num = GetNumLootItems()
	local shown = 0
	for i = 1, num do
		-- Era 1.15 signature (1.13+ modern shape): icon, name, quantity,
		-- currencyID, quality, locked, isQuestItem, questID, isActive.
		local icon, name, quantity, _, quality, locked = GetLootSlotInfo(i)
		if icon then
			shown = shown + 1
			local row = rows[shown]
			if not row then
				row = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 30)
				row.icon = row:CreateTexture(nil, "ARTWORK")
				row.icon:SetSize(WM.Px(80), WM.Px(80))
				row.icon:SetPoint("LEFT", WM.Px(14), 0)
				row.countText = WM.CreateText(row, 24, "OUTLINE")
				row.countText:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
				row.label:ClearAllPoints()
				row.label:SetPoint("LEFT", WM.Px(110), 0)
				row.label:SetJustifyH("LEFT")
				rows[shown] = row
			end
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -WM.Px((shown - 1) * (ROW_H + GAP)))
			row:SetPoint("TOPRIGHT", 0, -WM.Px((shown - 1) * (ROW_H + GAP)))
			row:SetHeight(WM.Px(ROW_H))
			row.icon:SetTexture(icon)
			row.icon:SetDesaturated(locked and true or false)
			row.countText:SetText(quantity and quantity > 1 and quantity or "")
			row.label:SetWidth(scroller.ContentWidth() - WM.Px(130))
			-- Coin slots carry no quality; their multi-line name renders as-is.
			local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
			if q then
				row.label:SetText(string.format("|cff%02x%02x%02x%s|r",
					q.r * 255, q.g * 255, q.b * 255, name or ""))
			else
				row.label:SetText(name or "")
			end
			local slot = i
			-- Master-assignment is decided at TAP time, not rebuild time, so a
			-- loot-method change mid-session routes correctly.
			row:SetScript("OnClick", function()
				if NeedsMasterAssign(slot) then
					OpenPicker(slot)
				else
					LootSlot(slot)
				end
			end)
			WM.AttachTooltip(row, function(tt) tt:SetLootItem(slot) end)
			row:Show()
		end
	end
	for i = shown + 1, #rows do
		rows[i]:Hide()
	end
	titleText:SetText(shown > 0 and ("Loot (" .. shown .. ")") or "Loot")
	WM.SetButtonEnabled(takeAllButton, shown > 0)
	scroller.SetContentHeight(WM.Px(shown * (ROW_H + GAP)))
	-- Everything looted: end the session ourselves instead of leaving an
	-- empty sheet over the deck until LOOT_CLOSED (the resulting LOOT_CLOSED
	-- hides the sheet). num > 0 distinguishes "all cleared" from a session
	-- that opened empty, where the X remains the exit.
	if shown == 0 and num > 0 then
		CloseLoot()
	end
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileLootSheet", UIParent)
	-- Upper deck band only: full deck width, bottom edge stopped just above
	-- the main action bar (WM.Layout.mainBar — published by ActionBars.lua,
	-- which loads and inits earlier; the container frame is created outside
	-- its combat queue, so it exists even on a mid-combat login). Both action
	-- bars and the bottom row stay tappable during mid-combat looting; the
	-- covered unit row / chat are the acceptable cost of the transient sheet.
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("TOPRIGHT", WM.Deck, "TOPRIGHT", 0, 0)
	-- KNOWN DEGRADATION at above-default viewport heights: the sheet is
	-- deckHeight-486 px tall (354 at the default 1080). Above ~1082 the
	-- scroller's content column drops under 240 px and its fixed 120 px
	-- Up/Down buttons start to overlap (Up's effective target shrinks to
	-- ~72 px at the 1130 max) — below the 90 px touch minimum. Same geometry
	-- for the master-loot picker. Acceptable for the transient loot sheet at
	-- a non-default setting; a compact scroller mode is the proper fix if
	-- this ever bites in practice.
	sheet:SetPoint("BOTTOM", WM.Layout.mainBar, "TOP", 0, WM.Px(4))
	sheet:SetFrameStrata("FULLSCREEN_DIALOG")
	sheet:EnableMouse(true) -- swallow taps meant for whatever is underneath
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", WM.Px(24), -WM.Px(26))

	-- >=90 px targets (ARCHITECTURE §4): X 100x96, Take all 260x96.
	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", function()
		CloseLoot() -- LOOT_CLOSED hides the sheet
	end)

	takeAllButton = WM.CreateTouchButton(sheet, 260, 96, "Take all", 32)
	takeAllButton:SetPoint("TOPRIGHT", close, "TOPLEFT", -WM.Px(8), 0)
	local a = WM.Colors.accent
	takeAllButton.borderTex:SetColorTexture(a[1], a[2], a[3], 1)
	takeAllButton:SetScript("OnClick", TakeAll)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	-- Master-loot candidate picker: overlays the sheet (same strata, higher
	-- level via parentage), title + X + scrolling candidate rows.
	picker = CreateFrame("Frame", "WowMobileLootPicker", sheet)
	picker:SetAllPoints(sheet)
	picker:SetFrameLevel(sheet:GetFrameLevel() + 20) -- above rows + scroller buttons
	picker:EnableMouse(true)
	WM.SkinFrame(picker, WM.Colors.panel, WM.Colors.accent)
	picker:Hide()

	pickerTitle = WM.CreateText(picker, 32)
	pickerTitle:SetPoint("TOPLEFT", WM.Px(24), -WM.Px(30))
	pickerTitle:SetPoint("RIGHT", -WM.Px(130), 0)
	pickerTitle:SetJustifyH("LEFT")
	pickerTitle:SetWordWrap(false)

	local pickerClose = WM.CreateTouchButton(picker, 100, 96, "X", 44)
	pickerClose:SetPoint("TOPRIGHT", -WM.Px(4), -WM.Px(4))
	pickerClose:SetScript("OnClick", HidePicker) -- back to the loot list, slot untouched

	local pickerContent = CreateFrame("Frame", nil, picker)
	pickerContent:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(104))
	pickerContent:SetPoint("BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	pickerScroller = WM.Deck.CreateScroller(pickerContent)

	-- BoP confirmation: the default LootFrame raised StaticPopup("LOOT_BIND")
	-- from its (now-unregistered) event handler, so this sheet raises its own
	-- dialog — same accept path, boosted like every popup by Blizzard.lua.
	StaticPopupDialogs["WOWMOBILE_LOOT_BIND"] = {
		text = LOOT_NO_DROP or "Looting this item will bind it to you.",
		button1 = YES,
		button2 = NO,
		OnAccept = function(_, slot) ConfirmLootSlot(slot) end,
		timeout = 0,
		hideOnEscape = 1,
		multiple = 1, -- several BoP items in one "Take all" queue their own popups
	}

	WM.On("LOOT_OPENED", function(_, autoLoot)
		sheet:Show()
		scroller.ScrollToTop()
		Rebuild()
		-- With the default frame's events gone, its auto-loot pass is ours too.
		if autoLoot then TakeAll() end
	end)
	WM.On("LOOT_SLOT_CLEARED", function(_, slot)
		-- A successful GiveMasterLoot clears the slot the picker was
		-- assigning: its job is done, fold it back to the loot list.
		if pickerSlot and slot == pickerSlot then HidePicker() end
		Rebuild()
	end)
	WM.TryOn("LOOT_SLOT_CHANGED", Rebuild)
	-- Candidate roster changed (members moved in/out of loot range): re-render
	-- the open picker so its rows always match who GiveMasterLoot can reach.
	-- TryOn as a guard, but the event exists on Era 1.15 — the classic
	-- LootFrame registers it.
	WM.TryOn("UPDATE_MASTER_LOOT_LIST", function()
		if pickerSlot and picker and picker:IsShown() then RefreshPicker() end
	end)
	WM.On("LOOT_CLOSED", function()
		HidePicker() -- its slot is dead with the session
		sheet:Hide()
		GameTooltip:Hide() -- a row tooltip may still hover over a dead slot
		-- The session can end with BoP confirms still up (walked out of range,
		-- corpse despawn): their slots are dead, so kill every instance —
		-- multiple=1 can have several showing, and StaticPopup_Hide only hides
		-- the first match, so walk the popup frames directly.
		for i = 1, STATICPOPUP_NUMDIALOGS or 4 do
			local popup = _G["StaticPopup" .. i]
			if popup and popup:IsShown() and popup.which == "WOWMOBILE_LOOT_BIND" then
				popup:Hide()
			end
		end
	end)
	WM.On("LOOT_BIND_CONFIRM", function(_, slot)
		StaticPopup_Show("WOWMOBILE_LOOT_BIND", nil, nil, slot)
	end)
end)
