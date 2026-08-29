--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · MoveMode
-- Touch-native version of WoW's cursor-carry model. Long-press (the phone
-- client maps long-press to a right click) on a bag item, an equipped item,
-- a spellbook entry or an action button lifts it onto the game cursor and
-- opens a "carry bar" pinned above the deck (carried icon + name + a big X);
-- valid drop targets highlight green, and a plain TAP on one places/swaps via
-- the right API for the pair. Tapping the X — or any registered surface that
-- can't take the payload — cancels cleanly.
--
-- 1.12 cursor facts this module is built around (all verified against the
-- vanilla FrameXML that drives the default drag-and-drop):
--   * PickupContainerItem / SplitContainerItem  (ContainerFrame.lua),
--     PickupInventoryItem (PaperDollFrame.lua), PickupAction + PlaceAction
--     (ActionButton.lua), PickupSpell(bookSlot, "spell") (SpellBookFrame.lua),
--     CursorHasItem(), ClearCursor() all exist and are callable any time —
--     no secure frames, no combat lockdown on this client.
--   * GetCursorInfo does NOT exist (it is a 2.0 addition). MoveMode therefore
--     tracks the carried payload itself and reconciles with the only cursor
--     query the client has, CursorHasItem() — which answers for ITEMS only:
--       - item payloads (bag/equipped): reconciled on CURSOR_UPDATE (present
--         in the vanilla event set, but registered via WM.TryOn and NOT
--         load-bearing — the same reconcile also runs on ITEM_LOCK_CHANGED,
--         BAG_UPDATE and a coarse 0.5 s tick), so an out-of-band placement
--         or clear folds the carry bar automatically. The reconcile also
--         runs in REVERSE: a cursor loaded outside a tracked carry (any
--         Blizzard-side pickup, or an economy sheet's Click* API lifting a
--         slot's occupant) is ADOPTED as a generic "Held item" carry.
--         Without adoption that would be an invisible carry with no Cancel,
--         and bag-cell taps would take the non-carry branch
--         (UseContainerItem = use/deposit) instead of placing the item;
--       - spell/action payloads: NO query exists. If Blizzard-side code
--         clears the cursor (e.g. the edge rail's Esc key) the carry bar can
--         linger; it resolves on Cancel, on a tap on a non-action surface,
--         or on an occupied-action-slot tap whose PlaceAction visibly
--         no-opped (icon-unchanged check in DropOnAction — a same-icon pair
--         stays ambiguous and is treated as a swap). Accepted 1.12
--         limitation.
--   * Swap semantics: dropping onto an occupied slot puts the displaced
--     item/action on the cursor. The displaced identity is captured from the
--     target slot BEFORE the drop (no cursor query afterwards) and the carry
--     simply continues with it.
--   * ClearCursor() on a carried item returns it to its source slot; on a
--     carried action it discards it from the cursor — identical to dragging
--     it off the bar in the default UI. Cancel therefore restores an action
--     payload to its (still empty) home slot via PlaceAction first.
--
-- Drop targets: bag cells (Bags.lua), bank/bank-bag/deposit cells (Bank.lua —
-- the 1.12 container API addresses the bank as bag -1 and bank bags 5..10, so
-- the same BeginFromBag/DropOnBag handlers serve both directions unchanged),
-- character slots (CharacterPanel.lua, equip-location filtered), action
-- buttons (ActionBars.lua / QuickBar.lua), and the economy sheets' special
-- "put an item here" slots (AuctionHouse sell slot, Mail attachment, Trade
-- offer slots). Those special slots place via their own Click* C-calls
-- (ClickAuctionSellItemButton / ClickSendMailItemButton / ClickTradeButton)
-- and then call Move.NoteSlotDrop(), which reconciles IMMEDIATELY:
--   * placement into an EMPTY slot: cursor empties, the carry bar folds;
--   * placement onto an OCCUPIED slot: the Click* call SWAPS — the carried
--     item lands in the slot and the displaced occupant rides the cursor, so
--     CursorHasItem() stays true and a fold would never fire. NoteSlotDrop
--     detects this (carry active + cursor still loaded) and DEGRADES the
--     payload to a generic no-origin "Held item", because the old icon/name/
--     invType now describe the placed item, not what the cursor holds;
--   * a Click* pickup with no carry active is adopted on the spot (no event
--     latency).
--
-- Stack split: long-pressing a stack (count > 1) opens a quantity stepper
-- sheet FIRST ("Take how many?"); confirming runs SplitContainerItem for
-- n < count and a plain PickupContainerItem for the whole stack.
--
-- Layout (design px): the carry bar spans the square's bottom edge, but only
-- its RIGHT end is interactive — the phone client's virtual joystick captures
-- every first touch at x <= 486, y >= 594 of the default square (client
-- input.js JOY_ZONE_FRAC; same budget tables as Pet.lua / QuickBar.lua), so a
-- Cancel button on the left half would be untappable. The split stepper sheet
-- sits above the bar, right-aligned at x >= 492 for the same reason — which
-- puts it (y 130..430) in the band RollFrames.lua's roll rows start in:
-- RollFrames normally stacks from bottom offset 140, and hops above the
-- stepper (offset 438) whenever it is open, via Move.SplitShown /
-- Move.onSplitToggle below — so roll buttons are never buried under it.
--------------------------------------------------------------------------------

local WM = WowMobile

local Move = {}
WM.MoveMode = Move

local BOOK = BOOKTYPE_SPELL or "spell"

local CARRY_H = 112 -- carry bar height; lane 8..120 above the square's bottom
local SPLIT_W = 580 -- split sheet width; left edge at 1080-8-580 = 492 > 486
local SPLIT_H = 300

local payload      -- { kind = "container"|"inventory"|"spell"|"action", icon,
                   --   name, count, quality, invType, bag, slot, invSlot,
                   --   bookSlot, actionSlot } — origin fields only when the
                   --   payload still has a home slot to return/merge into.
local splitPending -- { bag, slot, count, icon, name, quality, link, n }
local targets = {} -- registered drop-target frames
local bar, split   -- carry bar / split stepper (built in OnInit)

--------------------------------------------------------------------------------
-- Link helpers (Lua 5.0: string.find captures, no string.match)
--------------------------------------------------------------------------------

local function LinkName(link)
	if not link then return nil end
	local _, _, name = string.find(link, "%[(.-)%]")
	return name
end

-- Quality + equip location from a link via GetItemInfo (1.12 returns: name,
-- link, quality, level, type, subType, stackCount, invType, texture). Both
-- come back nil while the item record is uncached — the drop itself still
-- works, only the character-slot highlight degrades (see TargetValid).
local function LinkItemData(link)
	if not link then return nil, nil end
	local _, _, id = string.find(link, "item:(%d+)")
	if not id then return nil, nil end
	local _, _, quality, _, _, _, _, invType = GetItemInfo("item:" .. id)
	return quality, invType
end

--------------------------------------------------------------------------------
-- Drop-target registry + highlights
--------------------------------------------------------------------------------

local invTypeSlots = {} -- "INVTYPE_*" -> array of inventory slot ids (OnInit)

local function IsItemPayload()
	return payload ~= nil and
		(payload.kind == "container" or payload.kind == "inventory")
end

local function TargetValid(frame)
	if not payload then return false end
	local kind = frame.moveTargetKind
	if kind == "action" then
		-- Action slots take anything the cursor can carry (spells, items,
		-- displaced actions) — PlaceAction sorts the pair out.
		return true
	end
	if kind == "bag" then
		return IsItemPayload()
	end
	if kind == "inv" then
		if not IsItemPayload() then return false end
		local slots = payload.invType and invTypeSlots[payload.invType]
		if not slots then return false end -- uncached item: no highlight; drops still allowed
		for i = 1, table.getn(slots) do
			if slots[i] == frame.slotID then return true end
		end
	end
	return false
end

local function ApplyHighlights()
	for i = 1, table.getn(targets) do
		local f = targets[i]
		WM.SetShown(f.moveTargetHl, TargetValid(f))
	end
end

local function ClearHighlights()
	for i = 1, table.getn(targets) do
		targets[i].moveTargetHl:Hide()
	end
end

-- Register `frame` as a drop target of the given kind ("bag" | "inv" |
-- "action"; "inv" frames must carry a .slotID field). Adds the green
-- highlight overlay; callable at any time — cells created while a carry is
-- already active (a bag grid rebuild) pick up the current highlight state.
function Move.MakeTarget(frame, kind)
	local hl = frame:CreateTexture(nil, "OVERLAY")
	hl:SetAllPoints(frame)
	hl:SetTexture(0.30, 0.90, 0.40, 0.28)
	hl:Hide()
	frame.moveTargetKind = kind
	frame.moveTargetHl = hl
	table.insert(targets, frame)
	if payload then
		WM.SetShown(hl, TargetValid(frame))
	end
end

--------------------------------------------------------------------------------
-- Carry lifecycle
--------------------------------------------------------------------------------

-- RollFrames.lua sets Move.onSplitToggle and reads Move.SplitShown() to hop
-- its roll rows above the split stepper while it is open (layout note in the
-- header). 1.12 has no Frame:HookScript, hence the explicit callback.
function Move.SplitShown()
	return split ~= nil and split:IsShown() and true or false
end

local function NotifySplitToggle()
	if Move.onSplitToggle then Move.onSplitToggle() end
end

local function CloseSplit()
	splitPending = nil
	if split and split:IsShown() then
		split:Hide()
		NotifySplitToggle()
	end
end

local function EndCarry()
	payload = nil
	CloseSplit()
	if bar then bar:Hide() end
	ClearHighlights()
end

function Move.IsActive()
	return payload ~= nil
end

-- True when a tap should take the DROP path even though no payload is
-- tracked yet: something loaded the cursor outside a tracked carry (an
-- economy sheet's Click* pickup, any stray Blizzard path) and the adopting
-- reconcile hasn't run for it yet. Cell tap handlers use IsActive() OR
-- this, so a foreign cursor is never mistaken for "no carry" (which would
-- UseContainerItem = use/deposit, or UseAction, instead of placing).
function Move.CursorForeign()
	return payload == nil and CursorHasItem()
end

local function SetBarItem(icon, name, quality, countText)
	bar.icon:SetTexture(icon or WM.TEX_QUESTION)
	bar.name:SetText(name or "")
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		bar.name:SetTextColor(q.r, q.g, q.b)
	else
		bar.name:SetTextColor(0.92, 0.92, 0.92)
	end
	bar.count:SetText(countText or "")
end

-- Enter move mode with an already-lifted payload (the BeginFrom* helpers
-- below build the payload AND perform the pickup, then call this).
function Move.Begin(p)
	if not bar then return end
	payload = p
	CloseSplit()
	SetBarItem(p.icon, p.name, p.quality,
		p.count and p.count > 1 and ("x" .. p.count) or "")
	bar:Show()
	ApplyHighlights()
end

function Move.Cancel()
	if payload and payload.kind == "action" and payload.actionSlot
			and not HasAction(payload.actionSlot) then
		-- Put the carried action back on its (still empty) home slot;
		-- without this, ClearCursor would strip it off the bar entirely.
		PlaceAction(payload.actionSlot)
	end
	-- Items return to their source slot on ClearCursor (1.12 cursor
	-- semantics); spells simply drop back to the book; a carried action
	-- whose home slot got re-occupied is discarded — identical to the
	-- default UI's drag-off-the-bar removal.
	ClearCursor()
	EndCarry()
end

-- Reverse reconciliation (see header): a cursor loaded by Blizzard-side code
-- while NO carry is active is adopted as a generic no-origin "Held item"
-- carry — the carry bar, highlights, drop handlers and Cancel all engage.
-- 1.12 has no GetCursorInfo, so the identity is honestly unknown (question-
-- mark icon, generic name); the item itself still places/swaps correctly
-- because every drop goes through the real Pickup* APIs. Returns true when a
-- payload is active afterwards (false only pre-init, when the bar doesn't
-- exist yet and Move.Begin no-ops).
local function AdoptForeignCursor()
	if payload then return true end
	if not CursorHasItem() then return false end
	Move.Begin({ kind = "container", icon = WM.TEX_QUESTION,
		name = "Held item" })
	return payload ~= nil
end

--------------------------------------------------------------------------------
-- Pickup entry points (long-press handlers in the integrated modules)
--------------------------------------------------------------------------------

local OpenSplit -- forward: defined with the stepper UI below

function Move.BeginFromBag(bag, slot)
	if payload then return end
	local icon, count, locked, quality = GetContainerItemInfo(bag, slot)
	if not icon or locked then return end
	local link = GetContainerItemLink(bag, slot)
	local name = LinkName(link)
	if count and count > 1 then
		OpenSplit(bag, slot, count, icon, name, quality, link)
		return
	end
	PickupContainerItem(bag, slot)
	if CursorHasItem() then
		local q, invType = LinkItemData(link)
		Move.Begin({ kind = "container", bag = bag, slot = slot,
			icon = icon, name = name or "Item", count = 1,
			quality = quality or q, invType = invType })
	end
end

function Move.BeginFromInventory(invSlot)
	if payload then return end
	local icon = GetInventoryItemTexture("player", invSlot)
	if not icon then return end
	local link = GetInventoryItemLink("player", invSlot)
	PickupInventoryItem(invSlot)
	if CursorHasItem() then
		local quality, invType = LinkItemData(link)
		Move.Begin({ kind = "inventory", invSlot = invSlot, icon = icon,
			name = LinkName(link) or "Item", count = 1,
			quality = quality, invType = invType })
	end
end

function Move.BeginFromSpell(bookSlot)
	if payload then return end
	local name, rank = GetSpellName(bookSlot, BOOK)
	if not name then return end
	local icon = GetSpellTexture(bookSlot, BOOK)
	PickupSpell(bookSlot, BOOK)
	-- No cursor query exists for spells (CursorHasItem is item-only, no
	-- GetCursorInfo on 1.12); PickupSpell on a valid book slot always loads
	-- the cursor, so the carry starts on trust.
	Move.Begin({ kind = "spell", bookSlot = bookSlot, icon = icon,
		name = name .. (rank and rank ~= "" and (" (" .. rank .. ")") or "") })
end

function Move.BeginFromAction(slot)
	if payload then return end
	if not HasAction(slot) then return end
	local icon = GetActionTexture(slot)
	-- GetActionText names macros only; 1.12 has no per-slot spell-name API,
	-- so plain spell actions carry a generic label.
	local text = GetActionText(slot)
	PickupAction(slot)
	Move.Begin({ kind = "action", actionSlot = slot, icon = icon,
		name = text or ("Bar slot " .. slot) })
end

--------------------------------------------------------------------------------
-- Drop handlers (tap handlers in the integrated modules while active)
--------------------------------------------------------------------------------

function Move.DropOnBag(bag, slot)
	-- Adopt a Blizzard-loaded cursor first (belt-and-braces: the cell tap
	-- handlers route here on Move.CursorForeign() before any reconcile ran).
	if not AdoptForeignCursor() then return end
	if not IsItemPayload() then
		Move.Cancel() -- spells/actions can't enter bags: invalid tap cancels
		return
	end
	if not CursorHasItem() then
		EndCarry() -- cursor emptied elsewhere; fold the stale carry bar
		return
	end
	if payload.kind == "container" and payload.bag == bag and payload.slot == slot then
		-- Tap back on the origin slot: return / merge the (split) stack.
		PickupContainerItem(bag, slot)
		EndCarry()
		return
	end
	local dIcon, dCount, dLocked, dQuality = GetContainerItemInfo(bag, slot)
	if dLocked then return end -- target mid-transaction; ignore the tap
	local dLink = GetContainerItemLink(bag, slot)
	PickupContainerItem(bag, slot)
	if not CursorHasItem() then
		EndCarry() -- placed (or merged) clean
	elseif dIcon then
		local dName = LinkName(dLink)
		if dName and dName == payload.name then
			-- Merge overflow onto a same-item stack: what rides the cursor is
			-- the REMAINDER of the carried stack, not the target's contents,
			-- and 1.12 has no query for how much — keep the carried identity
			-- with an unknown count (no count text). No origin fields: the
			-- source slot's contents changed under the merge.
			Move.Begin({ kind = "container", icon = payload.icon,
				name = payload.name, quality = payload.quality,
				invType = payload.invType })
		else
			-- Swap: whatever the slot held rides the cursor now — keep
			-- carrying it. No origin fields: its home slot holds our item.
			local q, invType = LinkItemData(dLink)
			Move.Begin({ kind = "container", icon = dIcon,
				name = dName or "Item", count = dCount,
				quality = dQuality or q, invType = invType })
		end
	else
		Move.Cancel() -- placement refused into an empty slot: bail out clean
	end
end

function Move.DropOnInventory(invSlot)
	if not AdoptForeignCursor() then return end
	if not IsItemPayload() then
		Move.Cancel()
		return
	end
	if not CursorHasItem() then
		EndCarry()
		return
	end
	local dTexture = GetInventoryItemTexture("player", invSlot)
	local dLink = GetInventoryItemLink("player", invSlot)
	PickupInventoryItem(invSlot)
	if not CursorHasItem() then
		EndCarry() -- equipped clean
	elseif GetInventoryItemLink("player", invSlot) ~= dLink then
		-- Swap: the displaced equipped item rides the cursor now. Compared by
		-- LINK, not texture — two different items sharing one icon (same-model
		-- weapons/rings) are still distinguished. Only a swap of two items
		-- with the IDENTICAL link is misread as a refusal below; the end
		-- state is the same item in the slot either way, so the misread is
		-- harmless.
		local quality, invType = LinkItemData(dLink)
		Move.Begin({ kind = "inventory", icon = dTexture,
			name = LinkName(dLink) or "Item", count = 1,
			quality = quality, invType = invType })
	else
		-- Slot unchanged: the client refused the equip (wrong slot type
		-- etc. — the UI error fired) or the identical-link swap above.
		-- Treat as an invalid drop; ClearCursor sends the item back home.
		Move.Cancel()
	end
end

function Move.DropOnAction(slot)
	-- Foreign item cursors adopt too: PlaceAction happily takes an item.
	if not AdoptForeignCursor() then return end
	if IsItemPayload() and not CursorHasItem() then
		EndCarry()
		return
	end
	local hadAction = HasAction(slot)
	local dIcon = hadAction and GetActionTexture(slot)
	local dText = hadAction and GetActionText(slot)
	PlaceAction(slot)
	if hadAction then
		if payload.icon and payload.icon ~= WM.TEX_QUESTION
				and payload.icon ~= dIcon
				and GetActionTexture(slot) == dIcon then
			-- The slot's icon did not change even though our payload's icon
			-- differs: PlaceAction no-opped, i.e. the cursor was actually
			-- empty (a spell/action carry cleared Blizzard-side — 1.12 gives
			-- no cursor query for those, see header). Fold the stale carry
			-- instead of inventing a phantom "displaced action" payload.
			-- A same-icon pair is indistinguishable and treated as a swap.
			-- Adopted/degraded payloads (icon == TEX_QUESTION placeholder,
			-- never the item's real icon) BYPASS this heuristic entirely:
			-- comparing the placeholder against dIcon says nothing, and the
			-- adoption path already verified CursorHasItem() (and the
			-- empty-cursor early-out above folded any cleared carry), so
			-- PlaceAction genuinely swapped — err toward the visible,
			-- cancelable "Previous action" carry below rather than silently
			-- discarding the displaced action on an invisible cursor.
			EndCarry()
			return
		end
		-- 1.12 swap semantics: the displaced action rides the cursor now.
		-- There is no cursor query for actions, so this is tracked on trust;
		-- its home slot is occupied by our payload, so actionSlot stays nil
		-- (Cancel then discards it, like dragging it off the bar).
		Move.Begin({ kind = "action", icon = dIcon or WM.TEX_QUESTION,
			name = dText or "Previous action" })
	else
		EndCarry()
	end
end

--------------------------------------------------------------------------------
-- Reconciliation with the real cursor (item payloads only — see header)
--------------------------------------------------------------------------------

local function Reconcile()
	if not payload then
		-- REVERSE direction (see header): no carry active but the cursor is
		-- loaded — something outside a tracked carry picked an item up (a
		-- stray Blizzard pickup path, or an economy sheet's Click* call
		-- lifting a slot's occupant). Adopt it as a generic Held-item carry
		-- so the bar, highlights and Cancel all engage.
		AdoptForeignCursor()
		return
	end
	if IsItemPayload() and not CursorHasItem() then
		-- Placed or cleared out-of-band (a Click* placement, Esc): fold the
		-- carry UI without touching the cursor.
		EndCarry()
	end
end

-- Public hook for the economy sheets (see the drop-target note in the
-- header). NoteSlotDrop runs right after a sheet's Click* placement API:
-- fold when the cursor emptied (placed clean), DEGRADE to a generic
-- "Held item" carry when a swap left the slot's previous occupant riding
-- the cursor (the tracked identity would be stale), and with no carry at
-- all fall through to Reconcile — fold, or ADOPT a fresh Click* pickup.
function Move.NoteSlotDrop()
	if payload and CursorHasItem() then
		Move.Begin({ kind = "container", icon = WM.TEX_QUESTION,
			name = "Held item" })
	else
		Reconcile()
	end
end

--------------------------------------------------------------------------------
-- Stack-split stepper (shares the carry bar as its header)
--------------------------------------------------------------------------------

local function SyncSplitUI()
	local p = splitPending
	if not p then return end
	split.value:SetText(p.n)
	split.take.label:SetText("Take " .. p.n)
end

OpenSplit = function(bag, slot, count, icon, name, quality, link)
	if not split then return end
	splitPending = { bag = bag, slot = slot, count = count, icon = icon,
		name = name, quality = quality, link = link, n = 1 }
	SetBarItem(icon, name or "Item", quality, "x" .. count)
	bar:Show()
	split:Show()
	NotifySplitToggle()
	SyncSplitUI()
end

local function BumpSplit(delta)
	local p = splitPending
	if not p then return end
	local n = p.n + delta
	if n < 1 then n = 1 end
	if n > p.count then n = p.count end
	p.n = n
	SyncSplitUI()
end

local function ConfirmSplit(n)
	local p = splitPending
	if not p then return end
	CloseSplit()
	-- Revalidate against the live bag: the stepper holds no lock, so between
	-- opening it and pressing Take the slot's contents can change (stack
	-- consumed by a macro, bag reshuffle on BAG_UPDATE, item sold or locked by
	-- a transaction). Picking up blind would lift whatever occupies the slot
	-- NOW while the carry bar still shows the stepper's stale icon/name. Bail
	-- when the slot no longer holds the same unlocked item (link-compared —
	-- GetContainerItemLink exists on 1.12); clamp n to the live count.
	local _, count, locked = GetContainerItemInfo(p.bag, p.slot)
	if not count or count < 1 or locked
			or GetContainerItemLink(p.bag, p.slot) ~= p.link then
		return
	end
	if n > count then n = count end
	if n >= count then
		PickupContainerItem(p.bag, p.slot) -- whole stack: plain pickup
	else
		SplitContainerItem(p.bag, p.slot, n)
	end
	if CursorHasItem() then
		local quality, invType = LinkItemData(p.link)
		Move.Begin({ kind = "container", bag = p.bag, slot = p.slot,
			icon = p.icon, name = p.name or "Item", count = n,
			quality = p.quality or quality, invType = invType })
	else
		EndCarry()
	end
end

--------------------------------------------------------------------------------
-- Init: carry bar, split sheet, equip-location map, events
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Equip-location -> inventory-slot-id map for the character-slot
	-- highlight (ids resolved once via GetInventorySlotInfo).
	local function AddInvType(invType, slotName)
		local id = GetInventorySlotInfo(slotName)
		if not id then return end
		if not invTypeSlots[invType] then invTypeSlots[invType] = {} end
		table.insert(invTypeSlots[invType], id)
	end
	AddInvType("INVTYPE_HEAD", "HeadSlot")
	AddInvType("INVTYPE_NECK", "NeckSlot")
	AddInvType("INVTYPE_SHOULDER", "ShoulderSlot")
	AddInvType("INVTYPE_BODY", "ShirtSlot")
	AddInvType("INVTYPE_CHEST", "ChestSlot")
	AddInvType("INVTYPE_ROBE", "ChestSlot")
	AddInvType("INVTYPE_TABARD", "TabardSlot")
	AddInvType("INVTYPE_WRIST", "WristSlot")
	AddInvType("INVTYPE_HAND", "HandsSlot")
	AddInvType("INVTYPE_WAIST", "WaistSlot")
	AddInvType("INVTYPE_LEGS", "LegsSlot")
	AddInvType("INVTYPE_FEET", "FeetSlot")
	AddInvType("INVTYPE_CLOAK", "BackSlot")
	AddInvType("INVTYPE_FINGER", "Finger0Slot")
	AddInvType("INVTYPE_FINGER", "Finger1Slot")
	AddInvType("INVTYPE_TRINKET", "Trinket0Slot")
	AddInvType("INVTYPE_TRINKET", "Trinket1Slot")
	AddInvType("INVTYPE_WEAPON", "MainHandSlot")
	AddInvType("INVTYPE_WEAPON", "SecondaryHandSlot")
	AddInvType("INVTYPE_2HWEAPON", "MainHandSlot")
	AddInvType("INVTYPE_WEAPONMAINHAND", "MainHandSlot")
	AddInvType("INVTYPE_WEAPONOFFHAND", "SecondaryHandSlot")
	AddInvType("INVTYPE_SHIELD", "SecondaryHandSlot")
	AddInvType("INVTYPE_HOLDABLE", "SecondaryHandSlot")
	AddInvType("INVTYPE_RANGED", "RangedSlot")
	AddInvType("INVTYPE_RANGEDRIGHT", "RangedSlot")
	AddInvType("INVTYPE_THROWN", "RangedSlot")
	AddInvType("INVTYPE_RELIC", "RangedSlot")

	-- Carry bar, pinned above the deck (the square's bottom band). Only the
	-- Cancel button is interactive, on the right end — clear of the joystick
	-- capture zone (see the layout note in the header).
	bar = CreateFrame("Frame", "WowMobileCarryBar", UIParent)
	bar:SetPoint("BOTTOMLEFT", WM.WorldSquare, "BOTTOMLEFT", WM.Px(8), WM.Px(8))
	bar:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	bar:SetHeight(WM.Px(CARRY_H))
	bar:SetFrameStrata("DIALOG")
	-- Swallow taps across the WHOLE bar, not just the Cancel button: without
	-- this, a tap on the visible middle band (the carried icon/name — the
	-- natural "tap the thing I'm carrying" gesture) would fall through to
	-- WorldFrame, and on 1.12 a world click with an item on the cursor raises
	-- the drop-to-destroy DELETE_ITEM confirm (touch-boosted in Blizzard.lua)
	-- — one boosted tap from destroying the carried item. The client
	-- joystick's first-touch capture zone already owns the left band
	-- (x <= 486) client-side, so this costs nothing there.
	bar:EnableMouse(true)
	WM.SkinFrame(bar, WM.Colors.panel, WM.Colors.accent)
	bar:Hide()

	bar.icon = bar:CreateTexture(nil, "ARTWORK")
	bar.icon:SetWidth(WM.Px(88))
	bar.icon:SetHeight(WM.Px(88))
	bar.icon:SetPoint("LEFT", bar, "LEFT", WM.Px(12), 0)

	bar.name = WM.CreateText(bar, 30)
	bar.name:SetPoint("TOPLEFT", bar, "TOPLEFT", WM.Px(116), -WM.Px(22))
	bar.name:SetJustifyH("LEFT")
	bar.name:SetWidth(WM.Px(640))
	WM.SingleLine(bar.name, 30)

	bar.count = WM.CreateText(bar, 24, "OUTLINE")
	bar.count:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", WM.Px(116), WM.Px(14))
	bar.count:SetTextColor(0.75, 0.75, 0.8)

	local cancel = WM.CreateTouchButton(bar, 150, CARRY_H - 16, "X", 44)
	cancel:SetPoint("RIGHT", bar, "RIGHT", -WM.Px(8), 0)
	cancel:SetScript("OnClick", function() Move.Cancel() end)

	-- Split stepper sheet: right-aligned above the carry bar (x 492..1072).
	split = CreateFrame("Frame", "WowMobileSplitSheet", UIParent)
	split:SetWidth(WM.Px(SPLIT_W))
	split:SetHeight(WM.Px(SPLIT_H))
	split:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT",
		-WM.Px(8), WM.Px(CARRY_H + 18))
	split:SetFrameStrata("DIALOG")
	split:EnableMouse(true)
	WM.SkinFrame(split, WM.Colors.panel, WM.Colors.accent)
	split:Hide()

	local title = WM.CreateText(split, 32)
	title:SetPoint("TOPLEFT", split, "TOPLEFT", WM.Px(20), -WM.Px(18))
	title:SetText("Take how many?")

	local minus = WM.CreateTouchButton(split, 110, 96, "-", 48)
	minus:SetPoint("TOPLEFT", split, "TOPLEFT", WM.Px(16), -WM.Px(70))
	minus:SetScript("OnClick", function() BumpSplit(-1) end)

	split.value = WM.CreateText(split, 44)
	split.value:SetPoint("LEFT", minus, "RIGHT", 0, 0)
	split.value:SetWidth(WM.Px(140))
	split.value:SetJustifyH("CENTER")

	local plus = WM.CreateTouchButton(split, 110, 96, "+", 48)
	plus:SetPoint("LEFT", minus, "RIGHT", WM.Px(148), 0)
	plus:SetScript("OnClick", function() BumpSplit(1) end)

	local maxBtn = WM.CreateTouchButton(split, 130, 96, "Max", 32)
	maxBtn:SetPoint("LEFT", plus, "RIGHT", WM.Px(8), 0)
	maxBtn:SetScript("OnClick", function()
		if splitPending then BumpSplit(splitPending.count) end
	end)

	split.take = WM.CreateTouchButton(split, 250, 96, "Take 1", 32)
	split.take:SetPoint("BOTTOMLEFT", split, "BOTTOMLEFT", WM.Px(16), WM.Px(16))
	split.take:SetScript("OnClick", function()
		if splitPending then ConfirmSplit(splitPending.n) end
	end)

	local allBtn = WM.CreateTouchButton(split, 140, 96, "All", 32)
	allBtn:SetPoint("LEFT", split.take, "RIGHT", WM.Px(8), 0)
	allBtn:SetScript("OnClick", function()
		if splitPending then ConfirmSplit(splitPending.count) end
	end)

	local splitCancel = WM.CreateTouchButton(split, 140, 96, "Cancel", 28)
	splitCancel:SetPoint("LEFT", allBtn, "RIGHT", WM.Px(8), 0)
	splitCancel:SetScript("OnClick", function() EndCarry() end)

	-- (Round 1's boosted-BankFrame OnClick wrap lived here; the bank is now a
	-- full deck rebuild — Bank.lua — whose cells go through BeginFromBag/
	-- DropOnBag directly, and the swap/adopt reconcile it performed survives
	-- as the public Move.NoteSlotDrop above.)

	-- Item-payload reconciliation, BOTH directions (see header): fold a stale
	-- carry when the cursor emptied Blizzard-side, ADOPT a foreign cursor
	-- when Blizzard-side code loaded it with no carry active. CURSOR_UPDATE
	-- is TryOn'd — it exists on 1.12 but nothing depends on it; the same
	-- reconcile also rides ITEM_LOCK_CHANGED / BAG_UPDATE and a coarse tick
	-- (UNgated, so adoption runs even with no payload; one CursorHasItem()
	-- C-call per 0.5 s, no allocations).
	WM.TryOn("CURSOR_UPDATE", Reconcile)
	WM.On("ITEM_LOCK_CHANGED", Reconcile)
	WM.On("BAG_UPDATE", Reconcile)
	WM.Ticker(0.5, Reconcile)
	-- Zoning clears the cursor wholesale; drop any carry/split state with it.
	WM.On("PLAYER_ENTERING_WORLD", function()
		if payload or splitPending then EndCarry() end
	end)
end)
