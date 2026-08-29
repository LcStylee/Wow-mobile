--------------------------------------------------------------------------------
-- WowMobile · CharacterPanel
-- Deck-filling character sheet with four tabs in the TITLE BAR (the content
-- region's height budget is exactly consumed by the gear grid, so the tab row
-- borrows the title bar's spare width instead of content height):
--   Gear   — equipped item grid (tap/hover = tooltip, per-slot durability
--            bars) + core stats; long-press unequips onto the cursor and
--            carried equippables drop here (MoveMode.lua).
--   Rep    — collapsible faction headers (Expand/CollapseFactionHeader),
--            standing name + FACTION_BAR_COLORS progress bar per faction;
--            tap a faction to watch/unwatch it — only wired when the
--            platform has a watched-faction setter (WM.SetWatchedFaction,
--            Compat: SetWatchedFactionIndex on era 1.15).
--   Skills — skill lines with rank/max bars under collapsible headers
--            (Expand/CollapseSkillHeader, SKILL_LINES_CHANGED re-renders).
--   Honor  — era honor system: current rank (UnitPVPRank + GetPVPRankInfo),
--            rank progress bar (GetPVPRankProgress), and session / yesterday
--            / this week / last week / lifetime kill stats — exactly the
--            functions the classic_era HonorFrame_Shared.lua drives the
--            default honor tab with; every row is guarded so a build lacking
--            one API omits that row instead of erroring.
--------------------------------------------------------------------------------

local _, WM = ...

-- Paper-doll order, laid out as a 4x5 grid. Labels are our own short names.
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
-- Height budget: 19 slots in 4 columns = 5 rows → 5*(CELL+GAP)-GAP = 672 px.
-- The panel content region is deckHeight - 104 (title bar) - 8 (bottom
-- margin): 728 px at the default 1.0 viewport ratio and 678 px at the
-- tightest ratio Config allows (deck never drops below DECK_FIXED_PX = 790),
-- so the fifth row (Main Hand / Off Hand / Ranged) always fits on screen.
-- (The tab row lives in the 104 px title bar, so this budget is unchanged.)
local CELL = 128
local GAP = 8

local panel
local tabButtons = {}   -- key -> title-bar tab button
local tabFrames = {}    -- key -> content sub-frame
local activeTab = "gear"
local slotCells = {}
local statRows = {}
local durabilityText

--------------------------------------------------------------------------------
-- Stats (Gear tab)
-- Each row: label + value closure. Guarded so builds lacking an API simply
-- omit that row instead of erroring.
--------------------------------------------------------------------------------

local STAT_DEFS = {
	{ "Strength",  function() local _, v = UnitStat("player", 1) return v end },
	{ "Agility",   function() local _, v = UnitStat("player", 2) return v end },
	{ "Stamina",   function() local _, v = UnitStat("player", 3) return v end },
	{ "Intellect", function() local _, v = UnitStat("player", 4) return v end },
	{ "Spirit",    function() local _, v = UnitStat("player", 5) return v end },
	{ "Armor",     function() local _, eff = UnitArmor("player") return eff end },
	{ "Attack Power", function()
		local base, pos, neg = UnitAttackPower("player")
		return base + pos + neg
	end },
	{ "Melee Crit", function()
		if not GetCritChance then return nil end
		return string.format("%.1f%%", GetCritChance())
	end },
	{ "Ranged Crit", function()
		if not GetRangedCritChance then return nil end
		return string.format("%.1f%%", GetRangedCritChance())
	end },
	{ "Defense", function()
		if not UnitDefense then return nil end
		local base, mod = UnitDefense("player")
		return base + mod
	end },
}

local function UpdateStats()
	for i = 1, #STAT_DEFS do
		local row = statRows[i]
		local ok, value = pcall(STAT_DEFS[i][2])
		if ok and value ~= nil then
			row.value:SetText(value)
			row:Show()
		else
			row:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Equipment (Gear tab)
--------------------------------------------------------------------------------

local function UpdateSlots()
	local totalCur, totalMax = 0, 0
	for i = 1, #SLOTS do
		local cell = slotCells[i]
		local texture = GetInventoryItemTexture("player", cell.slotID)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetDesaturated(false)
		else
			cell.icon:SetTexture(cell.emptyTexture or WM.TEX_QUESTION)
			cell.icon:SetDesaturated(true)
		end
		local cur, max = GetInventoryItemDurability(cell.slotID)
		if cur and max and max > 0 then
			totalCur, totalMax = totalCur + cur, totalMax + max
			cell.dura:Show()
			cell.dura:SetMinMaxValues(0, max)
			cell.dura:SetValue(cur)
			local frac = cur / max
			if frac < 0.2 then
				cell.dura:SetStatusBarColor(0.9, 0.2, 0.2)
			elseif frac < 0.5 then
				cell.dura:SetStatusBarColor(0.95, 0.8, 0.25)
			else
				cell.dura:SetStatusBarColor(0.3, 0.8, 0.35)
			end
		else
			cell.dura:Hide()
		end
	end
	if totalMax > 0 then
		durabilityText:SetText(string.format("Durability  %d%%", totalCur / totalMax * 100))
	else
		durabilityText:SetText("")
	end
end

local function RefreshGear()
	if not panel:IsShown() or activeTab ~= "gear" then return end
	UpdateSlots()
	UpdateStats()
end

--------------------------------------------------------------------------------
-- Pooled bar-row list (Rep + Skills tabs)
-- Rows: full-width touch button with a left label, right value text and a
-- thin progress bar along the bottom. Event-driven rebuilds over the pool.
--------------------------------------------------------------------------------

-- 92 px: rows are tappable actions (watch-toggle, header collapse), so they
-- honor the >=90 px touch floor (ARCHITECTURE §4), matching the Raid tool
-- row; the lists live in scrollers, so the height costs nothing.
local ROW_H = 92

local function NewBarList(scroller)
	local list = { rows = {}, used = 0, y = 0 }

	function list.Reset()
		for i = 1, #list.rows do list.rows[i]:Hide() end
		list.used, list.y = 0, 0
	end

	-- indentPx label/value strings; barFrac 0..1 (nil hides the bar); barColor
	-- {r,g,b}; onTap; accent = accent border (watched faction).
	function list.Row(opts)
		list.used = list.used + 1
		local b = list.rows[list.used]
		if not b then
			b = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 28)
			b.label:ClearAllPoints()
			b.label:SetJustifyH("LEFT")
			b.value = WM.CreateText(b, 24)
			b.value:SetPoint("RIGHT", -WM.Px(16), WM.Px(6))
			b.bar = CreateFrame("StatusBar", nil, b)
			b.bar:SetStatusBarTexture(WM.TEX_WHITE)
			b.bar:SetPoint("BOTTOMLEFT", WM.Px(4), WM.Px(4))
			b.bar:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
			b.bar:SetHeight(WM.Px(10))
			b.bar:SetMinMaxValues(0, 1)
			local bg = b.bar:CreateTexture(nil, "BACKGROUND")
			bg:SetAllPoints()
			bg:SetColorTexture(0.05, 0.05, 0.06, 1)
			list.rows[list.used] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 0, -WM.Px(list.y))
		b:SetPoint("TOPRIGHT", 0, -WM.Px(list.y))
		b:SetHeight(WM.Px(ROW_H))
		local indent = opts.indentPx or 0
		b.label:SetPoint("LEFT", WM.Px(16 + indent), WM.Px(6))
		b.label:SetWidth(scroller.ContentWidth() - WM.Px(260 + indent))
		b.label:SetText(opts.label or "")
		b.value:SetText(opts.value or "")
		if opts.barFrac then
			b.bar:Show()
			b.bar:SetValue(opts.barFrac)
			local c = opts.barColor
			if c then b.bar:SetStatusBarColor(c.r or c[1], c.g or c[2], c.b or c[3]) end
		else
			b.bar:Hide()
		end
		local border = opts.accent and WM.Colors.accent or WM.Colors.border
		b.borderTex:SetColorTexture(border[1], border[2], border[3], 1)
		-- Tapless rows (skill lines, factions on a build without a watch
		-- setter) keep full-brightness text — they are data, not disabled
		-- actions; a nil OnClick simply makes the tap a no-op.
		b:SetScript("OnClick", opts.onTap)
		WM.SetButtonEnabled(b, true)
		b:Show()
		list.y = list.y + ROW_H + 6
		return b
	end

	function list.Finish()
		scroller.SetContentHeight(WM.Px(list.y + 8))
	end

	return list
