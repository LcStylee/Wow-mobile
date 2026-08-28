--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Bags
-- Bag button row (backpack + bags 1-4 with free-slot counts) on the right end
-- of the deck's bottom row, and a deck-filling grid panel of every bag slot.
-- Tap a cell = UseContainerItem(bag, slot) — use/equip, or SELL while a
-- merchant window is open (the default 1.12 bags' semantics); tooltip via the
-- injected hover.
--------------------------------------------------------------------------------

local WM = WowMobile

local NUM_BAGS = 4 -- bags 1..4 plus the backpack (bag 0)
local COLS = 8
-- Cell size is budgeted against the SCROLLER viewport, not the full panel:
-- panel content is 1064 (1080 deck − 2*8 inset) and Deck.CreateScroller
-- reserves a 92 px button column + 6 px gap on the right, leaving 966 px.
-- 8 columns at 114+6 pitch span 8*120 − 6 = 954 <= 966 (12 px slack).
local CELL = 114
local GAP = 6

local panel, scroller
local bagButtons = {}
local cells = {}     -- "bag:slot" -> cell
local bagSizes = {}  -- last laid-out size per bag

-- 1.12 has no GetContainerNumFreeSlots; count empties directly.
local function FreeSlots(bag)
	local free = 0
	for slot = 1, GetContainerNumSlots(bag) do
		if not GetContainerItemInfo(bag, slot) then
			free = free + 1
		end
	end
	return free
end

--------------------------------------------------------------------------------
-- Grid panel
--------------------------------------------------------------------------------

local function CellKey(bag, slot)
	return bag .. ":" .. slot
end

local function CreateCell(bag, slot)
	local cell = CreateFrame("Button", "WowMobileBagCell" .. bag .. "_" .. slot,
		scroller.child)
	cell:SetWidth(WM.Px(CELL))
	cell:SetHeight(WM.Px(CELL))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(4), -WM.Px(4))
	cell.icon:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	cell.count = WM.CreateText(cell, 26, "OUTLINE")
	cell.count:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
	cell.bag, cell.slot = bag, slot
	-- Tap = use/equip/sell (the default 1.12 bag semantics); long-press (the
	-- client maps long-press to a right click) = MoveMode pickup, with the
	-- stack stepper for counts > 1; while a carry is active every tap is a
	-- drop on this cell (place / swap / merge).
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	cell:SetScript("OnClick", function()
		if WM.MoveMode.IsActive() then
			WM.MoveMode.DropOnBag(this.bag, this.slot)
		elseif arg1 == "RightButton" then
			WM.MoveMode.BeginFromBag(this.bag, this.slot)
		else
			UseContainerItem(this.bag, this.slot)
		end
	end)
	WM.MoveMode.MakeTarget(cell, "bag")
	WM.AttachTooltip(cell, function(tt, self)
		tt:SetBagItem(self.bag, self.slot)
	end)
	return cell
end

local function UpdateCell(cell)
	-- 1.12: texture, itemCount, locked, quality, readable.
	local icon, count, locked, quality = GetContainerItemInfo(cell.bag, cell.slot)
	if icon then
		cell.icon:SetTexture(icon)
		if locked then
			cell.icon:SetVertexColor(0.4, 0.4, 0.45)
		else
			cell.icon:SetVertexColor(1, 1, 1)
		end
		cell.count:SetText(count and count > 1 and count or "")
		local q = quality and quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		if q then
			cell.borderTex:SetTexture(q.r, q.g, q.b, 1)
		else
			WM.TintBorder(cell, WM.Colors.border)
		end
	else
		cell.icon:SetTexture(WM.TEX_WHITE)
		cell.icon:SetVertexColor(0.12, 0.12, 0.14)
		cell.count:SetText("")
		WM.TintBorder(cell, WM.Colors.border)
	end
end

local function RebuildGrid()
	if not panel:IsShown() then return end
	local shown = {}
	local index = 0
	for bag = 0, NUM_BAGS do
		local size = GetContainerNumSlots(bag)
		bagSizes[bag] = size
		for slot = 1, size do
			index = index + 1
			local key = CellKey(bag, slot)
			local cell = cells[key]
			if not cell then
				cell = CreateCell(bag, slot)
				cells[key] = cell
			end
			local col = math.mod(index - 1, COLS)
			local row = math.floor((index - 1) / COLS)
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				WM.Px(col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))
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

