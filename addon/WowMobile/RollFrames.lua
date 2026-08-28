--------------------------------------------------------------------------------
-- WowMobile · RollFrames
-- Group-loot rolls as big touch rows pinned above the deck (the default
-- GroupLootFrames are banished in Blizzard.lua): START_LOOT_ROLL adds a row —
-- item icon (tap = tooltip), name, NEED / GREED / PASS buttons and a draining
-- timer bar — stacking upward for simultaneous rolls; rows leave on roll or
-- CANCEL_LOOT_ROLL. CONFIRM_LOOT_ROLL (BoP need/greed) flows through a
-- StaticPopup (boosted by Blizzard.lua) whose accept calls ConfirmLootRoll.
--
-- Layout budget (design px, world-square coordinates): rows span x 504..960 —
-- right of the client joystick's capture zone (x <= 486, y >= 594; budget
-- tables in Pet.lua/ActionBars.lua) and left of the quick-bar column
-- (x >= 976, Minimap.lua's right-edge table) — stacking upward from y=136
-- above the square's bottom edge, clear of MoveMode's carry bar (bottom
-- 8..128). MoveMode's split stepper is TALLER (x 500..1072, y 8..308): while
-- it is open, rows hop up to y=316 (MoveMode.SplitShown/onSplitToggle wiring
-- below) so Need/Greed/Pass are never buried under the stepper on the shared
-- DIALOG strata. Accepted transient overlap: with a full party the
-- PartyMemberFrame3/4 band (x 690..960, y ~690..1050, Blizzard.lua) sits
-- under active roll rows; rolls only exist in groups, live at most ~60 s and
-- draw above on DIALOG strata, so the covered party frames are briefly
-- untappable — the deliberate tradeoff for keeping rolls in thumb reach.
--
-- Rolls in flight across a /reload can't be recovered: the classic API has no
-- enumerator for active roll IDs (GetActiveLootRollIDs is retail-only), so a
-- reload mid-roll silently forfeits to the server timeout — same limitation
-- the default classic UI has.
--------------------------------------------------------------------------------

local _, WM = ...

local ROW_W, ROW_H = 456, 176
local GAP = 8
local BOTTOM_Y = 136       -- above MoveMode's carry bar (bottom 8..128)
local BOTTOM_Y_SPLIT = 316 -- above MoveMode's split stepper (bottom 8..308)

local container
local pool = {}   -- all created rows
local order = {}  -- rollID stack order, bottom-up

local function RowFor(rollID)
	for i = 1, #pool do
		if pool[i]:IsShown() and pool[i].rollID == rollID then
			return pool[i]
		end
	end
	return nil
end

local function Relayout()
	-- Lane base: hop above the split stepper while it is open (see header).
	local y = (WM.MoveMode and WM.MoveMode.SplitShown()) and BOTTOM_Y_SPLIT or BOTTOM_Y
	container:ClearAllPoints()
	container:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT",
		-WM.Px(120), WM.Px(y))
	local shown = 0
	for i = 1, #order do
		local row = RowFor(order[i])
		if row then
			row:ClearAllPoints()
			row:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, WM.Px(shown * (ROW_H + GAP)))
			shown = shown + 1
		end
	end
	container:SetShown(shown > 0) -- hiding also stops the OnUpdate ticker
end

local function RemoveRoll(rollID)
	local row = RowFor(rollID)
	if row then
		row.rollID = nil
		row:Hide()
	end
	for i = #order, 1, -1 do
		if order[i] == rollID then
			table.remove(order, i)
		end
	end
	Relayout()
end

