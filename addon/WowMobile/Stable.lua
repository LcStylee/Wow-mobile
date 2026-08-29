--------------------------------------------------------------------------------
-- WowMobile · Stable
-- Touch rebuild of the hunter stable (the default PetStableFrame is banished
-- in Blizzard.lua with the established technique — its OnHide calls
-- ClosePetStables and clears a carried pet, which would end the session).
-- One sheet on PET_STABLE_SHOW:
--   * current pet + the stable slots as big cells (icon, name, level +
--     family, loyalty), unpurchased slots rendered locked,
--   * swap via TAP-TAP: first tap selects a pet (accent border), second tap
--     on another slot performs PickupStablePet(src) + ClickStablePet(dst) —
--     the same pickup/click pair the default frame's drag handlers use
--     (classic_era PetStable.xml), issued back-to-back since a phone has no
--     drag. Indices are 1-based with 1 = the CURRENT pet and 2..N+1 the
--     stable slots (the default frame's GetID()+1 convention). Cursor
--     mutations respect the move rules: combat shows the notice and does
--     nothing (SheetKit.CanMove), never queues.
--   * Buy Slot with GetNextStableSlotCost() behind a two-tap confirm →
--     BuyStableSlot() (the default frame's own purchase call).
-- PET_STABLE_UPDATE / UNIT_PET re-render; PET_STABLE_CLOSED hides the sheet.
--------------------------------------------------------------------------------

local _, WM = ...

local MAX_SLOTS = NUM_PET_STABLE_SLOTS or 2 -- era: 2 purchasable stable slots

local sheet, scroller, st
local selectedIndex   -- 1-based stable API index of the tap-tap source pet
local confirmBuy = false
local Render -- forward: TapSlot re-renders

local function PetLabel(name, level, family, loyalty)
	local s = name or "Empty"
	if level and family then
		s = string.format("%s\n|cff8a8a8fLevel %d %s|r", s, level, family)
	end
	if loyalty and loyalty ~= "" then
		s = s .. "\n|cff8a8a8f" .. loyalty .. "|r"
	end
	return s
end

local function TapSlot(index, purchased, hasPet)
	if not purchased then
		UIErrorsFrame:AddMessage("Buy this stable slot first.", 1, 0.3, 0.3)
		return
	end
	if not selectedIndex then
		if hasPet then
			selectedIndex = index
			Render()
		end
		return
	end
	if selectedIndex == index then
		selectedIndex = nil -- tap the selection again = deselect
		Render()
		return
	end
	if not WM.SheetKit.CanMove() then return end
	-- The default frame's drag pair, back-to-back: pickup the source pet
	-- onto the cursor, click it into the destination (swap when occupied).
	-- The server answers with PET_STABLE_UPDATE, which re-renders.
	PickupStablePet(selectedIndex)
	ClickStablePet(index)
	-- Defensive: a refused placement (e.g. dead pet, level lock) can leave
	-- the pet on the cursor with no visible cursor UI on a phone. A stable
	-- pet's cursor kind is NOT observable via GetCursorInfo (no "pet" kind
	-- exists on this client), so clear unconditionally — a no-op on an
	-- already-empty cursor.
	ClearCursor()
	selectedIndex = nil
	Render()
end

Render = function()
	if not sheet:IsShown() then return end
	st.Reset()

	st.Text("Your money: " .. WM.FormatMoney(GetMoney()), 26)
	st.Text(selectedIndex
		and "Tap another slot to move / swap the selected pet — or tap it again to cancel."
		or "Tap a pet, then tap another slot to move or swap it.", 26, 0.7, 0.7, 0.75)

	-- Current pet (stable API index 1).
	st.Text("Current pet", 32, 1, 0.82, 0)
	do
		local icon, name, level, family, loyalty = GetStablePetInfo(1)
		st.Grid({ {
			icon = icon,
			label = PetLabel(name, level, family, loyalty),
			selected = (selectedIndex == 1),
			tooltip = icon and function(tt)
				tt:SetText(name or "")
				if level and family then
					tt:AddLine(string.format("Level %d %s", level, family), 1, 1, 1)
				end
			end or nil,
			index = 1, hasPet = icon and true or false, purchased = true,
		} }, function(item)
			TapSlot(item.index, item.purchased, item.hasPet)
		end)
	end

	-- Stable slots (API indices 2..MAX_SLOTS+1).
	st.Text("Stable", 32, 1, 0.82, 0)
	local numSlots = GetNumStableSlots() or 0
	local items = {}
	for i = 1, MAX_SLOTS do
		local apiIndex = i + 1
		local purchased = i <= numSlots
		local icon, name, level, family, loyalty
		if purchased then
			icon, name, level, family, loyalty = GetStablePetInfo(apiIndex)
		end
		items[#items + 1] = {
			icon = icon,
			label = purchased and PetLabel(name, level, family, loyalty)
				or "|cff8a8a8fLocked — buy this slot below|r",
			selected = (selectedIndex == apiIndex),
			tooltip = icon and function(tt)
				tt:SetText(name or "")
				if level and family then
					tt:AddLine(string.format("Level %d %s", level, family), 1, 1, 1)
				end
			end or nil,
			index = apiIndex, hasPet = icon and true or false, purchased = purchased,
		}
	end
	st.Grid(items, function(item)
		TapSlot(item.index, item.purchased, item.hasPet)
	end)

	-- Buy the next slot (two-tap confirm, the Bank.lua pattern).
	if numSlots < MAX_SLOTS then
		local cost = GetNextStableSlotCost() or 0
		if confirmBuy then
			st.Row({
				{ label = "Confirm: buy stable slot for " .. WM.FormatMoney(cost),
					green = true,
					disabled = cost > GetMoney(),
					onTap = function()
						confirmBuy = false
						BuyStableSlot()
					end },
				{ label = "Back", onTap = function()
					confirmBuy = false
					Render()
				end },
			})
		else
			local b = st.Button("Buy a stable slot — " .. WM.FormatMoney(cost), nil, function()
				confirmBuy = true
				Render()
			end)
			WM.SetButtonEnabled(b, cost <= GetMoney())
		end
	end

	st.Finish("stable")
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("stable", "Stable")
	sheet.OnDismiss = function()
		-- Mirror the banished default frame's OnHide: end the session and
		-- never strand a pet on the invisible cursor. GetCursorInfo has no
		-- "pet" kind to key on, so clear unconditionally (no-op when empty).
		ClearCursor()
		ClosePetStables() -- PET_STABLE_CLOSED then hides the sheet
	end

	scroller = WM.Deck.CreateScroller(sheet.body)
	st = Kit.NewStack(scroller)

	WM.On("PET_STABLE_SHOW", function()
		selectedIndex, confirmBuy = nil, false
		sheet.Open(UnitName("npc") or "Stable")
		Render()
	end)
	WM.On("PET_STABLE_UPDATE", Render)
	WM.On("PET_STABLE_CLOSED", function()
		selectedIndex, confirmBuy = nil, false
		if sheet:IsShown() then sheet:Hide() end
		st.ClearView()
	end)
	WM.On("UNIT_PET", function(_, unit)
		if unit == "player" then Render() end
	end)
	WM.On("PLAYER_MONEY", function()
		if sheet:IsShown() then Render() end
	end)
end)