end

--------------------------------------------------------------------------------
-- Rep tab
--------------------------------------------------------------------------------

local repList, repScroller

local function RenderRep()
	if not panel:IsShown() or activeTab ~= "rep" then return end
	repList.Reset()
	local num = GetNumFactions()
	for i = 1, num do
		-- classic_era ReputationFrame.lua return shape.
		local name, _, standingID, barMin, barMax, barValue, _, _,
			isHeader, isCollapsed, hasRep, isWatched, isChild = GetFactionInfo(i)
		if name then
			local index = i
			local standing = _G["FACTION_STANDING_LABEL" .. (standingID or 4)] or ""
			local color = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standingID or 4]
			local span = (barMax or 0) - (barMin or 0)
			local frac = span > 0 and ((barValue or 0) - (barMin or 0)) / span or 0
			if isHeader and not hasRep then
				repList.Row({
					label = (isCollapsed and "+  " or "-  ") .. name,
					onTap = function()
						-- Toggle shifts every index below; UPDATE_FACTION
						-- re-renders the list.
						if isCollapsed then ExpandFactionHeader(index) else CollapseFactionHeader(index) end
					end,
				})
			else
				-- Headers WITH rep (e.g. faction super-headers) keep their
				-- collapse toggle; plain factions toggle the watched faction
				-- where the platform supports it (WM.SetWatchedFaction).
				local onTap
				if isHeader then
					onTap = function()
						if isCollapsed then ExpandFactionHeader(index) else CollapseFactionHeader(index) end
					end
				elseif WM.SetWatchedFaction then
					onTap = function()
						WM.SetWatchedFaction(isWatched and 0 or index)
						RenderRep() -- isWatched flips without an UPDATE_FACTION on some builds
					end
				end
				local prefix = isHeader and ((isCollapsed and "+  " or "-  ")) or ""
				repList.Row({
					label = prefix .. name .. (isWatched and "  |cffffcc00[watched]|r" or ""),
					value = string.format("%s  %d / %d", standing,
						(barValue or 0) - (barMin or 0), span),
					indentPx = (isChild and not isHeader) and 40 or (isHeader and 0 or 20),
					barFrac = frac,
					barColor = color or { 0.5, 0.5, 0.55 },
					accent = isWatched,
					onTap = onTap,
				})
			end
		end
	end
	if num == 0 then
		repList.Row({ label = "No known factions." })
	end
	repList.Finish()
