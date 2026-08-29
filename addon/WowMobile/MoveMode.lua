--------------------------------------------------------------------------------
-- WowMobile · MoveMode
-- Touch-native version of WoW's cursor-carry model. Long-press (the client
-- maps deck long-press to a right click, ARCHITECTURE §5) on a pickup-capable
-- surface — bag cell, equipped slot, spellbook entry, action button — enters
-- "move mode": the payload rides the REAL Blizzard cursor, a carry bar above
-- the deck shows what is held with a big Cancel, valid drop targets highlight
-- green, and a TAP places/swaps via the right API for the pair. A stack
-- (count > 1) first asks for a quantity via a stepper sheet
-- (SplitContainerItem for n < count, plain pickup for the whole stack).
--
-- The Blizzard cursor stays the single source of truth: every state change
-- reconciles against GetCursorInfo() (CURSOR_CHANGED / CURSOR_UPDATE plus a
-- slow ticker that only runs while carrying), so Blizzard-cursor-side
-- placements — the economy sheets (SheetKit bag list, the AH sell slot, the
-- trade/mail attachment slots) place a carried item through insecure
-- ClickTradeButton / ClickSendMailItemButton / ClickAuctionSellItemButton
-- calls — can never desync this UI, and a cursor filled by
-- Blizzard code is adopted into the same carry bar so it always has a visible
-- Cancel. ALL move mutations are out-of-combat: Begin() in combat shows a
-- notice and does nothing, and entering combat cancels the carry outright —
-- no silent queueing of item moves, by design. (The one queued mutation is
-- the PlaceAction that RESTORES an action-origin carry to its home slot once
-- combat ends — a rollback of the pickup, never a new placement.)
--
-- Integration contract (Bags / Spellbook / ActionBars / CharacterPanel):
--   AttachSecureSource(btn, getPayload) — right-click enters move mode; the
--       button's "type2" becomes a secure no-op so the right-click never also
--       fires the secure action (surfaces whose right-click already meant
--       something, e.g. the pet strip's togglemenu, simply don't attach).
--   SecureDrop(btn, accepts, place, isActionTarget) — tap while carrying
--       places (or cancels, when the payload doesn't fit), swallowing the
--       button's secure action for exactly that click: PreClick nils "type",
--       PostClick restores it. PlaceAction targets (the action bars) pass
--       isActionTarget = true so a payload their placement displaces gets
--       action-origin cancel handling (carryIsAction / PlaceAction restore).
--       Legal and taint-free — attribute writes from addon code are how every
--       secure button here is configured — because move mode guarantees the
--       write happens out of combat.
--   RegisterTarget(frame, accepts) — green overlay while a payload the frame
--       accepts is being carried.
--------------------------------------------------------------------------------

local _, WM = ...

local MoveMode = {}
WM.MoveMode = MoveMode

--------------------------------------------------------------------------------
-- Layout budget (design px, world-square coordinates)
-- The carry bar and the split stepper live in the square's bottom band, just
-- above the deck, starting at x=500: the client joystick owns first touches
-- in the square's bottom-left (x <= 486, y >= 594 — budget tables in Pet.lua
-- / ActionBars.lua), so anything tappable left of that line would be eaten by
-- it. Accepted transient overlaps while move mode is active:
--   * on reduced viewport heights the lowest quick-bar slot can sit under the
--     bar (QuickBar keeps slot bottoms inside the square, down to its edge),
--   * with a full party, the re-homed PartyFrame stack's bottom (x ~672..960
--     — 128-UI-unit-wide pooled member frames at the 0.9 cap, arithmetic in
--     RollFrames.lua — stack ends ~1050 at default height, Blizzard.lua) is
--     briefly covered.
-- Both draw below this bar's DIALOG strata and move mode is a deliberate,
-- short-lived state, so no permanent budget is claimed.
--------------------------------------------------------------------------------

