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
-- slow ticker that only runs while carrying), so Blizzard-side placements —
-- the boosted bank/mail/trade frames place a carried item through their own
-- insecure click handlers — can never desync this UI, and a cursor filled by
-- Blizzard code is adopted into the same carry bar so it always has a visible
-- Cancel. ALL move mutations are out-of-combat: Begin() in combat shows a
-- notice and does nothing, and entering combat cancels the carry outright —
-- no silent queueing of item moves, by design.
--
-- Integration contract (Bags / Spellbook / ActionBars / CharacterPanel):
--   AttachSecureSource(btn, getPayload) — right-click enters move mode; the
--       button's "type2" becomes a secure no-op so the right-click never also
--       fires the secure action (surfaces whose right-click already meant
--       something, e.g. the pet strip's togglemenu, simply don't attach).
--   SecureDrop(btn, accepts, place) — tap while carrying places (or cancels,
--       when the payload doesn't fit), swallowing the button's secure action
--       for exactly that click: PreClick nils "type", PostClick restores it.
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
--   * with a full party, PartyMemberFrame4's bottom (x 690..960, chain ends
--     ~1050 at default height, Blizzard.lua) is briefly covered.
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
	carryCount, lastCursorKey, carryHomeAction = nil, nil, nil
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
		-- Placed (possibly by a boosted Blizzard frame) or dropped elsewhere.
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

local function HideSplit()
	pendingSplit = nil
	if splitSheet and splitSheet:IsShown() then
		splitSheet:Hide()
		NotifySplitToggle()
	end
end

-- On this engine ClearCursor() on an "action" payload DESTROYS the action —
-- it is the client's drag-off-the-bar removal gesture, and PickupAction()
-- already emptied the source slot. Cancelling a carried action must therefore
-- PlaceAction it back into its home slot, never bare-ClearCursor it.
-- `home` may be nil (adopted carry): GetCursorInfo() for an "action" payload
-- returns the slot it was picked up from as its first data value (10.x cursor
-- API, which Era 1.15 runs), so that serves as the fallback.
local function RestoreOrDiscardAction(home)
	local t, cursorSlot = GetCursorInfo()
	if t ~= "action" then return end -- resolved some other way meanwhile
	home = home or cursorSlot
	if home and not HasAction(home) then
		-- The home slot is still empty: put the carried action back. (After a
		-- swap this is the DISPLACED action landing in the original's old
		-- slot — completing the swap instead of destroying the displaced one.)
		PlaceAction(home)
	else
		-- No empty home slot (the payload is a displaced action whose slot now
		-- holds what we placed there): nowhere safe to restore to. Discard —
		-- loudly — matching the default UI's drag-off-the-bar removal.
		UIErrorsFrame:AddMessage("No empty home slot - action removed from the bar.", 1, 0.3, 0.3)
		ClearCursor()
	end
end

function MoveMode.Cancel()
	HideSplit()
	local t = GetCursorInfo()
	local home = carryHomeAction -- EndCarry clears it; capture first
	EndCarry() -- flip state first: the cursor calls below re-enter via CURSOR_CHANGED
	if t == "action" then
		if InCombatLockdown() then
			-- PlaceAction is lockdown-blocked and ClearCursor would destroy
			-- the action: fold the UI now, leave the payload on the Blizzard
			-- cursor, and restore it the moment combat ends.
			WM.OutOfCombat("movemode-restore-action", function()
				RestoreOrDiscardAction(home)
			end)
		else
			RestoreOrDiscardAction(home)
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
	pendingSplit = { bag = bag, slot = slot, count = count, n = 1 }
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
	if n >= p.count then
		WM.Container.Pickup(p.bag, p.slot) -- whole stack: plain pickup
		carryCount = p.count
	else
		WM.Container.Split(p.bag, p.slot, n)
		carryCount = n
	end
	if GetCursorInfo() then Activate() end
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
	if payload.kind == "bag" then
		local icon, count = WM.Container.GetItemInfo(payload.bag, payload.slot)
		if not icon then return end -- empty slot: nothing to carry
		if count and count > 1 then
			OpenSplit(payload.bag, payload.slot, count)
			return
		end
		WM.Container.Pickup(payload.bag, payload.slot)
		carryCount = nil
	elseif payload.kind == "inv" then
		if not GetInventoryItemLink("player", payload.slotID) then return end
		PickupInventoryItem(payload.slotID)
	elseif payload.kind == "spell" then
		WM.PickupSpellBookSlot(payload.bookSlot, payload.book)
	elseif payload.kind == "action" then
		if not HasAction(payload.slot) then return end
		PickupAction(payload.slot)
		carryHomeAction = payload.slot -- Cancel restores here (see RestoreOrDiscardAction)
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
function MoveMode.SecureDrop(button, accepts, place)
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
			place(self)
			carryCount = nil -- whatever rides the cursor now (a swap's displaced
			                 -- payload, possibly the same itemID) has an unknown count
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
		Reconcile()
	else
		MoveMode.Cancel()
	end
end

--------------------------------------------------------------------------------
-- Cursor reconciliation + adoption
--------------------------------------------------------------------------------

local function OnCursorChanged()
	if active then
		Reconcile()
		return
	end
	if pendingSplit then return end -- stepper up: nothing on the cursor yet
	-- Never adopt in combat: the drop machinery (SecureDrop attribute writes)
	-- is dead under lockdown, so a carry UI would advertise placements it
	-- cannot service. The PLAYER_REGEN_ENABLED handler below adopts whatever
	-- is still on the cursor once combat ends.
	if InCombatLockdown() then return end
	-- A Blizzard-side pickup (macro frame, a boosted default frame's drag)
	-- filled the cursor without us: adopt it so the user always has a carry
	-- bar with a Cancel, and so drop targets light up for it too.
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
	-- returns items/spells to their source and PlaceAction-restores a carried
	-- action to its home slot (see MoveMode.Cancel — a bare ClearCursor would
	-- destroy an action payload on this engine).
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

-- CURSOR_CHANGED is the 8.0+/10.x event (Era 1.15 runs the 10.x engine);
-- CURSOR_UPDATE is the older spelling — register whichever exists.
WM.TryOn("CURSOR_CHANGED", OnCursorChanged)
WM.TryOn("CURSOR_UPDATE", OnCursorChanged)

-- Locked-flag flips accompany pickups/placements this addon didn't make.
WM.On("ITEM_LOCK_CHANGED", function()
	if active then Reconcile() end
end)

WM.On("PLAYER_REGEN_DISABLED", function()
	if pendingSplit then HideSplit() end
	if active then
		-- Cancel folds the UI; for an action payload it does NOT ClearCursor
		-- (that would destroy the action) — it queues the PlaceAction restore
		-- through WM.OutOfCombat for the moment combat ends.
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