end

--------------------------------------------------------------------------------
-- Skills tab
--------------------------------------------------------------------------------

local skillList

local function RenderSkills()
	if not panel:IsShown() or activeTab ~= "skills" then return end
	skillList.Reset()
	for i = 1, GetNumSkillLines() do
		-- classic_era SkillFrame.lua return shape.
		local name, isHeader, isExpanded, rank, tempPoints, modifier, maxRank =
			GetSkillLineInfo(i)
		if name then
			local index = i
			if isHeader then
				skillList.Row({
					label = (isExpanded and "-  " or "+  ") .. name,
					onTap = function()
						-- SKILL_LINES_CHANGED re-renders after the toggle.
						if isExpanded then CollapseSkillHeader(index) else ExpandSkillHeader(index) end
					end,
				})
			else
				local value
				if (maxRank or 0) > 0 then
					value = string.format("%d / %d%s", rank or 0, maxRank,
						(modifier and modifier ~= 0) and string.format("  (%+d)", modifier) or "")
				else
					value = tostring(rank or 0)
				end
				skillList.Row({
					label = name .. ((tempPoints and tempPoints > 0) and "  |cff33ff33+|r" or ""),
					value = value,
					indentPx = 30,
					barFrac = (maxRank or 0) > 0 and (rank or 0) / maxRank or 1,
					barColor = (maxRank or 0) > 0 and { 0.30, 0.80, 0.35 } or { 0.35, 0.35, 0.40 },
				})
			end
		end
	end
	skillList.Finish()
end

--------------------------------------------------------------------------------
-- Honor tab
-- Static rows filled on render; every stat call is feature-guarded. Source
-- for the era API set: classic_era HonorFrame_Shared.lua (see file header).
--------------------------------------------------------------------------------

local honorRows = {}   -- created once at init
local honorBar

