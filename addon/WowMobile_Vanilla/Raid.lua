--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Raid
-- Deck panel with a compact, group-sorted raid grid (up to 40 members), a
-- ready-check control, a raid-marker row, and a fullscreen READY-CHECK answer
-- overlay that fires independently of the panel.
--
-- Entry point: long-press the bottom row's "Quests / Raid" button (Deck.lua).
--
-- Platform notes (1.12):
--   * Unit buttons are PLAIN buttons on unit ids "raid1".."raid40" — no
--     secure templates and no combat lockdown exist on this client, so
--     TargetUnit(unit) from OnClick is legal at any time.
--   * GetRaidRosterInfo(i) -> name, rank (2 leader / 1 assist), subgroup,
--     level, class, fileName, zone, online, isDead (vanilla FrameXML
--     RaidFrame.lua reads this shape). Roster index i maps to unit "raid"..i.
--   * Long-press = the boosted unit dropdown. 1.12's raid member menus run
--     through the SHARED FriendsDropDown frame, and the initializer
--     (RaidFrameDropDown_Initialize) lives in the LoD addon Blizzard_RaidUI —
--     loaded whenever you are in a raid (FrameXML RaidFrame.lua LoDs it on
--     RAID_ROSTER_UPDATE), which is the only time these cells exist.
--     RaidGroupButton_OnClick sets NOTHING on FriendsDropDown beyond
--     initialize/displayMode; the initializer runs synchronously inside
--     ToggleDropDownMenu with `this` still the CLICKED frame and reads
--     this.name / this.id / this.unit off it. The cells therefore carry
--     exactly those members (name = string, id = roster index, unit =
--     "raidN"; the name FontString lives on cell.nameText so .name stays a
--     string). Boosted via the wrapped ToggleDropDownMenu in UnitFrames.lua;
--     if a build lacks the initializer the long-press degrades to targeting.
--   * Ready checks exist since 1.11: DoReadyCheck() to start (the default
--     1.12 UI enables its button on IsRaidLeader() only —
--     RaidFrameReadyCheckButton_Update — so assistants are not offered one
--     here either), READY_CHECK on receivers, ConfirmReadyCheck(1) /
--     ConfirmReadyCheck() to answer. On 1.12 the default answer UI is
--     ReadyCheckFrame (Blizzard_RaidUI), shown by UIParent's READY_CHECK
--     handler calling ShowReadyCheck() with NO arguments — the event carries
--     no originator on this client, and Blizzard's own 1.12 code names the
--     initiator by scanning the roster for rank == 2; mirrored here.
--     (UIParent's READY_CHECK registration is dropped in Blizzard.lua; this
--     overlay replaces that path.) 1.12 has no READY_CHECK_FINISHED/CONFIRM
--     events — the overlay runs a local timeout bar (duration arg when a
--     build passes one, else the default 30 s) and hides itself; TryOn
--     covers builds that do fire a FINISHED event.
--   * Raid markers are 1.11+: SetRaidTarget(unit, 0..8) and
--     GetRaidTargetIndex(unit); RAID_TARGET_UPDATE signals changes. Marking
--     requires raid lead/assist (party leader when not in a raid).
--------------------------------------------------------------------------------

local WM = WowMobile

local GROUPS = 8
local PER_GROUP = 5
local CELL_H = 96      -- >= 90 px touch floor
local CELL_GAP = 6
local LABEL_W = 44     -- "G1".."G8" gutter
local CTRL_H = 96
local MARKER_W = 110

local panel, scroller
local readyBtn, statusText
local markerButtons = {}  -- 1..8 markers + [9] = clear
local groupLabels = {}
local cells = {}          -- pooled member cells, 1..40
local unitCells = {}      -- "raidN" -> visible cell (for UNIT_* updates)
local overlay             -- fullscreen ready-check answer overlay

--------------------------------------------------------------------------------
-- Permissions
--------------------------------------------------------------------------------

local function CanMark()
	if GetNumRaidMembers() > 0 then
		return IsRaidLeader() or IsRaidOfficer()
	end
	return GetNumPartyMembers() > 0 and IsPartyLeader()
end

local function CanReadyCheck()
	-- 1.12 ready checks are a raid feature; the default UI gates its button
	-- on IsRaidLeader() alone (RaidFrameReadyCheckButton_Update), so match it
	-- rather than hand an assistant a button whose tap the server ignores.
	return GetNumRaidMembers() > 0 and IsRaidLeader()