local BAR_W, BAR_H = 572, 120 -- x 500..1072 of the square, bottom 8..128
local SPLIT_H = 300 -- title+name (top ~80), stepper row, Max/All/Take row
-- The split stepper occupies x 500..1072, y 8..308 — the same band
-- RollFrames.lua's roll rows start in. RollFrames therefore hops its rows
-- above y 308 whenever the stepper is open (MoveMode.SplitShown /
-- onSplitToggle below), so the two DIALOG-strata surfaces never overlap.

local carryBar, barIcon, barName, barCount
local splitSheet, splitCountText, splitNameText

local active = false
local carryCount        -- known quantity on the cursor (split/full-stack pickups)
local carryHomeAction   -- action slot Begin() lifted the carried action from
                        -- (that slot is empty while the carry lives); nil for
                        -- non-action carries and Blizzard-adopted ones
local carryIsAction     -- true while the cursor payload came OFF an action
                        -- slot (Begin kind=="action", or a payload PlaceAction
                        -- displaced from an occupied slot). Tracked as addon
                        -- state because the cursor can't tell us: GetCursorInfo()
                        -- never reports an "action" kind — after PickupAction
                        -- the cursor carries the underlying payload kind
                        -- ("spell"/"item"/"macro"/"petaction"), the same kinds
                        -- Blizzard's own ActionButton code branches on.
local lastCursorKey     -- "type:id" of the last rendered cursor payload
local pendingSplit      -- { bag, slot, count, n } while the stepper is up
local ticker            -- reconcile fallback, alive only while carrying
local targets = {}      -- { overlay, accepts } highlight registry

function MoveMode.IsActive()
	return active
end

--------------------------------------------------------------------------------
-- Payload classification helpers (shared `accepts` predicates)
-- GetCursorInfo returns: "item", itemID, itemLink · "spell", bookSlot,
-- bookType, spellID · "macro", macroIndex · "money", copper · ...
--------------------------------------------------------------------------------

function MoveMode.AcceptsItem(cursorType)
	return cursorType == "item"
end

-- Anything PlaceAction can bind to an action slot.
function MoveMode.AcceptsActionPayload(cursorType)
	return cursorType == "item" or cursorType == "spell"
		or cursorType == "macro" or cursorType == "petaction"
end

-- Character slots light up only for equippable items. Per-slot fit isn't
-- checked (no cheap era API for "does item X go in slot Y"); a wrong-slot tap
-- surfaces Blizzard's own error and the cursor keeps the item.
function MoveMode.AcceptsEquippable(cursorType, _, itemLink)
	return (cursorType == "item" and itemLink and IsEquippableItem(itemLink)) and true or false
end

--------------------------------------------------------------------------------
-- Highlight registry
--------------------------------------------------------------------------------