local function RenderHonor()
	if not panel:IsShown() or activeTab ~= "honor" then return end
	local function SetRow(i, label, value)
		local row = honorRows[i]
		row.labelText:SetText(label or "")
		row.value:SetText(value or "")
		row:SetShown(label ~= nil)
	end

	local i = 0
	local function Add(label, value)
		i = i + 1
		if honorRows[i] then SetRow(i, label, value) end
	end

	if UnitPVPRank and GetPVPRankInfo then
		local rankName, rankNumber = GetPVPRankInfo(UnitPVPRank("player"))
		if rankName then
			Add("Rank", string.format("%s (rank %d)", rankName, rankNumber or 0))
		else
			Add("Rank", "None yet")
		end
	end
	if GetPVPRankProgress then
		local progress = GetPVPRankProgress() or 0
		Add("Rank progress", string.format("%d%%", progress * 100))
		honorBar:SetValue(progress)
		honorBar:Show()
	else
		honorBar:Hide()
	end
	if GetPVPSessionStats then
		local hk, dk = GetPVPSessionStats()
		Add("Today", string.format("%d HK / %d DK", hk or 0, dk or 0))
	end
	if GetPVPYesterdayStats then
		local hk, dk, contribution = GetPVPYesterdayStats()
		Add("Yesterday", string.format("%d HK / %d DK — %d honor", hk or 0, dk or 0, contribution or 0))
	end
	if GetPVPThisWeekStats then
		local hk, contribution = GetPVPThisWeekStats()
		Add("This week", string.format("%d HK — %d honor", hk or 0, contribution or 0))
	end
	if GetPVPLastWeekStats then
		local hk, dk, contribution, standing = GetPVPLastWeekStats()
		Add("Last week", string.format("%d HK / %d DK — %d honor, standing %d",
			hk or 0, dk or 0, contribution or 0, standing or 0))
	end
	if GetPVPLifetimeStats then
		local hk, dk, highestRank = GetPVPLifetimeStats()
		Add("Lifetime", string.format("%d HK / %d DK", hk or 0, dk or 0))
		if GetPVPRankInfo and highestRank and highestRank > 0 then
			local rankName = GetPVPRankInfo(highestRank)
			Add("Highest rank", rankName or tostring(highestRank))
		end
	end
	if i == 0 then
		Add("Honor", "Not available on this client build")
	end
	for j = i + 1, #honorRows do
		honorRows[j]:Hide()
	end
end

--------------------------------------------------------------------------------
-- Tabs
--------------------------------------------------------------------------------

local RENDERERS -- key -> function, filled at init

