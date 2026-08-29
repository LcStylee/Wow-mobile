--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Stable
-- Hunter pet stable as a deck bottom sheet, replacing the default
-- PetStableFrame (banished with events unregistered in Blizzard.lua — its
-- OnHide calls ClosePetStables, so the established suppression technique
-- applies: a merely-hidden frame being Show()n/Hide()n would end the stable
-- session server-side).
--
-- 1.12 stable API (vanilla FrameXML PetStable.lua):
--   * GetStablePetInfo(slot) -> icon, name, level, family, loyalty; slot 0 is
--     the CURRENT pet, slots 1..2 the stable. GetNumStableSlots() -> owned
--     slot count (0..2, NUM_PET_STABLE_SLOTS caps at 2 on vanilla).
--   * Swapping is cursor-based in the default UI (drag a pet portrait onto
--     another slot). The touch flow is TAP-TAP: first tap selects a slot
--     (accent border), second tap on another slot performs
--     PickupStablePet(a) + ClickStablePet(b) — the exact pickup/drop pair
--     the 1.12 PetStable.xml uses (PetStableSlotButton OnDragStart calls
--     PickupStablePet, while both OnClick and OnReceiveDrag call
--     ClickStablePet, the client's drop-onto-slot primitive). A defensive
--     ClearCursor() follows in case the server refused the drop (dead pet,
--     level lock) so no stray pet-cursor lingers over the streamed UI.
--   * Buy Slot: GetNextStableSlotCost() prices the next slot; BuyStableSlot()
--     buys it — confirmed in our overlay (the default flow's popup belonged
--     to the banished frame).
--   * Events: PET_STABLE_SHOW opens, PET_STABLE_UPDATE repaints,
--     PET_STABLE_CLOSED ends the session; UNIT_PET repaints the current-pet
--     cell while open.
--------------------------------------------------------------------------------

local WM = WowMobile

local NUM_SLOTS = NUM_PET_STABLE_SLOTS or 2

local sheet, confirm, buyBtn, hintText
local slotCells = {}   -- [0] = current pet, [1..NUM_SLOTS] = stable slots
local selectedSlot     -- tap-tap swap source (nil = none)

local function IsOpen()
	return sheet ~= nil and sheet:IsShown()
end

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

local function PaintCell(cell)
	local owned = GetNumStableSlots()
	cell.locked = (cell.slot > 0 and cell.slot > owned)
	local icon, name, level, family
	if not cell.locked then
		icon, name, level, family = GetStablePetInfo(cell.slot)
	end
	if cell.locked then
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.10, 0.06, 0.06)
		cell.name:SetText("Locked")
		cell.name:SetTextColor(0.55, 0.4, 0.4)
		cell.sub:SetText("Buy this slot")
	elseif icon or name then
		cell.icon:SetTexture(icon or WM.TEX_QUESTION)
		cell.icon:SetVertexColor(1, 1, 1)
		cell.name:SetText(name or "?")
		cell.name:SetTextColor(0.92, 0.92, 0.92)
		cell.sub:SetText("Level " .. (level or "?") .. "  " .. (family or ""))
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.name:SetText(cell.slot == 0 and "No active pet" or "Empty")
		cell.name:SetTextColor(0.6, 0.6, 0.65)
		cell.sub:SetText("")
	end
	WM.TintBorder(cell, (selectedSlot == cell.slot)
		and WM.Colors.accent or WM.Colors.border)
end

local function PaintAll()
	if not IsOpen() then return end
	for i = 0, NUM_SLOTS do
		PaintCell(slotCells[i])
	end
	local owned, cost = GetNumStableSlots(), nil
	if owned >= NUM_SLOTS then
		buyBtn.label:SetText("All slots bought")
		WM.SetButtonEnabled(buyBtn, false)
		buyBtn.cost = nil
	else
		cost = GetNextStableSlotCost and GetNextStableSlotCost() or nil
		buyBtn.cost = cost
		buyBtn.label:SetText("Buy slot\n" .. WM.FormatMoney(cost or 0))
		WM.SetButtonEnabled(buyBtn, cost ~= nil and GetMoney() >= cost)
	end
	if selectedSlot then
		hintText:SetText("Now tap the slot to swap with — or tap the same slot to cancel.")
	else
		hintText:SetText("Tap a pet, then tap another slot to swap. The active pet is the Current pet cell.")
	end
end

local function TapSlot(slot)
	local cell = slotCells[slot]
	if cell.locked then return end
	if selectedSlot == nil then
		-- Nothing to move out of an empty stable slot; the current-pet cell
		-- may be "empty" too (no pet out) yet still a valid swap TARGET, so
		-- only block empty-source selection for stable slots.
		if slot > 0 then
			local icon, name = GetStablePetInfo(slot)
			if not icon and not name then return end
		end
		selectedSlot = slot
	elseif selectedSlot == slot then
		selectedSlot = nil -- second tap on the same slot cancels
	else
		-- The swap (see header): pick up A (OnDragStart primitive), drop on
		-- B (the OnClick/OnReceiveDrag primitive from 1.12 PetStable.xml).
		PickupStablePet(selectedSlot)
		ClickStablePet(slot)
		-- Defensive: if the server refused the drop the pet cursor would
		-- linger; clearing an already-empty cursor is a no-op.
		ClearCursor()
		selectedSlot = nil
		-- PET_STABLE_UPDATE repaints with the server's result.
	end
	PaintAll()