function MoveMode.RegisterTarget(frame, accepts)
	local overlay = frame:CreateTexture(nil, "OVERLAY", nil, 7)
	overlay:SetAllPoints()
	local g = WM.Colors.green
	overlay:SetColorTexture(g[1], g[2], g[3], 0.28)
	overlay:Hide()
	targets[#targets + 1] = { overlay = overlay, accepts = accepts }
end

local function UpdateHighlights()
	local t, a, b, c = GetCursorInfo()
	for i = 1, #targets do
		local tgt = targets[i]
		tgt.overlay:SetShown(active and t ~= nil and tgt.accepts(t, a, b, c) or false)
	end
end

--------------------------------------------------------------------------------
-- Carry bar rendering
--------------------------------------------------------------------------------

local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"

local function RefreshBarFromCursor()
	local t, a, b, c = GetCursorInfo()
	local icon, name
	if t == "item" then
		-- "item", itemID, itemLink
		name = b and b:match("%[(.-)%]")
		if GetItemIcon then
			icon = GetItemIcon(a)
		elseif GetItemInfoInstant then
			icon = select(5, GetItemInfoInstant(a))
		end
	elseif t == "spell" then
		-- 4th return is the spell ID; GetSpellInfo gives name + icon on era.
		local n, _, ic = GetSpellInfo(c)
		name, icon = n, ic
	elseif t == "macro" then
		local n, ic = GetMacroInfo(a)
		name, icon = n, ic
	elseif t == "money" then
		name, icon = WM.FormatMoney(a), COIN_ICON
	elseif t then
		name = "Held: " .. t
	end
	local key = t and (t .. ":" .. tostring(a)) or nil
	if key ~= lastCursorKey then
		-- A swap replaced the payload mid-carry; the old quantity is stale.
		if lastCursorKey ~= nil then carryCount = nil end
		lastCursorKey = key
	end
	barIcon:SetTexture(icon or WM.TEX_QUESTION)
	barName:SetText(name or "Held item")
	barCount:SetText(carryCount and carryCount > 1 and ("x" .. carryCount) or "")
end

--------------------------------------------------------------------------------
-- Carry lifecycle
--------------------------------------------------------------------------------

local function EndCarry()
	active = false
	carryCount, lastCursorKey, carryHomeAction, carryIsAction = nil, nil, nil, nil
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	if carryBar then carryBar:Hide() end
	UpdateHighlights()
end

local function Reconcile()
	if not active then return end
	if not GetCursorInfo() then
		-- Placed (possibly by an economy sheet's slot) or dropped elsewhere.
		EndCarry()
		return
	end
	RefreshBarFromCursor()
	UpdateHighlights()
end

local function Activate()
	if not carryBar then return end -- pre-init event; nothing to show yet
	active = true
	RefreshBarFromCursor()
	carryBar:Show()
	if not ticker then
		-- Fallback for anything CURSOR_CHANGED/CURSOR_UPDATE misses; only
		-- alive while carrying, so no steady-state timer cost.
		ticker = C_Timer.NewTicker(0.25, Reconcile)
	end
	UpdateHighlights()
end

-- RollFrames.lua sets MoveMode.onSplitToggle and reads MoveMode.SplitShown()
-- to hop its roll rows above the split stepper while it is open (the two
-- would otherwise share the square's bottom-right band — see layout note).
function MoveMode.SplitShown()
	return splitSheet ~= nil and splitSheet:IsShown() or false
end

local function NotifySplitToggle()
	if MoveMode.onSplitToggle then MoveMode.onSplitToggle() end
end

local OnCursorChanged -- defined under "Cursor reconciliation" below

local function HideSplit()
	local wasOpen = pendingSplit ~= nil
	pendingSplit = nil
	if splitSheet and splitSheet:IsShown() then
		splitSheet:Hide()
		NotifySplitToggle()
	end
	-- Adoption is suppressed while the stepper is up (OnCursorChanged bails on
	-- pendingSplit): a pickup made through some other surface meanwhile — an
	-- economy sheet's trade/mail/sell slot lifting an item back, say — left a
	-- full cursor with
	-- no carry bar and no Cancel. Re-run adoption now so it gets both.
	if wasOpen and not active and GetCursorInfo() then
		OnCursorChanged()
	end
end

-- The cancel asymmetry that makes action-origin carries special: ClearCursor()
-- on a bag-item pickup returns the item to its bag slot and on a spellbook
-- pickup just drops the spell (it never left the book) — but PickupAction()
-- already EMPTIED the source action slot, so ClearCursor() on an action-origin
-- payload permanently vacates that bar slot (the drag-off-the-bar removal
-- gesture). Cancelling one must therefore PlaceAction the payload back into
-- its home slot. Since the cursor kind alone can't identify these carries
-- (see carryIsAction above), callers pass the tracked home slot in.
local PLACEABLE = { spell = true, item = true, macro = true, petaction = true }

-- `key` is the cursor identity ("type:id", same key SecureDrop compares)
-- captured when the restore was decided on. The combat-queued path can run
-- SECONDS after Cancel: if Blizzard-cursor-side code (macro frame drag, an
-- economy sheet slot) replaced the cursor payload mid-combat, the original
-- action-origin payload is already gone — and PlaceAction here would slam
-- the unrelated new payload into the old home slot. Bail on a mismatch and
-- leave the foreign payload alone; the PLAYER_REGEN_ENABLED adoption gives
-- it a carry bar of its own.
local function RestoreOrDiscardAction(home, key)
	local t, a = GetCursorInfo()
	if not t then return end -- resolved some other way meanwhile
	if key and (t .. ":" .. tostring(a)) ~= key then return end
	if not PLACEABLE[t] then
		ClearCursor() -- can't live in an action slot; plain drop is all there is
		return
	end
	if home and not HasAction(home) then
		-- The home slot is still empty: put the payload back. (After a swap
		-- this is the DISPLACED action landing in the original's vacated
		-- slot — completing the swap instead of stranding the displaced one.)
		PlaceAction(home)
	else
		-- No empty home slot (adopted/displaced payload with no known origin,
		-- or the home got refilled meanwhile): nowhere safe to restore to.
		-- Discard — loudly — matching the default UI's drag-off-the-bar
		-- removal. Only the bar placement is lost; the spell/macro itself
		-- still exists in the spellbook / macro list.
		UIErrorsFrame:AddMessage("No free home slot - removed from the action bar.", 1, 0.3, 0.3)
		ClearCursor()
	end
end

function MoveMode.Cancel()
	HideSplit()
	local t, a = GetCursorInfo()
	-- EndCarry clears the carry bookkeeping; capture first.
	local home, isAction = carryHomeAction, carryIsAction
	local key = t and (t .. ":" .. tostring(a)) or nil -- payload identity at
	                 -- Cancel time, for the (possibly deferred) restore below
	EndCarry() -- flip state first: the cursor calls below re-enter via CURSOR_CHANGED
	if t == nil then return end
	if isAction then
		if InCombatLockdown() then
			-- PlaceAction is lockdown-blocked and ClearCursor would strip the
			-- payload off the bar for good: fold the UI now, leave the payload
			-- on the Blizzard cursor, and restore it the moment combat ends.
			-- The key makes the deferred restore a no-op if the cursor payload
			-- was replaced meanwhile (see RestoreOrDiscardAction).
			WM.OutOfCombat("movemode-restore-action", function()
				RestoreOrDiscardAction(home, key)
			end)
		else
			RestoreOrDiscardAction(home, key)
		end
		return
	end
	ClearCursor() -- items return to their source slot; spells drop back to the book
end

local function CombatNotice()
	UIErrorsFrame:AddMessage("Items can't be moved during combat.", 1, 0.3, 0.3)
end

--------------------------------------------------------------------------------
-- Split stepper ("Take how many?")
--------------------------------------------------------------------------------

local function RefreshSplit()
	if not pendingSplit then return end
	splitCountText:SetText(pendingSplit.n .. " / " .. pendingSplit.count)
end

local function OpenSplit(bag, slot, count)
	local link = WM.Container.GetItemLink(bag, slot)
	pendingSplit = { bag = bag, slot = slot, count = count, n = 1, link = link }
	splitNameText:SetText((link and link:match("%[(.-)%]")) or "Stack")
	RefreshSplit()
	splitSheet:Show()
	NotifySplitToggle()
end

local function TakeSplit(n)
	local p = pendingSplit
	HideSplit()
	if not p then return end
	if InCombatLockdown() then
		CombatNotice()
		return
	end
	if GetCursorInfo() then
		-- A pickup elsewhere filled the cursor while the stepper was open
		-- (HideSplit above just adopted it into the carry bar): Pickup on the
		-- stepper's slot now would swap that foreign payload into it. Drop
		-- the split; the adopted carry is the live interaction.
		return
	end
	-- Revalidate against the live bag: the stepper holds no lock, so between
	-- opening it and pressing Take the stack can shrink, merge, move, lock
	-- (mid-sale/mail transaction) or be sold. Bail when the slot no longer
	-- holds the same unlocked item; clamp n to the count it holds now.
	local _, count, locked = WM.Container.GetItemInfo(p.bag, p.slot)
	if not count or count < 1 or locked
			or WM.Container.GetItemLink(p.bag, p.slot) ~= p.link then
		return
	end
	if n > count then n = count end
	if n >= count then
		WM.Container.Pickup(p.bag, p.slot) -- whole stack: plain pickup
	else
		WM.Container.Split(p.bag, p.slot, n)
	end
	-- Set carryCount only once the cursor confirms the pickup landed — a
	-- no-opped Pickup/Split must not leave a stale count behind for the next
	-- carry's bar to render.
	if GetCursorInfo() then
		carryCount = n
		Activate()
	end
end

--------------------------------------------------------------------------------
-- Entry
-- payload: { kind = "bag",    bag, slot }
--          { kind = "inv",    slotID }
--          { kind = "spell",  bookSlot, book }
--          { kind = "action", slot }
--------------------------------------------------------------------------------

function MoveMode.Begin(payload)
	if InCombatLockdown() then
		CombatNotice()
		return
	end
	HideSplit()
	-- HideSplit's adoption path can Activate() a foreign cursor carry (a
	-- Blizzard-side pickup made while the stepper was open). Beginning a NEW
	-- pickup on top of that would misfire — e.g. a long-press on an equip
	-- cell would PickupInventoryItem and EQUIP the foreign payload. The
	-- adopted carry wins; the user's tap now targets it instead.
	if active then return end
	carryCount = nil -- no residue from a previous carry: every non-split entry
	                 -- path starts countless (RefreshBarFromCursor only clears
	                 -- it when it saw the previous payload render)
	if payload.kind == "bag" then
		local icon, count = WM.Container.GetItemInfo(payload.bag, payload.slot)
		if not icon then return end -- empty slot: nothing to carry
		if count and count > 1 then
			OpenSplit(payload.bag, payload.slot, count)
			return
		end
		WM.Container.Pickup(payload.bag, payload.slot)
	elseif payload.kind == "inv" then
		if not GetInventoryItemLink("player", payload.slotID) then return end
		PickupInventoryItem(payload.slotID)
	elseif payload.kind == "spell" then
		WM.PickupSpellBookSlot(payload.bookSlot, payload.book)
	elseif payload.kind == "action" then
		if not HasAction(payload.slot) then return end
		PickupAction(payload.slot)
		-- The cursor now reports the underlying spell/item/macro kind, not an
		-- "action" kind — mark the carry ourselves so Cancel knows to
		-- PlaceAction it back here instead of ClearCursor-ing it off the bar.
		carryHomeAction, carryIsAction = payload.slot, true
	end
	if GetCursorInfo() then Activate() end
end

--------------------------------------------------------------------------------
-- Secure-surface plumbing
--------------------------------------------------------------------------------

-- Unknown secure action type: SECURE_ACTIONS has no entry for it, so a
-- right-click performs nothing securely and only our insecure hook below
-- runs. (Without this, "type" would apply to every button and a long-press
-- on a bag cell would USE the item it was trying to pick up.)
local INERT_TYPE2 = "wowmobile-carry"

-- Callers run from out-of-combat code (every cell/button factory already sits
-- inside a WM.OutOfCombat closure) — required for the attribute write.
function MoveMode.AttachSecureSource(button, getPayload)
	button:SetAttribute("type2", INERT_TYPE2)
	button:HookScript("OnClick", function(self, mouseButton)
		if mouseButton ~= "RightButton" then return end
		if self.wmDropHandled then return end -- this click already placed/cancelled
		if active or pendingSplit then return end
		local payload = getPayload(self)
		if payload then MoveMode.Begin(payload) end
	end)
end

-- accepts == nil marks a surface that is never a drop target (spellbook):
-- tapping it while carrying just cancels, so the swallowed click can't cast.
-- isActionTarget marks drop surfaces whose `place` is PlaceAction (the action
-- bars): a payload their placement displaces onto the cursor came OFF an
-- action slot and needs the action-origin cancel handling (carryIsAction).
function MoveMode.SecureDrop(button, accepts, place, isActionTarget)
	button:SetScript("PreClick", function(self)
		if not active then return end
		if InCombatLockdown() then
			-- Should be unreachable: Begin() refuses in combat, adoption is
			-- combat-gated (OnCursorChanged) and PLAYER_REGEN_DISABLED cancels
			-- live carries. If a carry still slipped through, the drop
			-- machinery below cannot run (attribute writes are lockdown-
			-- blocked), so fold the carry UI and let the secure click proceed.
			EndCarry()
			return
		end
		self.wmDropHandled = true
		self.wmSavedType = self:GetAttribute("type")
		self:SetAttribute("type", nil) -- swallow the secure action for this click only
		local t, a, b, c = GetCursorInfo()
		if t and accepts and accepts(t, a, b, c) then
			local prevKey = t .. ":" .. tostring(a)
			local wasAction, home = carryIsAction, carryHomeAction
			place(self)
			carryCount = nil -- whatever rides the cursor now (a swap's displaced
			                 -- payload, possibly the same itemID) has an unknown count
			-- Displacement bookkeeping: a different payload on the cursor after
			-- the place is what the target slot held. Off an action slot it is
			-- action-origin — and when the carry that just landed was itself an
			-- action, its vacated home slot is where a Cancel should complete
			-- the swap; otherwise (spell straight from the book onto an
			-- occupied slot) there is no empty home and Cancel falls back to
			-- the loud discard. Off anything else (bag/equip swaps) ClearCursor
			-- returns the displaced item on its own, so the flags drop.
			local nt, na = GetCursorInfo()
			if nt and (nt .. ":" .. tostring(na)) ~= prevKey then
				carryIsAction = isActionTarget and true or nil
				carryHomeAction = (isActionTarget and wasAction) and home or nil
			end
			Reconcile()
		else
			MoveMode.Cancel()
		end
	end)
	button:SetScript("PostClick", function(self)
		if self.wmSavedType ~= nil then
			self:SetAttribute("type", self.wmSavedType)
			self.wmSavedType = nil
		end
		self.wmDropHandled = nil
	end)
end

-- Insecure equipped-slot cells (CharacterPanel) call this from plain OnClick.
function MoveMode.DropOnInventory(slotID)
	if not active then return end
	local t, a, b = GetCursorInfo()
	if MoveMode.AcceptsEquippable(t, a, b) then
		PickupInventoryItem(slotID) -- equips/swaps; wrong slot → Blizzard error, cursor keeps item
		carryCount = nil -- a displaced equipped item has no stack count
		-- When the equip went through and displaced the slot's old item (the
		-- cursor payload changed), what rides the cursor now is that displaced
		-- equipped item: plain ClearCursor handles it, so the action-origin
		-- flags must not survive even if the equipped payload was an item
		-- lifted off the bar (a Cancel would otherwise PlaceAction the
		-- displaced gear onto the action bar). On a wrong-slot tap the cursor
		-- keeps the original payload and the flags stay valid.
		local nt, na = GetCursorInfo()
		if nt and (nt .. ":" .. tostring(na)) ~= (t .. ":" .. tostring(a)) then
			carryIsAction, carryHomeAction = nil, nil
		end
		Reconcile()
	else
		MoveMode.Cancel()
	end
end

--------------------------------------------------------------------------------
-- Cursor reconciliation + adoption
--------------------------------------------------------------------------------

function OnCursorChanged() -- assigns the forward-declared local (split section)
	if active then
		Reconcile()
		return
	end
	if pendingSplit then return end -- stepper up: adopted when it closes (HideSplit)
	-- Never adopt in combat: the drop machinery (SecureDrop attribute writes)
	-- is dead under lockdown, so a carry UI would advertise placements it
	-- cannot service. The PLAYER_REGEN_ENABLED handler below adopts whatever
	-- is still on the cursor once combat ends.
	if InCombatLockdown() then return end
	-- A Blizzard-cursor-side pickup (macro frame, an economy sheet slot
	-- lifting an item back) filled the cursor without us: adopt it so the
	-- user always has a carry
	-- bar with a Cancel, and so drop targets light up for it too. Known limit:
	-- if Blizzard-side code lifted the payload off an ACTION slot, nothing
	-- observable marks it action-origin (the cursor kind is just spell/item/
	-- macro), so carryIsAction stays unset and Cancel ClearCursors — the same
	-- outcome the default UI gives that drag when dropped onto the world.
	local t = GetCursorInfo()
	if t == "item" or t == "spell" or t == "macro" or t == "money" then
		Activate()
	end
end

--------------------------------------------------------------------------------
-- UI construction
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Carry bar -----------------------------------------------------------
	carryBar = CreateFrame("Button", "WowMobileCarryBar", UIParent)
	carryBar:SetSize(WM.Px(BAR_W), WM.Px(BAR_H))
	carryBar:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	carryBar:SetFrameStrata("DIALOG")
	WM.SkinFrame(carryBar, WM.Colors.panel, WM.Colors.accent)
	carryBar:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- The whole bar cancels; the X is the visible affordance for it. Cancel
	-- returns items/spells to their source and PlaceAction-restores an
	-- action-origin carry to its tracked home slot (see MoveMode.Cancel — the
	-- cursor reports such a carry as plain spell/item/macro, and a bare
	-- ClearCursor would leave its bar slot permanently empty).
	carryBar:SetScript("OnClick", function() MoveMode.Cancel() end)
	carryBar:Hide()

	barIcon = carryBar:CreateTexture(nil, "ARTWORK")
	barIcon:SetSize(WM.Px(96), WM.Px(96))
	barIcon:SetPoint("LEFT", WM.Px(12), 0)
	barCount = WM.CreateText(carryBar, 26, "OUTLINE")
	barCount:SetPoint("BOTTOMRIGHT", barIcon, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	barName = WM.CreateText(carryBar, 28)
	barName:SetPoint("LEFT", WM.Px(122), 0)
	barName:SetPoint("RIGHT", -WM.Px(130), 0)
	barName:SetJustifyH("LEFT")
	barName:SetWordWrap(true)

	local cancel = WM.CreateTouchButton(carryBar, 110, BAR_H - 16, "X", 44)
	cancel:SetPoint("RIGHT", -WM.Px(8), 0)
	cancel:SetScript("OnClick", function() MoveMode.Cancel() end)

	-- Split stepper -------------------------------------------------------
	splitSheet = CreateFrame("Frame", "WowMobileSplitSheet", UIParent)
	splitSheet:SetSize(WM.Px(BAR_W), WM.Px(SPLIT_H))
	splitSheet:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	splitSheet:SetFrameStrata("DIALOG")
	splitSheet:EnableMouse(true)
	WM.SkinFrame(splitSheet, WM.Colors.panel, WM.Colors.accent)
	splitSheet:Hide()

	local title = WM.CreateText(splitSheet, 30)
	title:SetPoint("TOPLEFT", WM.Px(16), -WM.Px(14))
	title:SetText("Take how many?")
	splitNameText = WM.CreateText(splitSheet, 24)
	splitNameText:SetPoint("TOPLEFT", WM.Px(16), -WM.Px(52))
	splitNameText:SetWidth(WM.Px(BAR_W - 140))
	splitNameText:SetJustifyH("LEFT")
	splitNameText:SetWordWrap(false)
	splitNameText:SetTextColor(0.7, 0.7, 0.75)

	local splitClose = WM.CreateTouchButton(splitSheet, 96, 90, "X", 40)
	splitClose:SetPoint("TOPRIGHT", -WM.Px(8), -WM.Px(8))
	splitClose:SetScript("OnClick", HideSplit) -- nothing picked up yet; just dismiss

	local minus = WM.CreateTouchButton(splitSheet, 110, 96, "-", 48)
	minus:SetPoint("BOTTOMLEFT", WM.Px(12), WM.Px(116))
	minus:SetScript("OnClick", function()
		if pendingSplit and pendingSplit.n > 1 then
			pendingSplit.n = pendingSplit.n - 1
			RefreshSplit()
		end
	end)

	local plus = WM.CreateTouchButton(splitSheet, 110, 96, "+", 48)
	plus:SetPoint("BOTTOMLEFT", minus, "BOTTOMRIGHT", WM.Px(210), 0)
	plus:SetScript("OnClick", function()
		if pendingSplit and pendingSplit.n < pendingSplit.count then
			pendingSplit.n = pendingSplit.n + 1
			RefreshSplit()
		end
	end)

	splitCountText = WM.CreateText(splitSheet, 40)
	splitCountText:SetPoint("LEFT", minus, "RIGHT", 0, 0)
	splitCountText:SetPoint("RIGHT", plus, "LEFT", 0, 0)
	splitCountText:SetJustifyH("CENTER")

	local maxBtn = WM.CreateTouchButton(splitSheet, 140, 96, "Max", 30)
	maxBtn:SetPoint("BOTTOMLEFT", WM.Px(12), WM.Px(10))
	maxBtn:SetScript("OnClick", function()
		if pendingSplit then
			pendingSplit.n = pendingSplit.count
			RefreshSplit()
		end
	end)

	local allBtn = WM.CreateTouchButton(splitSheet, 140, 96, "All", 30)
	allBtn:SetPoint("LEFT", maxBtn, "RIGHT", WM.Px(10), 0)
	allBtn:SetScript("OnClick", function()
		if pendingSplit then TakeSplit(pendingSplit.count) end
	end)

	local takeBtn = WM.CreateTouchButton(splitSheet, 240, 96, "Take", 32)
	takeBtn:SetPoint("LEFT", allBtn, "RIGHT", WM.Px(10), 0)
	local a = WM.Colors.accent
	takeBtn.borderTex:SetColorTexture(a[1], a[2], a[3], 1)
	takeBtn:SetScript("OnClick", function()
		if pendingSplit then TakeSplit(pendingSplit.n) end
	end)
end)

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- CURSOR_CHANGED is the 10.0.2+ spelling (the rename of CURSOR_UPDATE; Era
-- 1.15 runs the 10.x engine); CURSOR_UPDATE is the pre-10.0 name — register
-- whichever of the two this build knows.
WM.TryOn("CURSOR_CHANGED", OnCursorChanged)
WM.TryOn("CURSOR_UPDATE", OnCursorChanged)

-- Locked-flag flips accompany pickups/placements this addon didn't make.
WM.On("ITEM_LOCK_CHANGED", function()
	if active then Reconcile() end
end)

WM.On("PLAYER_REGEN_DISABLED", function()
	if pendingSplit then HideSplit() end
	if active then
		-- Cancel folds the UI; for an action-origin carry it does NOT
		-- ClearCursor (that would leave the picked-up slot empty for good) —
		-- it queues the PlaceAction restore through WM.OutOfCombat for the
		-- moment combat ends.
		MoveMode.Cancel()
		CombatNotice()
	end
end)

WM.On("PLAYER_REGEN_ENABLED", function()
	-- A cursor filled mid-combat by Blizzard-side code was deliberately left
	-- un-adopted (see OnCursorChanged); adopt it now that drops work again.
	-- Core's queue flush registered first, so a queued action restore has
	-- already emptied the cursor by the time this runs.
	if not active then OnCursorChanged() end
end)