local function SelectTab(key)
	activeTab = key
	for k, f in pairs(tabFrames) do
		f:SetShown(k == key)
	end
	for k, b in pairs(tabButtons) do
		local c = (k == key) and WM.Colors.accent or WM.Colors.border
		b.borderTex:SetColorTexture(c[1], c[2], c[3], 1)
	end
	local render = RENDERERS[key]
	if render then render() end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("character", "Character")

	-- Title-bar tab row: 4 x 148 + 3 gaps (6) = 610 px spanning x 340..950 —
	-- right of the title text, left of the close button (x >= 976). Height
	-- 96 matches the close button (>=90 px touch targets).
	local TABS = { { "gear", "Gear" }, { "rep", "Rep" }, { "skills", "Skills" }, { "honor", "Honor" } }
	for i = 1, #TABS do
		local key, label = TABS[i][1], TABS[i][2]
		local b = WM.CreateTouchButton(panel, 148, 96, label, 26)
		b:SetPoint("TOPLEFT", WM.Px(340 + (i - 1) * 154), -WM.Px(4))
		b:SetScript("OnClick", function() SelectTab(key) end)
		tabButtons[key] = b
	end
	for i = 1, #TABS do
		local f = CreateFrame("Frame", nil, panel.content)
		f:SetAllPoints()
		f:Hide()
		tabFrames[TABS[i][1]] = f
	end
	local gearFrame = tabFrames.gear

	-- == Gear tab: equipment grid, left side. ==
	for i = 1, #SLOTS do
		local slotName, label = SLOTS[i][1], SLOTS[i][2]
		local cell = CreateFrame("Button", nil, gearFrame)
		cell:SetSize(WM.Px(CELL), WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		cell:SetPoint("TOPLEFT", WM.Px(col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))

		local slotID, emptyTexture = GetInventorySlotInfo(slotName)
		cell.slotID, cell.emptyTexture = slotID, emptyTexture

		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetSize(WM.Px(72), WM.Px(72))
		cell.icon:SetPoint("TOP", 0, -WM.Px(8))

		local name = WM.CreateText(cell, 20)
		name:SetPoint("BOTTOM", 0, WM.Px(8))
		name:SetText(label)
		name:SetTextColor(0.7, 0.7, 0.75)

		cell.dura = CreateFrame("StatusBar", nil, cell)
		cell.dura:SetStatusBarTexture(WM.TEX_WHITE)
		cell.dura:SetSize(WM.Px(72), WM.Px(8))
		cell.dura:SetPoint("TOP", cell.icon, "BOTTOM", 0, -WM.Px(2))
		local bg = cell.dura:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.06, 1)

		WM.AttachTooltip(cell, function(tt, self)
			-- Classic Era 1.15 runs the 10.0.2 tooltip-data engine, where
			-- GameTooltip:SetInventoryItem no longer returns hasItem — decide
			-- emptiness from the data API, never from the setter's return.
			if GetInventoryItemLink("player", self.slotID) then
				tt:SetInventoryItem("player", self.slotID)
			else
				tt:SetText(label)
			end
		end)

		-- MoveMode (MoveMode.lua): long-press (right-click) unequips the slot
		-- onto the cursor; while carrying an equippable item the cell
		-- highlights and a tap equips/swaps it here (a tap with anything else
		-- held cancels the carry). Insecure buttons only register LeftButtonUp
		-- by default, so the right edge must be added for the long-press.
		cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cell:SetScript("OnClick", function(self, mouseButton)
			if WM.MoveMode.IsActive() then
				WM.MoveMode.DropOnInventory(self.slotID)
			elseif mouseButton == "RightButton" then
				WM.MoveMode.Begin({ kind = "inv", slotID = self.slotID })
			end
		end)
		WM.MoveMode.RegisterTarget(cell, WM.MoveMode.AcceptsEquippable)
		slotCells[i] = cell
	end

	-- Gear tab: stat column, right side.
	local statX = COLS * (CELL + GAP) + 24
	for i = 1, #STAT_DEFS do
		local row = CreateFrame("Frame", nil, gearFrame)
		row:SetSize(WM.Px(1064 - statX - 16), WM.Px(52))
		row:SetPoint("TOPLEFT", WM.Px(statX), -WM.Px((i - 1) * 56))
		local label = WM.CreateText(row, 28)
		label:SetPoint("LEFT")
		label:SetText(STAT_DEFS[i][1])
		label:SetTextColor(0.75, 0.75, 0.8)
		row.value = WM.CreateText(row, 28)
		row.value:SetPoint("RIGHT")
		statRows[i] = row
	end

	durabilityText = WM.CreateText(gearFrame, 28)
	durabilityText:SetPoint("TOPLEFT", WM.Px(statX), -WM.Px(#STAT_DEFS * 56 + 16))

	-- == Rep + Skills tabs: scroller-backed bar lists. ==
	repScroller = WM.Deck.CreateScroller(tabFrames.rep)
	repList = NewBarList(repScroller)
	local skillScroller = WM.Deck.CreateScroller(tabFrames.skills)
	skillList = NewBarList(skillScroller)

	-- == Honor tab: fixed rows + rank progress bar. ==
	local honorFrame = tabFrames.honor
	for i = 1, 8 do
		local row = CreateFrame("Frame", nil, honorFrame)
		row:SetSize(WM.Px(1000), WM.Px(64))
		row:SetPoint("TOPLEFT", WM.Px(16), -WM.Px((i - 1) * 70 + 60))
		row.labelText = WM.CreateText(row, 30)
		row.labelText:SetPoint("LEFT")
		row.labelText:SetTextColor(0.75, 0.75, 0.8)
		row.value = WM.CreateText(row, 30)
		row.value:SetPoint("RIGHT")
		row:Hide()
		honorRows[i] = row
	end
	honorBar = CreateFrame("StatusBar", nil, honorFrame)
	honorBar:SetStatusBarTexture(WM.TEX_WHITE)
	honorBar:SetStatusBarColor(1, 0.82, 0)
	honorBar:SetPoint("TOPLEFT", WM.Px(16), -WM.Px(20))
	honorBar:SetPoint("TOPRIGHT", -WM.Px(16), -WM.Px(20))
	honorBar:SetHeight(WM.Px(24))
	honorBar:SetMinMaxValues(0, 1)
	local hbg = honorBar:CreateTexture(nil, "BACKGROUND")
	hbg:SetAllPoints()
	hbg:SetColorTexture(0.05, 0.05, 0.06, 1)

	RENDERERS = {
		gear = RefreshGear,
		rep = RenderRep,
		skills = RenderSkills,
		honor = RenderHonor,
	}

	panel.OnOpen = function()
		SelectTab(activeTab)
	end

	-- Gear events.
	WM.On("UNIT_INVENTORY_CHANGED", function(_, unit)
		if unit == "player" then RefreshGear() end
	end)
	WM.On("UNIT_STATS", function(_, unit)
		if unit == "player" then RefreshGear() end
	end)
	WM.On("UPDATE_INVENTORY_DURABILITY", RefreshGear)
	WM.TryOn("UNIT_ATTACK_POWER", function(_, unit)
		if unit == "player" then RefreshGear() end
	end)

	-- Rep / Skills / Honor events (renderers no-op unless their tab shows).
	WM.On("UPDATE_FACTION", RenderRep)
	WM.On("SKILL_LINES_CHANGED", RenderSkills)
	WM.TryOn("PLAYER_PVP_KILLS_CHANGED", RenderHonor)
	WM.TryOn("PLAYER_PVP_RANK_CHANGED", RenderHonor)
end)