end

--------------------------------------------------------------------------------
-- Member cells
--------------------------------------------------------------------------------

local function OpenRaidUnitMenu(cell)
	-- The 1.12 raid menu plumbing (see the header note): the initializer
	-- reads this.name/this.id/this.unit from the CLICKED frame — the cell,
	-- which PaintCell keeps stamped with those exact members — so nothing is
	-- set on FriendsDropDown beyond initialize/displayMode, matching
	-- RaidGroupButton_OnClick. RaidFrameDropDown_Initialize is Blizzard_RaidUI
	-- (LoD, but loaded whenever in a raid); nil-checked for odd builds.
	if FriendsDropDown and RaidFrameDropDown_Initialize then
		-- Pre-clear like RaidGroupButton_OnClick's RightButton branch does:
		-- 1.12 ToggleDropDownMenu CLOSES the list when it is visible and
		-- UIDROPDOWNMENU_OPEN_MENU is this same dropdown's name — and all 40
		-- cells share the ONE FriendsDropDown — so without this, long-pressing
		-- member B while member A's menu is open would dismiss instead of
		-- reopening on B. HideDropDownMenu(1) resets that state first.
		if HideDropDownMenu then
			HideDropDownMenu(1)
		end
		FriendsDropDown.initialize = RaidFrameDropDown_Initialize
		FriendsDropDown.displayMode = "MENU"
		WM.OpenUnitMenu(FriendsDropDown)
	else
		TargetUnit(cell.unit)
	end
end

local function PaintCellHealth(cell)
	local unit = cell.unit
	if cell.offline then
		cell.bar:SetMinMaxValues(0, 1)
		cell.bar:SetValue(0)
		cell.sub:SetText("Offline")
		cell.sub:SetTextColor(0.55, 0.55, 0.6)
		return
	end
	if cell.dead or UnitIsDeadOrGhost(unit) then
		cell.bar:SetMinMaxValues(0, 1)
		cell.bar:SetValue(0)
		cell.sub:SetText(UnitIsGhost(unit) and "Ghost" or "Dead")
		cell.sub:SetTextColor(0.85, 0.3, 0.3)
		return
	end
	local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
	cell.bar:SetMinMaxValues(0, hpMax > 0 and hpMax or 1)
	cell.bar:SetValue(hp)
	if hpMax > 0 then
		cell.sub:SetText(math.floor(hp / hpMax * 100) .. "%")
	else
		cell.sub:SetText("")
	end
	cell.sub:SetTextColor(0.85, 0.85, 0.88)
end

local function AcquireCell(n)
	local cell = cells[n]
	if cell then return cell end
	cell = CreateFrame("Button", nil, scroller.child)
	cell:SetHeight(WM.Px(CELL_H))
	WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
	local hl = cell:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(cell)
	hl:SetTexture(1, 1, 1, 0.10)
	cell.bar = CreateFrame("StatusBar", nil, cell)
	cell.bar:SetStatusBarTexture(WM.TEX_WHITE)
	cell.bar:SetPoint("TOPLEFT", cell, "TOPLEFT", WM.Px(4), -WM.Px(4))
	cell.bar:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	local bg = cell.bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(cell.bar)
	bg:SetTexture(0.05, 0.05, 0.06, 1)
	-- The FontString is cell.nameText, NOT cell.name — the menu initializer
	-- reads cell.name as the member's name STRING (see OpenRaidUnitMenu).
	cell.nameText = WM.CreateText(cell, 24, "OUTLINE")
	cell.nameText:SetPoint("TOP", cell, "TOP", 0, -WM.Px(12))
	cell.nameText:SetWidth(WM.Px(168))
	cell.nameText:SetJustifyH("CENTER")
	WM.SingleLine(cell.nameText, 24)
	cell.sub = WM.CreateText(cell, 20, "OUTLINE")
	cell.sub:SetPoint("BOTTOM", cell, "BOTTOM", 0, WM.Px(10))
	cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	cell:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			OpenRaidUnitMenu(this)
		else
			TargetUnit(this.unit)
		end
	end)
	-- Tooltip above the finger, standard unit tooltip.
	WM.AttachTooltip(cell, function(tt, self)
		tt:SetUnit(self.unit)
	end)
	cells[n] = cell
	return cell
