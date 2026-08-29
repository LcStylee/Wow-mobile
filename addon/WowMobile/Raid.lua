--------------------------------------------------------------------------------
-- WowMobile · Raid
-- Deck panel with a compact raid grid plus the ready-check flow:
--   * grid — up to 40 SecureUnitButtonTemplate cells (unit raid1..raid40,
--     fixed per cell so combat never needs an attribute write), one column
--     per subgroup, class-colored health bars, name, Dead/Ghost/Offline
--     states; tap = target, long-press = the boosted unit menu (togglemenu,
--     same as the deck unit frames). Show/hide is RegisterUnitWatch, so cells
--     stay correct in combat; the group-sorted RE-LAYOUT is protected-frame
--     work and rides the combat queue (positions go stale mid-fight after a
--     roster change and snap right at PLAYER_REGEN_ENABLED — accepted).
--   * tool row — Ready check (leader/assist) and the raid-marker row
--     (skull, cross, ... + clear) applied to the current target. Marking is
--     lead/assist-gated in a raid; in a plain party the 10.x engine lets any
--     member mark, so the row stays enabled there (a server-side refusal
--     just no-ops). SetRaidTarget is not protected.
--   * READY_CHECK → fullscreen overlay with big Ready / Not Ready and a
--     draining timeout bar (event's timeLeft arg); READY_CHECK_FINISHED (or
--     answering) dismisses it. The default ReadyCheckFrame AND the compact
--     raid frames are banished in Blizzard.lua, so per-member answers are
--     surfaced here: each grid cell carries a ready-check badge (waiting /
--     ready / not-ready via READY_CHECK_CONFIRM, unanswered flipped to
--     not-ready at READY_CHECK_FINISHED — the default UI's AFK rule — then
--     cleared after a short linger). The panel need not be open for the
--     answer overlay to work.
-- When not in a raid the grid area shows a notice instead (party members
-- already live on the re-homed Blizzard party frames, Blizzard.lua — a
-- duplicate 5-cell grid here would just shadow them).
--------------------------------------------------------------------------------

local _, WM = ...

local MAX_RAID = 40
-- 8 columns, one per subgroup (LayoutGrid keys columns off the subgroup
-- number directly).
-- Width: 8*127 + 7*6 = 1058 ≤ 1064 (panel content). Height: tool row 92 + 8
-- gap + 5 rows of (110+6)-6 = 574 → 674 total, inside even the tightest
-- content region (678 px at the minimum viewport ratio; same arithmetic as
-- the CharacterPanel grid budget).
local CELL_W, CELL_H = 127, 110
local GAP = 6
local TOOL_H = 92
local GRID_Y = TOOL_H + 8

local panel, notice
local cells = {}        -- i -> secure cell for unit "raid"..i
local unitToCell = {}   -- "raidN" -> cell
local markerButtons = {}
local readyBtn

--------------------------------------------------------------------------------
-- Grid cells
--------------------------------------------------------------------------------

local function UpdateCellVisuals(cell)
	local unit = cell.unit
	if not UnitExists(unit) then return end
	cell.name:SetText(UnitName(unit) or "")
	local r, g, b = WM.UnitColor(unit)
	cell.name:SetTextColor(r, g, b)
	local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
	cell.health:SetMinMaxValues(0, hpMax > 0 and hpMax or 1)
	cell.health:SetValue(hp)
	cell.health:SetStatusBarColor(r, g, b)
	if not UnitIsConnected(unit) then
		cell.status:SetText("Offline")
		cell.status:SetTextColor(0.6, 0.6, 0.65)
		cell.health:SetValue(0)
	elseif UnitIsDeadOrGhost(unit) then
		cell.status:SetText(UnitIsGhost(unit) and "Ghost" or "Dead")
		cell.status:SetTextColor(0.9, 0.35, 0.35)
	elseif hpMax > 0 and hp < hpMax then
		cell.status:SetText(math.floor(hp / hpMax * 100 + 0.5) .. "%")
		cell.status:SetTextColor(0.92, 0.92, 0.92)
	else
		cell.status:SetText("")
	end
end