-- Era 1.15 GetLootRollItemInfo: texture, name, count, quality, bindOnPickUp,
-- canNeed, canGreed, canDisenchant, ... (the classic shape; reason codes
-- trail and are unused here).
local function RefreshRowInfo(row)
	local texture, name, count, quality, bop, canNeed, canGreed =
		GetLootRollItemInfo(row.rollID)
	row.pendingInfo = (name == nil) -- uncached: the ticker below retries
	row.bop = bop and true or false
	row.icon:SetTexture(texture or WM.TEX_QUESTION)
	row.countText:SetText(count and count > 1 and count or "")
	local q = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if q then
		row.name:SetTextColor(q.r, q.g, q.b)
	else
		row.name:SetTextColor(0.92, 0.92, 0.92)
	end
	row.name:SetText(name or RETRIEVING_ITEM_INFO)
	WM.SetButtonEnabled(row.needBtn, canNeed and true or false)
	WM.SetButtonEnabled(row.greedBtn, canGreed and true or false)
	WM.SetButtonEnabled(row.passBtn, true)
end

local function DoRoll(row, rollType)
	if not row.rollID then return end
	RollOnLoot(row.rollID, rollType)
	-- BoP need/greed may require server confirmation (CONFIRM_LOOT_ROLL): keep
	-- the row until CANCEL_LOOT_ROLL (or the popup's accept) so dismissing the
	-- popup leaves the buttons available to roll again. Everything else is
	-- final the moment it's sent.
	if rollType == 0 or not row.bop then
		RemoveRoll(row.rollID)
	end
end

local function CreateRow()
	local row = CreateFrame("Frame", "WowMobileRollRow" .. (#pool + 1), container)
	row:SetSize(WM.Px(ROW_W), WM.Px(ROW_H))
	row:SetFrameStrata("DIALOG")
	WM.SkinFrame(row, WM.Colors.panel)

	-- Icon as a button purely for the tooltip (the injected tap's hover fires
	-- OnEnter); anchored above per the tooltip-clear-of-finger rule.
	local iconBtn = CreateFrame("Button", nil, row)
	iconBtn:SetSize(WM.Px(92), WM.Px(92))
	iconBtn:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(12))
	row.icon = iconBtn:CreateTexture(nil, "ARTWORK")
	row.icon:SetAllPoints()
	row.countText = WM.CreateText(iconBtn, 24, "OUTLINE")
	row.countText:SetPoint("BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	WM.AttachTooltip(iconBtn, function(tt)
		if row.rollID then tt:SetLootRollItem(row.rollID) end
	end)

	row.name = WM.CreateText(row, 24)
	row.name:SetPoint("TOPLEFT", WM.Px(108), -WM.Px(12))
	row.name:SetPoint("TOPRIGHT", -WM.Px(8), -WM.Px(12))
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	-- 108x96 buttons: >=90 px touch targets.
	row.needBtn = WM.CreateTouchButton(row, 108, 96, "Need", 26)
	row.needBtn:SetPoint("TOPLEFT", WM.Px(104), -WM.Px(46))
	local g = WM.Colors.green
	row.needBtn.borderTex:SetColorTexture(g[1], g[2], g[3], 1)
	row.needBtn:SetScript("OnClick", function() DoRoll(row, 1) end)

	row.greedBtn = WM.CreateTouchButton(row, 108, 96, "Greed", 26)
	row.greedBtn:SetPoint("LEFT", row.needBtn, "RIGHT", WM.Px(8), 0)
	local a = WM.Colors.accent
	row.greedBtn.borderTex:SetColorTexture(a[1], a[2], a[3], 1)
	row.greedBtn:SetScript("OnClick", function() DoRoll(row, 2) end)

	row.passBtn = WM.CreateTouchButton(row, 108, 96, "Pass", 26)
	row.passBtn:SetPoint("LEFT", row.greedBtn, "RIGHT", WM.Px(8), 0)
	row.passBtn:SetScript("OnClick", function() DoRoll(row, 0) end)

	row.timer = CreateFrame("StatusBar", nil, row)
	row.timer:SetStatusBarTexture(WM.TEX_WHITE)
	row.timer:SetStatusBarColor(1, 0.82, 0)
	row.timer:SetPoint("BOTTOMLEFT", WM.Px(4), WM.Px(4))
	row.timer:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	row.timer:SetHeight(WM.Px(12))
	local bg = row.timer:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.06, 1)

	pool[#pool + 1] = row
	return row
end

local function AddRoll(rollID, rollTime)
	if RowFor(rollID) then return end
	local row
	for i = 1, #pool do
		if not pool[i]:IsShown() then
			row = pool[i]
			break
		end
	end
	row = row or CreateRow()
	row.rollID = rollID
	row.timer:SetMinMaxValues(0, rollTime or 60000)
	row.timer:SetValue(GetLootRollTimeLeft(rollID) or rollTime or 0)
	RefreshRowInfo(row)
	row:Show()
	order[#order + 1] = rollID
	Relayout()
end

WM.OnInit(function()
	container = CreateFrame("Frame", "WowMobileRollFrames", UIParent)
	container:SetSize(WM.Px(ROW_W), WM.Px(ROW_H))
	container:SetPoint("BOTTOMRIGHT", WM.WorldSquare, "BOTTOMRIGHT",
		-WM.Px(120), WM.Px(BOTTOM_Y))
	container:SetFrameStrata("DIALOG")
	container:Hide()

	-- Re-lane the rows whenever MoveMode's split stepper opens/closes
	-- (MoveMode.lua loads earlier, so WM.MoveMode exists by init time).
	if WM.MoveMode then
		WM.MoveMode.onSplitToggle = Relayout
	end

	-- One throttled OnUpdate for every visible row (no per-row timers, no
	-- allocations): drains the timer bars and retries uncached item info.
	-- Runs only while the container is shown, i.e. while rolls exist.
	container:SetScript("OnUpdate", function(self, elapsed)
		self.acc = (self.acc or 0) + elapsed
		if self.acc < 0.1 then return end
		self.acc = 0
		for i = 1, #pool do
			local row = pool[i]
			if row:IsShown() and row.rollID then
				row.timer:SetValue(GetLootRollTimeLeft(row.rollID) or 0)
				if row.pendingInfo then RefreshRowInfo(row) end
			end
		end
	end)

	-- BoP roll confirmation, re-raised through the (boosted) StaticPopups.
	-- NOTE: CONFIRM_LOOT_ROLL is handled by UIParent's shared retail-lineage
	-- OnEvent (which raises the default "CONFIRM_LOOT_ROLL" popup), NOT by the
	-- banished group-loot frames — so banishing them does not suppress it.
	-- UIParent registered its events before this addon loaded, so its handler
	-- runs first; the StaticPopup_Hide in the handler below then removes the
	-- default popup before this touch-sized one is shown in its place.
	StaticPopupDialogs["WOWMOBILE_CONFIRM_LOOT_ROLL"] = {
		text = LOOT_NO_DROP or "Rolling for this item will bind it to you.",
		button1 = YES,
		button2 = NO,
		OnAccept = function(_, data)
			ConfirmLootRoll(data.rollID, data.rollType)
			RemoveRoll(data.rollID)
		end,
		timeout = 0,
		hideOnEscape = 1,
		multiple = 1,
	}

	WM.On("START_LOOT_ROLL", function(_, rollID, rollTime)
		AddRoll(rollID, rollTime)
	end)
	WM.On("CANCEL_LOOT_ROLL", function(_, rollID)
		RemoveRoll(rollID)
		-- The roll resolved/expired: a confirm popup still up for it would be
		-- a dead modal whose accept confirms an expired rollID — kill it.
		-- multiple=1 means several instances can be up; walk the frames and
		-- hide only the one(s) carrying this rollID.
		for i = 1, STATICPOPUP_NUMDIALOGS or 4 do
			local popup = _G["StaticPopup" .. i]
			if popup and popup:IsShown()
					and popup.which == "WOWMOBILE_CONFIRM_LOOT_ROLL"
					and popup.data and popup.data.rollID == rollID then
				popup:Hide()
			end
		end
	end)
	WM.On("CONFIRM_LOOT_ROLL", function(_, rollID, rollType)
		-- Remove the default popup UIParent just raised (see note above), then
		-- show the touch-sized replacement.
		StaticPopup_Hide("CONFIRM_LOOT_ROLL")
		StaticPopup_Show("WOWMOBILE_CONFIRM_LOOT_ROLL", nil, nil,
			{ rollID = rollID, rollType = rollType })
	end)
end)
