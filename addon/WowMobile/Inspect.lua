--------------------------------------------------------------------------------
-- WowMobile · Inspect
-- Touch view of an inspected player's equipment. The boosted unit menu's
-- Inspect entry keeps driving the flow: it calls InspectUnit → (LoD)
-- Blizzard_InspectUI's InspectFrame_Show → CanInspect + NotifyInspect — the
-- default InspectFrame itself is banished in Blizzard.lua (its OnHide calls
-- ClearInspectPlayer, which would end the session this sheet shows). This
-- module hooks NotifyInspect (the one funnel every inspect request passes
-- through, whoever issues it) to track the pending unit+GUID, and
-- InspectUnit (FrameXML, the unit menu's entry point — the same gate behind
-- which the default InspectFrame opens) to mark that request USER-initiated;
-- INSPECT_READY — present on era 1.15; classic_era Blizzard_InspectUI
-- registers exactly this event — opens the sheet only for a user-initiated
-- request, so background NotifyInspect scans by other addons (gear-score /
-- talent scanners) never pop it, matching the default UI, which only opens
-- for InspectFrame_Show-driven requests. A READY for the already-shown unit
-- refreshes the sheet silently.
--
-- Platform-honest scope: what the era inspect answer reliably serves is the
-- inspected unit's EQUIPMENT (GetInventoryItemTexture/Link on the inspected
-- unit token, and server-backed GameTooltip:SetInventoryItem) — so this
-- sheet is the gear grid with full tooltips. Talents and the inspect honor
-- tab need their own async data flows on top (the vanilla-era default UI
-- has no inspect-talent view at all), and are deliberately left out.
-- Item names can lag the item cache; rows show "..." until a re-render
-- (UNIT_INVENTORY_CHANGED / GET_ITEM_INFO_RECEIVED) fills them.
--
-- The unit token stays live only while it points at the same player: the
-- sheet closes on PLAYER_TARGET_CHANGED (for "target"-token inspects) and on
-- a GUID mismatch, the default frame's own rules.
--------------------------------------------------------------------------------

local _, WM = ...

-- The character panel's paper-doll order, 4x5 (see CharacterPanel.lua for
-- the height budget — same 128 px cells, same content region).
local SLOTS = {
	{ "HeadSlot", "Head" },       { "NeckSlot", "Neck" },
	{ "ShoulderSlot", "Shoulder" },{ "BackSlot", "Back" },
	{ "ChestSlot", "Chest" },     { "ShirtSlot", "Shirt" },
	{ "TabardSlot", "Tabard" },   { "WristSlot", "Wrist" },
	{ "HandsSlot", "Hands" },     { "WaistSlot", "Waist" },
	{ "LegsSlot", "Legs" },       { "FeetSlot", "Feet" },
	{ "Finger0Slot", "Ring 1" },  { "Finger1Slot", "Ring 2" },
	{ "Trinket0Slot", "Trinket 1" },{ "Trinket1Slot", "Trinket 2" },
	{ "MainHandSlot", "Main Hand" },{ "SecondaryHandSlot", "Off Hand" },
	{ "RangedSlot", "Ranged" },
}

local COLS = 4
local CELL = 128
local GAP = 8

local sheet
local cells = {}
local infoText
local inspectUnit, inspectGUID -- the session the sheet is showing
local pendingUnit, pendingGUID -- latest NotifyInspect request (any issuer)
local userGUID                 -- GUID of the last USER-initiated request (InspectUnit)

local function Dismiss()
	if sheet:IsShown() then
		sheet:Hide()
	end
	inspectUnit, inspectGUID, userGUID = nil, nil, nil
	if ClearInspectPlayer then
		ClearInspectPlayer()
	end
end