-- Runs out of combat only (queued init below): secure frame creation.
local function CreateCell(i)
	local unit = "raid" .. i
	local f = CreateFrame("Button", "WowMobileRaidCell" .. i, panel.content,
		"SecureUnitButtonTemplate")
	f:SetSize(WM.Px(CELL_W), WM.Px(CELL_H))
	WM.SkinFrame(f, { 0.07, 0.07, 0.09, 1 })
	local hl = f:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.10)

	f.name = WM.CreateText(f, 20, "OUTLINE")
	f.name:SetPoint("TOPLEFT", WM.Px(6), -WM.Px(6))
	f.name:SetPoint("TOPRIGHT", -WM.Px(6), -WM.Px(6))
	f.name:SetJustifyH("LEFT")
	f.name:SetWordWrap(false)

	f.health = CreateFrame("StatusBar", nil, f)
	f.health:SetStatusBarTexture(WM.TEX_WHITE)
	f.health:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(38))
	f.health:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	local bg = f.health:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.06, 1)

	f.status = WM.CreateText(f, 20, "OUTLINE")
	f.status:SetPoint("CENTER", f.health, "CENTER")

	-- Ready-check badge (classic raid-frame textures, present on era): hidden
	-- outside a running/just-finished ready check; driven by the READY_CHECK*
	-- events below, not by the visual pass, so it survives health repaints.
	f.ready = f:CreateTexture(nil, "OVERLAY")
	f.ready:SetSize(WM.Px(34), WM.Px(34))
	f.ready:SetPoint("TOPRIGHT", -WM.Px(4), -WM.Px(2))
	f.ready:Hide()

	WM.RegisterSecureClicks(f) -- CVar-selected click edge, see Core.lua
	f:SetAttribute("unit", unit)
	f:SetAttribute("type1", "target")     -- tap = target the member
	f:SetAttribute("type2", "togglemenu") -- long-press = boosted unit menu
	RegisterUnitWatch(f) -- combat-safe show/hide with unit existence

	WM.AttachTooltip(f, function(tt) tt:SetUnit(unit) end)

	f.unit = unit
	cells[i] = f
	unitToCell[unit] = f
	return f
end

-- Group-sorted layout: cell for roster index i goes to its subgroup's column,
-- stacked in roster order. Protected-frame anchoring → queued by callers.
local function LayoutGrid()
	local counts = {} -- subgroup -> members placed so far
	for i = 1, MAX_RAID do
		local cell = cells[i]
		if cell then
			local _, _, subgroup = GetRaidRosterInfo(i)
			subgroup = subgroup or 1
			local row = counts[subgroup] or 0
			counts[subgroup] = row + 1
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT",
				WM.Px((subgroup - 1) * (CELL_W + GAP)),
				-WM.Px(GRID_Y + row * (CELL_H + GAP)))
		end
	end
end

-- Insecure visual pass — safe (and run) in combat.
local function RefreshAllVisuals()
	if not panel:IsShown() then return end
	if not cells[1] then
		-- Mid-combat login: the secure build is still queued (Bags.lua's
		-- combat-notice pattern) — say so instead of showing a blank grid.
		notice:SetText("The raid grid will appear when combat ends.")
		notice:Show()
		return
	end
	notice:SetText("You are not in a raid. Party members stay on the party frames at the right edge of the world.")
	notice:SetShown(not IsInRaid())
	for i = 1, MAX_RAID do
		local cell = cells[i]
		if cell and cell:IsShown() then
			UpdateCellVisuals(cell)
		end
	end
end

--------------------------------------------------------------------------------
-- Tool row: ready check + raid markers
--------------------------------------------------------------------------------

local function CanReadyCheck()
	return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function CanMark()
	if IsInRaid() then
		return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
	end
	return IsInGroup() -- party: any member may mark on the 10.x engine
end

local function UpdateToolRow()
	WM.SetButtonEnabled(readyBtn, IsInGroup() and CanReadyCheck())
	local canMark = CanMark()
	for i = 1, #markerButtons do
		local b = markerButtons[i]
		b:SetEnabled(canMark)
		if b.icon then b.icon:SetDesaturated(not canMark) end
		if b.label then
			if canMark then
				b.label:SetTextColor(0.92, 0.92, 0.92)
			else
				local d = WM.Colors.dim
				b.label:SetTextColor(d[1], d[2], d[3])
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Ready-check overlay (replaces the banished ReadyCheckFrame)
--------------------------------------------------------------------------------

