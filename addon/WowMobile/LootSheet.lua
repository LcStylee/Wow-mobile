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
-- also takes over the two flows the default frame drove:
--   * auto-loot (the LOOT_OPENED autoLoot argument),
--   * LOOT_BIND_CONFIRM → a StaticPopup (boosted by Blizzard.lua) whose
--     accept calls ConfirmLootSlot.
--
-- The sheet sits on FULLSCREEN_DIALOG, above the NPC bottom sheet's DIALOG:
-- loot can arrive while a merchant/gossip sheet is open (chest next to a
-- vendor, mid-fight corpse) and must never dismiss that interaction, so it
-- deliberately stays OUT of the deck's exclusive system and just covers
-- whatever is below until the transient loot session ends. All of this is
-- insecure UI, so mid-combat looting works untouched.
--------------------------------------------------------------------------------

local _, WM = ...

local ROW_H = 110
local GAP = 8

local sheet, scroller, titleText, takeAllButton
local rows = {} -- pooled row buttons

local function TakeAll()
	-- Reverse order so earlier LootSlot calls can't shift later indices.
	for i = GetNumLootItems(), 1, -1 do
		LootSlot(i)
	end
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
			row:SetScript("OnClick", function() LootSlot(slot) end)
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
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileLootSheet", UIParent)
	sheet:SetAllPoints(WM.Deck)
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
	WM.On("LOOT_SLOT_CLEARED", Rebuild)
	WM.TryOn("LOOT_SLOT_CHANGED", Rebuild)
	WM.On("LOOT_CLOSED", function()
		sheet:Hide()
		GameTooltip:Hide() -- a row tooltip may still hover over a dead slot
		-- The session can end with BoP confirms still up (walked out of range,
		-- corpse despawn): their slots are dead, so kill every instance —
		-- multiple=1 can have several showing, and StaticPopup_Hide only hides
		-- the first match, so walk the popup frames directly.
		for i = 1, STATICPOPUP_NUMBER_DIALOGS or 4 do
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
