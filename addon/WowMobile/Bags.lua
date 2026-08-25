--------------------------------------------------------------------------------
-- WowMobile · Bags
-- Bag button row (backpack + bags 1-4 with free-slot counts) on the right end
-- of the deck's bottom row, and a deck-filling grid panel of every bag slot.
-- Grid cells are secure type="item" buttons whose "item" attribute is the
-- positional "bag slot" string — set once per cell, so contents changing in
-- combat never needs an attribute write; tap = use/equip (the same semantics
-- as /use bag slot), tooltip via the injected hover. Structural changes (a
-- bag swapped for a different size) rebuild through the combat queue because
-- new cells mean new secure frames.
--------------------------------------------------------------------------------

local _, WM = ...

local NUM_BAGS = 4 -- bags 1..4 plus the backpack (bag 0)
local COLS = 8
local CELL = 118
local GAP = 6

local panel, scroller
local combatNotice      -- "available after combat" text for a first open in lockdown
local bagButtons = {}
local cells = {}     -- "bag:slot" -> secure cell
local bagSizes = {}  -- last laid-out size per bag

--------------------------------------------------------------------------------
-- Grid panel
--------------------------------------------------------------------------------

local function CellKey(bag, slot)
	return bag .. ":" .. slot
end

local function CreateCell(bag, slot)
	local cell = CreateFrame("Button", "WowMobileBagCell" .. bag .. "_" .. slot,
		scroller.child, "SecureActionButtonTemplate")
	cell:SetSize(WM.Px(CELL), WM.Px(CELL))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(4))
	cell.icon:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	cell.count = WM.CreateText(cell, 26, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
	WM.RegisterSecureClicks(cell) -- CVar-selected click edge, see Core.lua
	cell:SetAttribute("type", "item")
	cell:SetAttribute("item", bag .. " " .. slot) -- positional; never rewritten
	WM.AttachTooltip(cell, function(tt)
		tt:SetBagItem(bag, slot)
	end)
	cell.bag, cell.slot = bag, slot
	return cell
end

local function UpdateCell(cell)
	local icon, count, locked, quality = WM.Container.GetItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		cell.icon:SetDesaturated(locked and true or false)
		cell.icon:SetVertexColor(1, 1, 1)
		cell.count:SetText(count and count > 1 and count or "")
		local q = quality and quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		if q then
			cell.borderTex:SetColorTexture(q.r, q.g, q.b, 1)
		else
			local bd = WM.Colors.border
			cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
		end
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
		local bd = WM.Colors.border
		cell.borderTex:SetColorTexture(bd[1], bd[2], bd[3], 1)
	end
end

-- Full relayout: creates missing secure cells, so it must run out of combat
-- (queued by callers).
local function RebuildGrid()
	if not panel:IsShown() then return end
	combatNotice:Hide()
	local shown = {}
	local index = 0
	for bag = 0, NUM_BAGS do
		local size = WM.Container.GetNumSlots(bag)
		bagSizes[bag] = size
		for slot = 1, size do
			index = index + 1
			local key = CellKey(bag, slot)
			local cell = cells[key]
			if not cell then
				cell = CreateCell(bag, slot)
				cells[key] = cell
			end
			local col = (index - 1) % COLS
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", WM.Px(col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))
			UpdateCell(cell)
			cell:Show()
			shown[key] = true
		end
	end
	for key, cell in pairs(cells) do
		if not shown[key] then cell:Hide() end
	end
	scroller.SetContentHeight(WM.Px(math.ceil(index / COLS) * (CELL + GAP)))
end

-- Cheap visual pass for one bag (combat-safe: no secure attribute writes).
local function RefreshBagVisuals(bag)
	for slot = 1, bagSizes[bag] or 0 do
		local cell = cells[CellKey(bag, slot)]
		if cell and cell:IsShown() then UpdateCell(cell) end
	end
end

--------------------------------------------------------------------------------
-- Bag button row
--------------------------------------------------------------------------------

local BACKPACK_ICON = "Interface\\Buttons\\Button-Backpack-Up"

local function UpdateBagButtons()
	for bag = 0, NUM_BAGS do
		local b = bagButtons[bag]
		local size = WM.Container.GetNumSlots(bag)
		if bag == 0 then
			b.icon:SetTexture(BACKPACK_ICON)
		else
			local invID = WM.Container.BagInventoryID(bag)
			local texture = invID and GetInventoryItemTexture("player", invID)
			b.icon:SetTexture(texture or WM.TEX_WHITE)
			if not texture then
				b.icon:SetVertexColor(0.15, 0.15, 0.18) -- empty bag slot
			else
				b.icon:SetVertexColor(1, 1, 1)
			end
		end
		b.free:SetText(size > 0 and WM.Container.GetFreeSlots(bag) or "")
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("bags", "Bags")
	scroller = WM.Deck.CreateScroller(panel.content)

	-- Shown only for a first-ever open during combat: no secure cell can be
	-- created yet, so the grid would otherwise be silently blank.
	combatNotice = WM.CreateText(panel.content, 30)
	combatNotice:SetPoint("TOP", 0, -WM.Px(40))
	combatNotice:SetText("Bags will appear when combat ends.")
	combatNotice:SetTextColor(0.7, 0.7, 0.75)
	combatNotice:Hide()

	panel.OnOpen = function()
		if next(cells) then
			-- Immediate combat-safe visual pass: cell visuals (UpdateCell) are
			-- insecure, so items looted mid-fight show their current icons
			-- right away even while the structural rebuild below has to wait
			-- out combat (BAG_UPDATE skips hidden-panel refreshes, so contents
			-- may have changed since the last time the panel was open).
			for bag = 0, NUM_BAGS do
				RefreshBagVisuals(bag)
			end
		else
			combatNotice:SetShown(InCombatLockdown())
		end
		WM.OutOfCombat("bags-grid", RebuildGrid)
	end

	-- Bag buttons on the right end of the bottom row (menu buttons occupy the
	-- left; see Deck.lua).
	local row = WM.Layout.bottomRow
	local prev
	for bag = NUM_BAGS, 0, -1 do
		local b = CreateFrame("Button", "WowMobileBagButton" .. bag, row)
		b:SetSize(WM.Px(86), WM.Px(WM.DeckMetrics.rowBottom))
		WM.SkinFrame(b, WM.Colors.button)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.10)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", WM.Px(6), -WM.Px(6))
		b.icon:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
		b.free = WM.CreateText(b, 24, "OUTLINE")
		b.free:SetPoint("BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
		b.free:SetTextColor(0.4, 0.9, 0.4)
		if prev then
			b:SetPoint("RIGHT", prev, "LEFT", -WM.Px(4), 0)
		else
			b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		end
		b:SetScript("OnClick", function() WM.Deck.Toggle("bags") end)
		prev = b
		bagButtons[bag] = b
	end
	UpdateBagButtons()

	WM.On("BAG_UPDATE", function(_, bag)
		UpdateBagButtons()
		if not panel:IsShown() then return end
		if bag and bag >= 0 and bag <= NUM_BAGS then
			if WM.Container.GetNumSlots(bag) ~= bagSizes[bag] then
				-- Different bag equipped: needs new/removed secure cells. The
				-- visual pass still runs now so existing cells aren't stale
				-- while the structural rebuild waits out combat.
				RefreshBagVisuals(bag)
				WM.OutOfCombat("bags-grid", RebuildGrid)
			else
				RefreshBagVisuals(bag)
			end
		end
	end)
	WM.On("ITEM_LOCK_CHANGED", function(_, bag)
		if panel:IsShown() and bag and bag >= 0 and bag <= NUM_BAGS then
			RefreshBagVisuals(bag)
		end
	end)

	-- The client edge rail sends a real 'B' key (ARCHITECTURE §5), which hits
	-- Blizzard's toggle-backpack binding and would pop the mouse-sized default
	-- ContainerFrames over the deck. hooksecurefunc keeps the (insecure)
	-- originals intact; the hook immediately unwinds whatever default frames
	-- the call just opened and routes into the touch bags panel instead.
	-- OpenBackpack/OpenAllBags (programmatic auto-opens) are deliberately not
	-- hooked so no Blizzard flow can yank the deck panel open unasked.
	--
	-- Both toggles are hooked because which one the 'B' binding hits differs
	-- across builds — but on Classic-lineage ContainerFrame.lua ToggleAllBags
	-- itself calls ToggleBackpack (and ToggleBag), so one hardware press can
	-- fire this hook several times. `routed` collapses every firing within
	-- the same frame into a single route (cleared next frame via
	-- C_Timer.After(0)); without it the second firing's Deck.Toggle would
	-- immediately close the panel the first one just opened. The flag also
	-- guards reentrancy from CloseAllBags below.
	local routed = false
	local function RouteToDeckBags()
		if routed then return end
		routed = true
		C_Timer.After(0, function() routed = false end)
		CloseAllBags()
		WM.Deck.Toggle("bags")
	end
	hooksecurefunc("ToggleBackpack", RouteToDeckBags)
	if ToggleAllBags then
		hooksecurefunc("ToggleAllBags", RouteToDeckBags)
	end
end)