local overlay, overlayTitle, overlayTimer
local SetPlayerReadyBadge -- forward: badge section below

local function BuildOverlay()
	overlay = CreateFrame("Frame", "WowMobileReadyCheckOverlay", UIParent)
	-- Deck-only scrim (matching the vanilla port): the world square must stay
	-- tappable during the ~35 s window — a raid often keeps moving/fighting
	-- through a ready check, and a fullscreen mouse blocker would also eat
	-- the camera/joystick region. The dialog itself is anchored to the world
	-- square below and its buttons take their own taps regardless of the
	-- overlay's rect.
	overlay:SetAllPoints(WM.Deck)
	overlay:SetFrameStrata("FULLSCREEN_DIALOG")
	overlay:EnableMouse(true) -- swallow deck taps outside the buttons
	local scrim = overlay:CreateTexture(nil, "BACKGROUND")
	scrim:SetAllPoints()
	scrim:SetColorTexture(0, 0, 0, 0.55)
	overlay:Hide()

	-- Dialog geometry (design px, world-square coordinates): the client
	-- joystick claims FIRST touches in the square's bottom-left — x <= 486,
	-- y >= 0.55 * square height (594 at the default 1080; the boundary RISES
	-- on reduced viewports) — client-side and strata-blind, so no answer
	-- button may ever sit at x <= 486 (ARCHITECTURE §5; the RollFrames.lua
	-- lane rule). The whole dialog therefore lives at x 512..1072, top at
	-- y=90: every tappable px is right of the zone at ANY square height. The
	-- deck scrim dims and blocks the control deck meanwhile — that is the
	-- point of a modal prompt — while the world square stays live.
	local dialog = CreateFrame("Frame", nil, overlay)
	dialog:SetSize(WM.Px(560), WM.Px(520))
	dialog:SetPoint("TOP", WM.WorldSquare, "TOPRIGHT", -WM.Px(288), -WM.Px(90))
	WM.SkinFrame(dialog, WM.Colors.panel)

	overlayTitle = WM.CreateText(dialog, 34)
	overlayTitle:SetPoint("TOP", 0, -WM.Px(28))
	overlayTitle:SetWidth(WM.Px(510))
	overlayTitle:SetJustifyH("CENTER")

	overlayTimer = CreateFrame("StatusBar", nil, dialog)
	overlayTimer:SetStatusBarTexture(WM.TEX_WHITE)
	overlayTimer:SetStatusBarColor(1, 0.82, 0)
	overlayTimer:SetPoint("TOPLEFT", WM.Px(24), -WM.Px(130))
	overlayTimer:SetPoint("TOPRIGHT", -WM.Px(24), -WM.Px(130))
	overlayTimer:SetHeight(WM.Px(20))
	local bg = overlayTimer:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.06, 1)

	-- Stacked 512x160 answers — far past the 90 px touch floor on purpose:
	-- this is a timed prompt that may arrive mid-fumble.
	local ready = WM.CreateTouchButton(dialog, 512, 160, "Ready", 44)
	ready:SetPoint("TOP", 0, -WM.Px(170))
	local g = WM.Colors.green
	ready.borderTex:SetColorTexture(g[1], g[2], g[3], 1)
	ready:SetScript("OnClick", function()
		WM.ConfirmReadyCheck(true)
		SetPlayerReadyBadge(true)
		overlay:Hide()
	end)

	local notReady = WM.CreateTouchButton(dialog, 512, 160, "Not Ready", 44)
	notReady:SetPoint("TOP", ready, "BOTTOM", 0, -WM.Px(16))
	local r = WM.Colors.red
	notReady.borderTex:SetColorTexture(r[1], r[2], r[3], 1)
	notReady:SetScript("OnClick", function()
		WM.ConfirmReadyCheck(false)
		SetPlayerReadyBadge(false)
		overlay:Hide()
	end)

	-- Timeout drain: OnUpdate lives only while the overlay is shown, and the
	-- bar value is the only per-frame work — no allocations.
	overlay:SetScript("OnUpdate", function(self, elapsed)
		self.timeLeft = (self.timeLeft or 0) - elapsed
		if self.timeLeft <= 0 then
			self:Hide() -- server's READY_CHECK_FINISHED normally beats this
			return
		end
		overlayTimer:SetValue(self.timeLeft)
	end)