end

local function CreateCell(slot)
	-- Three 330x220 cells across the 1064 px sheet content: 3*330 + 2*12 =
	-- 1014. Icon 96, name, level/family line — all far past the touch floor.
	local cell = CreateFrame("Button", nil, sheet)
	cell:SetWidth(WM.Px(330))
	cell:SetHeight(WM.Px(220))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.slot = slot
	cell.title = WM.CreateText(cell, 24)
	cell.title:SetPoint("TOP", cell, "TOP", 0, -WM.Px(10))
	cell.title:SetText(slot == 0 and "Current pet" or ("Stable slot " .. slot))
	cell.title:SetTextColor(1, 0.82, 0)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetWidth(WM.Px(96))
	cell.icon:SetHeight(WM.Px(96))
	cell.icon:SetPoint("TOP", cell, "TOP", 0, -WM.Px(44))
	cell.name = WM.CreateText(cell, 28)
	cell.name:SetPoint("TOP", cell.icon, "BOTTOM", 0, -WM.Px(8))
	cell.name:SetWidth(WM.Px(300))
	cell.name:SetJustifyH("CENTER")
	WM.SingleLine(cell.name, 28)
	cell.sub = WM.CreateText(cell, 22)
	cell.sub:SetPoint("BOTTOM", cell, "BOTTOM", 0, WM.Px(10))
	cell.sub:SetTextColor(0.65, 0.65, 0.7)
	cell:SetScript("OnClick", function()
		TapSlot(this.slot)
	end)
	-- Tooltip above the finger: the default stable tooltips need the banished
	-- frame's paperdoll plumbing, so a plain text summary stands in.
	WM.AttachTooltip(cell, function(tt, self)
		if self.locked then
			tt:SetText("Locked stable slot — buy it below")
			return
		end
		local _, name, level, family, loyalty = GetStablePetInfo(self.slot)
		if name then
			tt:SetText(name)
			if level or family then
				tt:AddLine("Level " .. (level or "?") .. " " .. (family or ""), 0.8, 0.8, 0.85)
			end
			if loyalty then
				tt:AddLine(loyalty, 0.6, 0.8, 1.0)
			end
		else
			tt:SetText(self.slot == 0 and "No active pet" or "Empty stable slot")
		end
	end)
	return cell
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function Dismiss()
	ClosePetStables()
	sheet:Hide()
end

WM.OnInit(function()
	sheet = CreateFrame("Frame", "WowMobileStableSheet", UIParent)
	sheet:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	sheet:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	sheet:SetFrameStrata("DIALOG")
	sheet:EnableMouse(true)
	WM.SkinFrame(sheet, WM.Colors.panel)
	sheet:Hide()

	local titleText = WM.CreateText(sheet, 40)
	titleText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText("Pet Stable")

	local close = WM.CreateTouchButton(sheet, 100, 96, "X", 44)
	close:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", Dismiss)

	for i = 0, NUM_SLOTS do
		local cell = CreateCell(i)
		cell:SetPoint("TOPLEFT", sheet, "TOPLEFT",
			WM.Px(8 + i * 342), -WM.Px(112))
		slotCells[i] = cell
	end

	buyBtn = WM.CreateTouchButton(sheet, 340, 110, "Buy slot", 28)
	buyBtn:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(8), -WM.Px(348))
	buyBtn:SetScript("OnClick", function()
		if not this.cost then return end
		confirm.Ask("Buy the next stable slot for " ..
			WM.FormatMoney(this.cost) .. "?", "Buy slot", function()
			BuyStableSlot()
		end)
	end)

	hintText = WM.CreateText(sheet, 26)
	hintText:SetPoint("TOPLEFT", sheet, "TOPLEFT", WM.Px(372), -WM.Px(360))
	hintText:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -WM.Px(24), -WM.Px(360))
	hintText:SetJustifyH("LEFT")
	hintText:SetTextColor(0.7, 0.7, 0.75)

	confirm = WM.CreateConfirmOverlay(sheet)

	-- A deck panel / NPC sheet / map taking the stage walks away from the
	-- stable master too (ClosePetStables is safe with no stable open).
	WM.Deck.RegisterExclusive("stable", function()
		if sheet:IsShown() then Dismiss() end
	end)

	WM.On("PET_STABLE_SHOW", function()
		WM.Deck.YieldTo("stable")
		selectedSlot = nil
		sheet:Show()
		PaintAll()
	end)
	WM.On("PET_STABLE_UPDATE", function()
		if IsOpen() then PaintAll() end
	end)
	WM.On("PET_STABLE_CLOSED", function()
		sheet:Hide()
	end)
	WM.On("UNIT_PET", function(_, unit)
		if unit == "player" and IsOpen() then PaintAll() end
	end)
	WM.On("PLAYER_MONEY", function()
		if IsOpen() then PaintAll() end
	end)
end)