local function Render()
	local unit = inspectUnit
	if not unit or not UnitExists(unit) or UnitGUID(unit) ~= inspectGUID then
		Dismiss()
		return
	end
	sheet.titleText:SetText("Inspect: " .. (UnitName(unit) or ""))
	local level = UnitLevel(unit) or 0
	local class = UnitClass(unit) or "?"
	local race = UnitRace(unit) or ""
	infoText:SetText(string.format("Level %d %s %s", level, race, class))
	local r, g, b = WM.UnitColor(unit)
	infoText:SetTextColor(r, g, b)

	for i = 1, #cells do
		local cell = cells[i]
		local texture = GetInventoryItemTexture(unit, cell.slotID)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetDesaturated(false)
			local link = GetInventoryItemLink(unit, cell.slotID)
			local quality = link and select(3, GetItemInfo(link))
			local q = quality and quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
			if q then
				cell.borderTex:SetColorTexture(q.r, q.g, q.b, 1)
			else
				local bd = WM.Colors.border
				cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
			end
		else
			cell.icon:SetTexture(cell.emptyTexture or WM.TEX_QUESTION)
			cell.icon:SetDesaturated(true)
			local bd = WM.Colors.border
			cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
		end
	end
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("inspect", "Inspect")
	sheet.OnDismiss = Dismiss

	-- Identity text lives in the left band BESIDE the grid (not above it):
	-- the 4x5 grid alone is 672 px tall — exactly the CharacterPanel budget,
	-- which fits even the tightest content region (678 px) only with the
	-- grid starting at y=0.
	infoText = WM.CreateText(sheet.body, 30)
	infoText:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(10))
	infoText:SetWidth(WM.Px(270))
	infoText:SetJustifyH("LEFT")
	infoText:SetWordWrap(true)

	for i = 1, #SLOTS do
		local slotName, label = SLOTS[i][1], SLOTS[i][2]
		local cell = CreateFrame("Button", nil, sheet.body)
		cell:SetSize(WM.Px(CELL), WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		-- Grid right of the identity band: 4 columns starting x=300, rows
		-- from y=0 (5 rows x 136 - 8 = 672 px — the CharacterPanel budget).
		cell:SetPoint("TOPLEFT", WM.Px(300 + col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))

		local slotID, emptyTexture = GetInventorySlotInfo(slotName)
		cell.slotID, cell.emptyTexture = slotID, emptyTexture

		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetSize(WM.Px(72), WM.Px(72))
		cell.icon:SetPoint("TOP", 0, -WM.Px(12))

		local name = WM.CreateText(cell, 20)
		name:SetPoint("BOTTOM", 0, WM.Px(10))
		name:SetText(label)
		name:SetTextColor(0.7, 0.7, 0.75)

		WM.AttachTooltip(cell, function(tt, self)
			local unit = inspectUnit
			if unit and GetInventoryItemLink(unit, self.slotID) then
				-- Server-backed inspect tooltip, the default frame's call.
				tt:SetInventoryItem(unit, self.slotID)
			else
				tt:SetText(label)
			end
		end)
		cells[i] = cell
	end

	-- Every inspect request funnels through NotifyInspect (C function, always
	-- present); track whom the client asked about so INSPECT_READY can match.
	hooksecurefunc("NotifyInspect", function(unit)
		pendingUnit = unit
		pendingGUID = UnitGUID(unit)
	end)
	-- USER-initiated requests come through InspectUnit (FrameXML UIParent.lua,
	-- present at login — it LoDs Blizzard_InspectUI): the unit menu's Inspect
	-- entry calls it, background scanners call raw NotifyInspect and never
	-- pass here. Only these requests may open the sheet.
	hooksecurefunc("InspectUnit", function(unit)
		userGUID = unit and UnitGUID(unit) or nil
	end)

	WM.On("INSPECT_READY", function(_, guid)
		if pendingGUID and guid == pendingGUID and guid == userGUID then
			-- The answer to the user's own request: adopt it and open.
			userGUID = nil
			inspectUnit, inspectGUID = pendingUnit, pendingGUID
			sheet.Open()
			Render()
		elseif sheet:IsShown() and guid == inspectGUID then
			Render() -- silent refresh of the already-shown unit
		end
		-- Any other READY (another addon's background scan) is ignored; note
		-- that such a scan still replaces the server-side inspect session, so
		-- tooltips on an already-open sheet can go stale until re-inspected.
	end)

	-- Data refreshes while the sheet is up (item cache fills, gear swaps).
	WM.On("UNIT_INVENTORY_CHANGED", function(_, unit)
		if sheet:IsShown() and unit == inspectUnit then Render() end
	end)
	WM.TryOn("GET_ITEM_INFO_RECEIVED", function()
		if sheet:IsShown() then Render() end
	end)

	-- Unit-token liveness, the default InspectFrame's own rules.
	WM.On("PLAYER_TARGET_CHANGED", function()
		if sheet:IsShown() and inspectUnit == "target" then Dismiss() end
	end)
	WM.On("GROUP_ROSTER_UPDATE", function()
		if sheet:IsShown() and inspectUnit and inspectUnit ~= "target"
				and UnitGUID(inspectUnit or "") ~= inspectGUID then
			Dismiss()
		end
	end)
end)
