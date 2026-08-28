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
--   quality (quantity is 0 for coin slots — the default LootFrame keys its
--   coin path off that; LootSlotIsCoin exists too and is preferred when
--   present), LootSlot(slot), CloseLoot(), GameTooltip:SetLootItem(slot).
--   BoP confirmation: LOOT_BIND_CONFIRM(slot) -> the Blizzard "LOOT_BIND"
--   StaticPopup (touch-boosted in Blizzard.lua), whose OnAccept runs
--   ConfirmLootSlot(data). The default UI raises that popup from LootFrame's
--   OnEvent — with LootFrame's events gone, this module raises it instead.
--
-- Every slot is a full-width ~110 px row (icon, quality-colored name, count;
-- coin rows gold-tinted); tap = loot that slot; "Take all" sweeps every slot
-- (BoP slots detour through the confirm popup). The sheet closes on
-- LOOT_CLOSED and closes the loot itself when every slot has been taken.
-- The default frame's auto-loot pass is also taken over: 1.12
-- LootFrame_OnShow sweeps all slots when the "autoLootCorpse" CVar is on,
-- with a held Shift key inverting the setting — reproduced in ShowSheet
-- below, since LootFrame's events (and thus its OnShow) are gone.
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 110
local GAP = 8

local sheet, scroller, takeAllBtn
local rows = {}

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
-- Lifecycle
--------------------------------------------------------------------------------

local function ShowSheet()
	WM.Deck.YieldTo("loot") -- panels, NPC sheet and world map step aside
	sheet:Show()
	scroller.ScrollToTop()
	Render()
	-- Default-UI auto-loot (see header): autoLootCorpse CVar, Shift inverts.
	-- pcall guards the CVar read against builds that lack it.
	local auto = false
	local ok, v = pcall(GetCVar, "autoLootCorpse")
	if ok and v == "1" then auto = true end
	if IsShiftKeyDown() then auto = not auto end
	if auto then
		-- Reverse order so BoP-confirm detours can't stall earlier slots.
		for slot = GetNumLootItems(), 1, -1 do
			LootSlot(slot)
		end
	end
end

local function HideSheet()
	sheet:Hide()
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
		-- detour through the LOOT_BIND confirm instead of clearing).
		for slot = 1, GetNumLootItems() do
			LootSlot(slot)
		end
	end)

	local content = CreateFrame("Frame", nil, sheet)
	content:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(104))
	content:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	scroller = WM.Deck.CreateScroller(content)

	-- A deck panel / NPC sheet / map taking the stage walks away from the
	-- corpse too (CloseLoot is safe to call with no loot open).
	WM.Deck.RegisterExclusive("loot", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("LOOT_OPENED", ShowSheet)
	WM.On("LOOT_SLOT_CLEARED", Render)
	WM.On("LOOT_CLOSED", HideSheet)
	-- With LootFrame's events unregistered, the BoP confirmation must be
	-- raised here. Data is passed both ways 1.12 StaticPopup accepts it
	-- (4th argument and dialog.data) so OnAccept's ConfirmLootSlot(data)
	-- always sees the slot.
	WM.On("LOOT_BIND_CONFIRM", function(_, slot)
		local dialog = StaticPopup_Show("LOOT_BIND", nil, nil, slot)
		if dialog then dialog.data = slot end
	end)
end)