end

local function PaintCell(cell, rosterIndex)
	local name, _, _, level, _, _, _, online, isDead = GetRaidRosterInfo(rosterIndex)
	-- name / id / unit are the exact members RaidFrameDropDown_Initialize
	-- reads off the clicked frame (see OpenRaidUnitMenu).
	cell.name = name
	cell.id = rosterIndex
	cell.unit = "raid" .. rosterIndex
	cell.offline = not online
	cell.dead = isDead and true or false
	cell.nameText:SetText(name or "?")
	if online then
		local r, g, b = WM.UnitColor(cell.unit)
		cell.nameText:SetTextColor(r, g, b)
		cell.bar:SetStatusBarColor(r, g, b)
	else
		cell.nameText:SetTextColor(0.55, 0.55, 0.6)
		cell.bar:SetStatusBarColor(0.3, 0.3, 0.33)
	end
	PaintCellHealth(cell)
end

--------------------------------------------------------------------------------
-- Grid rebuild (group-sorted rows: one row per subgroup)
--------------------------------------------------------------------------------

local groupBuckets = {}
for g = 1, GROUPS do groupBuckets[g] = {} end

local function Rebuild()
	if not panel:IsShown() then return end
	for u in pairs(unitCells) do unitCells[u] = nil end
	for g = 1, GROUPS do
		local bucket = groupBuckets[g]
		for i = table.getn(bucket), 1, -1 do table.remove(bucket, i) end
	end

	local n = GetNumRaidMembers()
	if n == 0 then
		statusText:SetText("You are not in a raid.")
	else
		statusText:SetText(n .. " raid members")
	end
	WM.SetButtonEnabled(readyBtn, CanReadyCheck())

	for i = 1, n do
		local _, _, subgroup = GetRaidRosterInfo(i)
		if subgroup and subgroup >= 1 and subgroup <= GROUPS then
			table.insert(groupBuckets[subgroup], i)
		end
	end

	-- Cell width: the scroller viewport is 1064 - 98 = 966 px; the group
	-- gutter takes 44 + 6, leaving 916 for 5 cells -> (916 - 4*6)/5 = 178.
	local cellW = 178
	local used = 0
	local usedLabels = 0
	local y = 0
	for g = 1, GROUPS do
		local bucket = groupBuckets[g]
		local count = table.getn(bucket)
		if count > 0 then
			usedLabels = usedLabels + 1
			local lbl = groupLabels[usedLabels]
			if not lbl then
				lbl = WM.CreateText(scroller.child, 26, "OUTLINE")
				lbl:SetTextColor(1, 0.82, 0)
				groupLabels[usedLabels] = lbl
			end
			lbl:ClearAllPoints()
			lbl:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
				WM.Px(4), -WM.Px(y + CELL_H / 2 - 14))
			lbl:SetText("G" .. g)
			lbl:Show()
			for m = 1, count do
				if m > PER_GROUP then break end -- server-side cap, belt and braces
				used = used + 1
				local cell = AcquireCell(used)
				cell:ClearAllPoints()
				cell:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
					WM.Px(LABEL_W + 6 + (m - 1) * (cellW + CELL_GAP)), -WM.Px(y))
				cell:SetWidth(WM.Px(cellW))
				PaintCell(cell, bucket[m])
				unitCells[cell.unit] = cell
				cell:Show()
			end
			y = y + CELL_H + CELL_GAP
		end
	end
	for i = used + 1, table.getn(cells) do cells[i]:Hide() end
	for i = usedLabels + 1, table.getn(groupLabels) do groupLabels[i]:Hide() end
	scroller.SetContentHeight(WM.Px(y + 8))
end

--------------------------------------------------------------------------------
-- Marker row
--------------------------------------------------------------------------------

local function PaintMarkers()
	if not panel:IsShown() then return end
	local canMark = CanMark()
	local hasTarget = UnitExists("target")
	local current = GetRaidTargetIndex and GetRaidTargetIndex("target") or nil
	for i = 1, 9 do
		local b = markerButtons[i]
		WM.SetButtonEnabled(b, canMark and hasTarget)
		if b.icon then
			if canMark and hasTarget then
				b.icon:SetVertexColor(1, 1, 1)
			else
				b.icon:SetVertexColor(0.4, 0.4, 0.45)
			end
		end
		WM.TintBorder(b, (i == current) and WM.Colors.accent or WM.Colors.border)
	end