end

local function ShowReadyCheckOverlay(initiator, timeLeft)
	-- The initiator is auto-ready; only responders get the prompt (the
	-- default ReadyCheckListenerFrame behaves the same way).
	if not initiator or UnitIsUnit("player", initiator) then return end
	-- The banished default UI's audio cue (classic_era ReadyCheck.lua plays
	-- SOUNDKIT.READY_CHECK, id 8960, when the listener frame shows) — keep it
	-- so a timed prompt never arrives silently on a player watching the world.
	PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
	overlayTitle:SetText((UnitName(initiator) or initiator) .. " has started a ready check")
	overlay.timeLeft = timeLeft or 35
	overlayTimer:SetMinMaxValues(0, overlay.timeLeft)
	overlayTimer:SetValue(overlay.timeLeft)
	overlay:Show()
end

--------------------------------------------------------------------------------
-- Per-cell ready-check badges. With ReadyCheckFrame AND the compact raid
-- frames banished (Blizzard.lua) no default frame shows per-member answers,
-- so the grid cells do: waiting on READY_CHECK, flipped by READY_CHECK_CONFIRM
-- (unit token + isReady), unanswered forced to not-ready at
-- READY_CHECK_FINISHED (the default UI's AFK treatment), then cleared after a
-- short linger so the initiator can read the result.
--------------------------------------------------------------------------------

local READY_TEX = {
	waiting  = "Interface\\RaidFrame\\ReadyCheck-Waiting",
	ready    = "Interface\\RaidFrame\\ReadyCheck-Ready",
	notready = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}
local READY_LINGER = 8 -- seconds badges survive READY_CHECK_FINISHED
local readyGen = 0     -- invalidates a stale linger timer

local function SetCellReady(cell, state)
	cell.readyState = state
	if state then
		cell.ready:SetTexture(READY_TEX[state])
		cell.ready:Show()
	else
		cell.ready:Hide()
	end
end

local function ClearReadyBadges()
	for i = 1, MAX_RAID do
		if cells[i] then SetCellReady(cells[i], nil) end
	end
end

local function BeginReadyBadges(initiator)
	readyGen = readyGen + 1
	for i = 1, MAX_RAID do
		local cell = cells[i]
		if cell then
			if not UnitExists(cell.unit) then
				SetCellReady(cell, nil)
			elseif initiator and UnitIsUnit(cell.unit, initiator) then
				SetCellReady(cell, "ready") -- initiator is auto-ready
			else
				SetCellReady(cell, "waiting")
			end
		end
	end
end

-- The local player's own answer does not come back as a READY_CHECK_CONFIRM
-- (the default UI paints its own frame directly on click, same as here).
SetPlayerReadyBadge = function(isReady)
	for i = 1, MAX_RAID do
		local cell = cells[i]
		if cell and cell.readyState and UnitIsUnit(cell.unit, "player") then
			SetCellReady(cell, isReady and "ready" or "notready")
			return
		end
	end
end

local function FinishReadyBadges()
	readyGen = readyGen + 1
	local gen = readyGen
	for i = 1, MAX_RAID do
		local cell = cells[i]
		if cell and cell.readyState == "waiting" then
			SetCellReady(cell, "notready")
		end
	end
	C_Timer.After(READY_LINGER, function()
		if readyGen == gen then ClearReadyBadges() end
	end)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("raid", "Raid")
	BuildOverlay()

	-- Tool row: Ready check (200) + 9 markers (90) with 6px gaps =
	-- 200 + 6 + 9*90 + 8*6 = 1064, the exact content width.
	readyBtn = WM.CreateTouchButton(panel.content, 200, TOOL_H, "Ready check", 26)
	readyBtn:SetPoint("TOPLEFT")
	readyBtn:SetScript("OnClick", function() WM.DoReadyCheck() end)

	local x = 206
	for i = 1, 8 do
		local b = WM.CreateTouchButton(panel.content, 90, TOOL_H, nil, 24)
		b:SetPoint("TOPLEFT", WM.Px(x), 0)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetSize(WM.Px(56), WM.Px(56))
		b.icon:SetPoint("CENTER")
		b.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i)
		b:SetScript("OnClick", function()
			if UnitExists("target") then SetRaidTarget("target", i) end
		end)
		markerButtons[#markerButtons + 1] = b
		x = x + 96
	end
	local clear = WM.CreateTouchButton(panel.content, 90, TOOL_H, "Clear", 22)
	clear:SetPoint("TOPLEFT", WM.Px(x), 0)
	clear:SetScript("OnClick", function()
		if UnitExists("target") then SetRaidTarget("target", 0) end
	end)
	markerButtons[#markerButtons + 1] = clear

	notice = WM.CreateText(panel.content, 30)
	notice:SetPoint("TOP", 0, -WM.Px(GRID_Y + 60))
	notice:SetWidth(WM.Px(900))
	notice:SetJustifyH("CENTER")
	notice:SetText("You are not in a raid. Party members stay on the party frames at the right edge of the world.")
	notice:SetTextColor(0.7, 0.7, 0.75)

	-- All 40 secure cells are created once, up front: creation and the unit
	-- watch are protected-frame work, and building lazily on the first
	-- mid-combat GROUP_ROSTER_UPDATE would leave the healer staring at an
	-- empty panel for a whole fight. 40 idle watched buttons are cheap.
	WM.OutOfCombat("raid-build", function()
		for i = 1, MAX_RAID do
			CreateCell(i)
		end
		LayoutGrid()
		-- A mid-combat login queued this build while RefreshAllVisuals showed
		-- the "grid appears when combat ends" notice; re-run the visual pass
		-- (and the tool row) now so the stale notice clears the moment
		-- RegisterUnitWatch reveals the cells.
		UpdateToolRow()
		RefreshAllVisuals()
	end)

	panel.OnOpen = function()
		UpdateToolRow()
		RefreshAllVisuals()
	end

	WM.On("GROUP_ROSTER_UPDATE", function()
		-- Anchoring protected cells → queued; the visual pass runs now so
		-- health/names are right even while positions wait out combat.
		WM.OutOfCombat("raid-layout", LayoutGrid)
		UpdateToolRow()
		RefreshAllVisuals()
	end)
	WM.TryOn("PARTY_LEADER_CHANGED", UpdateToolRow)

	local function OnUnitEvent(_, unit)
		local cell = unitToCell[unit]
		if cell and panel:IsShown() and cell:IsShown() then
			UpdateCellVisuals(cell)
		end
	end
	WM.On("UNIT_HEALTH", OnUnitEvent)
	WM.TryOn("UNIT_HEALTH_FREQUENT", OnUnitEvent) -- classic-only, smoother ticks
	WM.On("UNIT_MAXHEALTH", OnUnitEvent)
	WM.On("UNIT_NAME_UPDATE", OnUnitEvent)
	WM.On("UNIT_CONNECTION", OnUnitEvent)
	WM.On("PLAYER_ENTERING_WORLD", RefreshAllVisuals)

	-- Ready check events (READY_CHECK carries initiator + timeLeft seconds;
	-- classic_era ReadyCheck.lua's ShowReadyCheck receives the same args).
	WM.On("READY_CHECK", function(_, initiator, timeLeft)
		ShowReadyCheckOverlay(initiator, timeLeft)
		BeginReadyBadges(initiator)
	end)
	WM.On("READY_CHECK_CONFIRM", function(_, unit, isReady)
		local cell = unit and unitToCell[unit]
		if cell then
			SetCellReady(cell, isReady and "ready" or "notready")
		end
	end)
	WM.On("READY_CHECK_FINISHED", function()
		overlay:Hide()
		FinishReadyBadges()
	end)
	WM.TryOn("GROUP_LEFT", function()
		overlay:Hide()
		readyGen = readyGen + 1
		ClearReadyBadges()
	end)
end)