-- Cheap visual pass for one bag.
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
		local size = GetContainerNumSlots(bag)
		if bag == 0 then
			b.icon:SetTexture(BACKPACK_ICON)
		else
			local invID = ContainerIDToInventoryID(bag)
			local texture = invID and GetInventoryItemTexture("player", invID)
			b.icon:SetTexture(texture or WM.TEX_WHITE)
			if not texture then
				b.icon:SetVertexColor(0.15, 0.15, 0.18) -- empty bag slot
			else
				b.icon:SetVertexColor(1, 1, 1)
			end
		end
		b.free:SetText(size > 0 and FreeSlots(bag) or "")
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("bags", "Bags")
	scroller = WM.Deck.CreateScroller(panel.content)

	panel.OnOpen = RebuildGrid

	-- Bag buttons on the right end of the bottom row (menu buttons occupy the
	-- left; see Deck.lua).
	local row = WM.Layout.bottomRow
	local prev
	for bag = NUM_BAGS, 0, -1 do
		local b = CreateFrame("Button", "WowMobileBagButton" .. bag, row)
		b:SetWidth(WM.Px(86))
		b:SetHeight(WM.Px(WM.DeckMetrics.rowBottom))
		WM.SkinFrame(b, WM.Colors.button)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(b)
		hl:SetTexture(1, 1, 1, 0.10)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", WM.Px(6), -WM.Px(6))
		b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -WM.Px(6), WM.Px(6))
		b.free = WM.CreateText(b, 24, "OUTLINE")
		b.free:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -WM.Px(6), WM.Px(4))
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
			if GetContainerNumSlots(bag) ~= bagSizes[bag] then
				RebuildGrid() -- different bag equipped: rows shift
			else
				RefreshBagVisuals(bag)
			end
		end
	end)
	-- 1.12 ITEM_LOCK_CHANGED carries no usable bag argument; refresh every
	-- visible bag (cheap: visuals only).
	WM.On("ITEM_LOCK_CHANGED", function()
		if not panel:IsShown() then return end
		for bag = 0, NUM_BAGS do
			RefreshBagVisuals(bag)
		end
	end)

	-- Replace the default container-frame entry points. The real 1.12
	-- FrameXML call graph (ContainerFrame.lua):
	--   * the 'B' key binding calls ToggleBackpack(); the per-bag bindings
	--     call ToggleBag(1..4),
	--   * OpenBackpack() and OpenAllBags() are themselves IMPLEMENTED via
	--     ToggleBackpack()/ToggleBag() — they are not independent paths — and
	--     the bank auto-open runs through OpenAllBags when the bank window
	--     shows.
	-- So all four globals are replaced together, split by intent:
	--   * hardware toggles (ToggleBackpack/ToggleBag) -> Deck.Toggle, so the
	--     'B' key opens AND closes the deck bags panel,
	--   * programmatic opens (OpenBackpack/OpenAllBags) -> Deck.Open, which
	--     is IDEMPOTENT — a Blizzard flow that fires it repeatedly (the
	--     bank's auto-open, addons calling OpenAllBags) can only ever leave
	--     the panel open, never yank an already-open panel closed.
	-- Leaving the Open* pair untouched is NOT an option here: the originals
	-- would call straight back into the replaced toggles and turn every
	-- auto-open into a blind toggle. The default ContainerFrames themselves
	-- can no longer open (every entry point lands here), so no CloseAllBags
	-- unwinding is needed. No hooksecurefunc on 1.12 — plain global
	-- replacement of insecure functions.
	function ToggleBackpack()
		WM.Deck.Toggle("bags")
	end
	function ToggleBag(id)
		WM.Deck.Toggle("bags")
	end
	function OpenBackpack()
		WM.Deck.Open("bags")
	end
	function OpenAllBags(forceOpen)
		WM.Deck.Open("bags")
	end
end)