end

local function CreateMarkerRow()
	-- 8 marker buttons + Clear: 9 * 110 + 8 * 6 = 1038 <= 1064 content width;
	-- 110x90 keeps every one on the touch floor. Icons come from the combined
	-- 1.12 sheet Interface\TargetingFrame\UI-RaidTargetingIcons (4x2 grid,
	-- 0.25 texcoord stride — the same mapping FrameXML's
	-- SetRaidTargetIconTexture uses).
	local prev
	for i = 1, 9 do
		local b = WM.CreateTouchButton(panel.content, MARKER_W, 90, nil, 30)
		if prev then
			b:SetPoint("TOPLEFT", prev, "TOPRIGHT", WM.Px(6), 0)
		else
			b:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(CTRL_H + 6))
		end
		if i <= 8 then
			b.icon = b:CreateTexture(nil, "ARTWORK")
			b.icon:SetWidth(WM.Px(64))
			b.icon:SetHeight(WM.Px(64))
			b.icon:SetPoint("CENTER", b, "CENTER", 0, 0)
			b.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
			local left = math.mod(i - 1, 4) * 0.25
			local top = math.floor((i - 1) / 4) * 0.25
			b.icon:SetTexCoord(left, left + 0.25, top, top + 0.25)
			b.markerIndex = i
		else
			b.label:SetText("Clear")
			b.markerIndex = 0
		end
		b:SetScript("OnClick", function()
			if UnitExists("target") and SetRaidTarget then
				SetRaidTarget("target", this.markerIndex)
			end
		end)
		markerButtons[i] = b
		prev = b
	end
end

--------------------------------------------------------------------------------
-- Ready-check answer overlay (fullscreen over the deck; independent of the
-- panel — a raider who never opens the raid panel still gets asked)
--------------------------------------------------------------------------------

local READY_TIMEOUT = 30 -- 1.12 server-side ready-check window

local function OverlayOnUpdate()
	local remain = this.endTime - GetTime()
	if remain <= 0 then
		this:Hide() -- no answer = the server counts us as not ready, honestly shown
	else
		this.timer:SetValue(remain)
	end
end

local function CreateOverlay()
	-- FULLSCREEN_DIALOG + decisive level bump BEFORE children are created —
	-- the Core confirm-overlay technique, so no open sheet/panel out-levels
	-- the Ready buttons.
	local o = CreateFrame("Frame", "WowMobileReadyCheckOverlay", UIParent)
	o:SetFrameStrata("FULLSCREEN_DIALOG")
	o:SetFrameLevel(o:GetFrameLevel() + 20)
	o:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", 0, 0)
	o:SetPoint("BOTTOMRIGHT", WM.Deck, "BOTTOMRIGHT", 0, 0)
	o:EnableMouse(true)
	WM.SkinFrame(o, WM.Colors.panel, WM.Colors.accent)
	o:Hide()

	o.text = WM.CreateText(o, 40)
	o.text:SetPoint("TOPLEFT", o, "TOPLEFT", WM.Px(32), -WM.Px(60))
	o.text:SetPoint("TOPRIGHT", o, "TOPRIGHT", -WM.Px(32), -WM.Px(60))
	o.text:SetJustifyH("CENTER")

	o.timer = CreateFrame("StatusBar", nil, o)
	o.timer:SetStatusBarTexture(WM.TEX_WHITE)
	o.timer:SetStatusBarColor(1, 0.82, 0)
	o.timer:SetPoint("TOPLEFT", o, "TOPLEFT", WM.Px(32), -WM.Px(190))
	o.timer:SetPoint("TOPRIGHT", o, "TOPRIGHT", -WM.Px(32), -WM.Px(190))
	o.timer:SetHeight(WM.Px(20))
	local tbg = o.timer:CreateTexture(nil, "BACKGROUND")
	tbg:SetAllPoints(o.timer)
	tbg:SetTexture(0.05, 0.05, 0.06, 1)

	-- Big Ready / Not Ready: 480x200 each, far past the touch floor.
	local yes = WM.CreateTouchButton(o, 480, 200, "Ready", 44)
	yes:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", WM.Px(32), WM.Px(40))
	yes.label:SetTextColor(0.3, 0.85, 0.35)
	yes:SetScript("OnClick", function()
		ConfirmReadyCheck(1) -- the default popup's OnAccept call
		o:Hide()
	end)
	local no = WM.CreateTouchButton(o, 480, 200, "Not Ready", 44)
	no:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT", -WM.Px(32), WM.Px(40))
	no.label:SetTextColor(0.85, 0.3, 0.3)
	no:SetScript("OnClick", function()
		ConfirmReadyCheck() -- the default popup's OnCancel call (no arg = not ready)
		o:Hide()
	end)

	-- Draining bar, frame-granularity SetValue only — no allocations.
	o:SetScript("OnUpdate", OverlayOnUpdate)
	return o
end

local function ShowReadyCheck(originator, duration)
	-- 1.12's READY_CHECK carries no originator arg (UIParent's handler calls
	-- ShowReadyCheck() with no arguments) — derive the initiator the way
	-- Blizzard's own 1.12 code does: scan the roster for rank == 2 (leader;
	-- only the leader can start one on this client). The arg is still read
	-- first for builds that do pass it.
	if not originator and GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local name, rank = GetRaidRosterInfo(i)
			if rank == 2 then
				originator = name
				break
			end
		end
	end
	-- The initiator is auto-ready server-side and needs no prompt.
	if originator and originator == UnitName("player") then return end
	-- The dropped default path's audio cue (1.12 UIParent.lua ShowReadyCheck
	-- calls PlaySound("ReadyCheck")) — keep it so the timed prompt never
	-- arrives silently.
	PlaySound("ReadyCheck")
	local secs = READY_TIMEOUT
	if type(duration) == "number" and duration > 0 then
		secs = duration
	end
	overlay.text:SetText((originator or "Someone") ..
		" has started a ready check. Are you ready?")
	overlay.endTime = GetTime() + secs
	overlay.timer:SetMinMaxValues(0, secs)
	overlay.timer:SetValue(secs)
	overlay:Show()
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("raid", "Raid")

	-- Control row: ready check + status.
	readyBtn = WM.CreateTouchButton(panel.content, 320, CTRL_H, "Ready check", 30)
	readyBtn:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, 0)
	readyBtn:SetScript("OnClick", function()
		if CanReadyCheck() and DoReadyCheck then
			DoReadyCheck()
			WM.Print("Ready check started.")
		end
	end)

	statusText = WM.CreateText(panel.content, 30)
	statusText:SetPoint("LEFT", readyBtn, "RIGHT", WM.Px(24), 0)
	statusText:SetTextColor(0.75, 0.75, 0.8)

	CreateMarkerRow()

	-- Grid below the two control rows (96 + 6 + 90 + 8 = 200).
	local gridArea = CreateFrame("Frame", nil, panel.content)
	gridArea:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(200))
	gridArea:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, 0)
	scroller = WM.Deck.CreateScroller(gridArea)

	overlay = CreateOverlay()

	panel.OnOpen = function()
		Rebuild()
		PaintMarkers()
		scroller.ScrollToTop()
	end

	WM.On("RAID_ROSTER_UPDATE", function()
		Rebuild()
		PaintMarkers() -- lead/assist may have changed
	end)
	WM.On("PARTY_MEMBERS_CHANGED", PaintMarkers)
	WM.On("PARTY_LEADER_CHANGED", PaintMarkers)
	WM.On("PLAYER_TARGET_CHANGED", PaintMarkers)
	WM.TryOn("RAID_TARGET_UPDATE", PaintMarkers)

	-- Health updates hit only the one visible cell — no rebuild, no garbage.
	local function OnUnitHealth(_, unit)
		local cell = unitCells[unit]
		if cell and panel:IsShown() then
			PaintCellHealth(cell)
		end
	end
	WM.On("UNIT_HEALTH", OnUnitHealth)
	WM.On("UNIT_MAXHEALTH", OnUnitHealth)

	WM.On("READY_CHECK", function(_, originator, duration)
		ShowReadyCheck(originator, duration)
	end)
	-- Not present on 1.12 (see header); harmless where a build adds it.
	WM.TryOn("READY_CHECK_FINISHED", function()
		overlay:Hide()
	end)
end)
