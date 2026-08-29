--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · CharacterPanel
-- Deck-filling character sheet with four touch tabs:
--   Gear       — equipped item grid (tap/hover = tooltip, per-slot durability
--                bars, long-press = MoveMode pickup) + core stats column,
--   Reputation — collapsible faction headers + standing-colored progress bars.
--                The watched-faction machinery IS genuine 1.12 (isWatched is
--                GetFactionInfo's 11th return, SetWatchedFactionIndex exists —
--                sources in the rep-tab block comment); tap a faction row to
--                watch/unwatch it, feeding the deck's own watch bar
--                (XPBar.lua's rep bar) — same gesture as the Era port,
--   Skills    — collapsible skill headers + rank/max bars,
--   Honor     — 1.12 rank system (UnitPVPRank + GetPVPRankInfo) with rank
--                progress and session/yesterday/week/lifetime stats.
-- Every tab's data accessor is pcall-guarded so a build lacking an API simply
-- omits that row instead of erroring (the STAT_DEFS pattern).
--------------------------------------------------------------------------------

local WM = WowMobile

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
-- Height budget: the tab row eats 100 px (92 + 8 gap) of the >=678 px content
-- region, leaving >=578 px for the views. 19 slots in 4 columns = 5 rows at
-- CELL+GAP pitch -> 5*(108+8)-8 = 572 <= 578, so the fifth row (Main Hand /
-- Off Hand / Ranged) always fits on screen at the tightest Config ratio.
-- 108 px cells still clear the 90 px touch floor.
local CELL = 108
local GAP = 8
local TAB_H = 92

local panel
local views = {}       -- key -> view frame
local tabButtons = {}
local activeTab = "gear"

local slotCells = {}
local statRows = {}
local durabilityText

--------------------------------------------------------------------------------
-- Gear tab: stats
-- Each row: label + value closure. pcall-guarded so a build lacking an API
-- simply omits that row instead of erroring. 1.12: UnitStat's 2nd return is
-- the effective stat; UnitArmor's 2nd return the effective armor; there is no
-- GetCritChance/GetRangedCritChance (those rows self-omit here — melee/ranged
-- crit is only visible in tooltips on this client).
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
	for i = 1, table.getn(STAT_DEFS) do
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
-- Gear tab: equipment
--------------------------------------------------------------------------------

local function UpdateSlots()
	local totalCur, totalMax = 0, 0
	for i = 1, table.getn(SLOTS) do
		local cell = slotCells[i]
		local texture = GetInventoryItemTexture("player", cell.slotID)
		if texture then
			cell.icon:SetTexture(texture)
			cell.icon:SetVertexColor(1, 1, 1)
		else
			cell.icon:SetTexture(cell.emptyTexture or WM.TEX_QUESTION)
			cell.icon:SetVertexColor(0.45, 0.45, 0.45)
		end
		local cur, max
		if GetInventoryItemDurability then
			cur, max = GetInventoryItemDurability(cell.slotID)
		end
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

--------------------------------------------------------------------------------
-- Reputation tab
-- 1.12 GetFactionInfo(i): name, description, standingID, barMin, barMax,
-- barValue, atWarWith, canToggleAtWar, isHeader, isCollapsed, isWatched —
-- ELEVEN returns, verified against genuine 1.12 FrameXML (Interface 11200):
-- ReputationFrame.lua line 51 reads "..., isHeader, isCollapsed, isWatched =
-- GetFactionInfo(factionIndex)", ReputationFrame.xml line 842 calls
-- SetWatchedFactionIndex(GetSelectedFaction()) (and 0 to clear), and
-- ReputationFrame.lua ships ReputationWatchBar_Update/GetWatchedFactionInfo
-- for the stock watch bar. So the whole watched-faction machinery IS vanilla
-- 1.12, not a later addition: the accent color and "watched" tag below do
-- appear on the real client, and tapping a faction row toggles the watch via
-- SetWatchedFactionIndex(i) (0 clears) — Era-parity gesture. The bar it
-- feeds is the deck's own: XPBar.lua's rep bar stands in for the stock
-- ReputationWatchBar, which is parented to MainMenuBar
-- (ReputationFrame.xml:869) and banished with it (Blizzard.lua). The toggle
-- repaints directly (re-render + WM.RefreshWatchedRep) because 1.12 promises
-- no UPDATE_FACTION for a pure watch flip. Headers toggle via
-- Expand/CollapseFactionHeader(i) — the toggle shifts every index below it,
-- and the resulting UPDATE_FACTION re-renders the list. Standing names come
-- from the FACTION_STANDING_LABEL<id> globals, bar colors from
-- FACTION_BAR_COLORS — both genuine 1.12 FrameXML. Lists are flat (child
-- factions are a later addition), so no indenting.
--------------------------------------------------------------------------------

local repScroller
local repHeaders = {}  -- pooled header toggle buttons
local repRows = {}     -- pooled faction bar rows
local REP_HEADER_H = 90
local REP_ROW_H = 84

local function AcquireRepHeader(n)
	local b = repHeaders[n]
	if b then return b end
	b = WM.CreateTouchButton(repScroller.child, 100, REP_HEADER_H, nil, 30)
	b.label:ClearAllPoints()
	b.label:SetPoint("LEFT", b, "LEFT", WM.Px(16), 0)
	b.label:SetJustifyH("LEFT")
	repHeaders[n] = b
	return b
end

local function AcquireRepRow(n)
	local row = repRows[n]
	if row then return row end
	row = CreateFrame("Frame", nil, repScroller.child)
	row:SetHeight(WM.Px(REP_ROW_H))
	row:EnableMouse(true) -- tap = watch toggle (script set per render)
	WM.SkinFrame(row, { 0.07, 0.07, 0.09, 1 })
	row.name = WM.CreateText(row, 28)
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(16), -WM.Px(10))
	row.name:SetJustifyH("LEFT")
	row.name:SetWidth(WM.Px(520))
	WM.SingleLine(row.name, 28)
	row.standing = WM.CreateText(row, 26)
	row.standing:SetPoint("TOPRIGHT", row, "TOPRIGHT", -WM.Px(16), -WM.Px(12))
	row.standing:SetJustifyH("RIGHT")
	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetStatusBarTexture(WM.TEX_WHITE)
	row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(16), WM.Px(10))
	row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -WM.Px(16), WM.Px(10))
	row.bar:SetHeight(WM.Px(16))
	local bg = row.bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(row.bar)
	bg:SetTexture(0.05, 0.05, 0.06, 1)
	repRows[n] = row
	return row
end

local function RenderReputation()
	local usedHeaders, usedRows = 0, 0
	local y = 0
	local numFactions = GetNumFactions and GetNumFactions() or 0
	for i = 1, numFactions do
		local name, _, standingID, barMin, barMax, barValue, _, _,
			isHeader, isCollapsed, isWatched = GetFactionInfo(i)
		if isHeader then
			usedHeaders = usedHeaders + 1
			local b = AcquireRepHeader(usedHeaders)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", repScroller.child, "TOPLEFT", 0, -WM.Px(y))
			b:SetPoint("TOPRIGHT", repScroller.child, "TOPRIGHT", 0, -WM.Px(y))
			b.label:SetText((isCollapsed and "+  " or "-  ") .. (name or ""))
			local index = i
			local collapsed = isCollapsed
			b:SetScript("OnClick", function()
				if collapsed then
					ExpandFactionHeader(index)
				else
					CollapseFactionHeader(index)
				end
			end)
			b:Show()
			y = y + REP_HEADER_H + 6
		else
			usedRows = usedRows + 1
			local row = AcquireRepRow(usedRows)
			row:ClearAllPoints()
			-- 1.12 faction lists are flat (no child factions), so no indent.
			row:SetPoint("TOPLEFT", repScroller.child, "TOPLEFT", 0, -WM.Px(y))
			row:SetPoint("TOPRIGHT", repScroller.child, "TOPRIGHT", 0, -WM.Px(y))
			row.name:SetText(name or "")
			-- Tap toggles the watched faction (block comment above): watch
			-- this row, or un-watch it if it already is. Long-press (right
			-- click) is left alone per the addon-wide convention.
			if SetWatchedFactionIndex then
				local index = i
				local watched = isWatched
				row:SetScript("OnMouseUp", function()
					if arg1 == "LeftButton" then
						SetWatchedFactionIndex(watched and 0 or index)
						RenderReputation() -- isWatched flips silently on 1.12
						if WM.RefreshWatchedRep then WM.RefreshWatchedRep() end
					end
				end)
			else
				row:SetScript("OnMouseUp", nil)
			end
			-- Mark the watched faction — isWatched is a genuine 1.12 return
			-- (11th; ReputationFrame.lua:51, see the block comment), so the
			-- marker appears on the real client too.
			-- Pooled rows — set the color BOTH ways.
			if isWatched then
				row.name:SetTextColor(1, 0.82, 0)
			else
				row.name:SetTextColor(0.92, 0.92, 0.92)
			end
			local standingText = getglobal("FACTION_STANDING_LABEL" .. (standingID or 4))
			if isWatched then
				standingText = (standingText or "") .. "  ·  watched"
			end
			row.standing:SetText(standingText or "")
			local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standingID]
			if c then
				row.bar:SetStatusBarColor(c.r, c.g, c.b)
				row.standing:SetTextColor(c.r, c.g, c.b)
			else
				row.bar:SetStatusBarColor(0.3, 0.5, 0.85)
				row.standing:SetTextColor(0.75, 0.75, 0.8)
			end
			local span = (barMax or 0) - (barMin or 0)
			row.bar:SetMinMaxValues(0, span > 0 and span or 1)
			row.bar:SetValue(span > 0 and ((barValue or 0) - (barMin or 0)) or 1)
			row:Show()
			y = y + REP_ROW_H + 6
		end
	end
	if numFactions == 0 then
		usedRows = usedRows + 1
		local row = AcquireRepRow(usedRows)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", repScroller.child, "TOPLEFT", 0, 0)
		row:SetPoint("TOPRIGHT", repScroller.child, "TOPRIGHT", 0, 0)
		row.name:SetText("No known factions.")
		row:SetScript("OnMouseUp", nil) -- pooled: no stale watch toggle
		row.name:SetTextColor(0.92, 0.92, 0.92)
		row.standing:SetText("")
		row.bar:SetMinMaxValues(0, 1)
		row.bar:SetValue(0)
		row:Show()
		y = y + REP_ROW_H + 6
	end
	for i = usedHeaders + 1, table.getn(repHeaders) do repHeaders[i]:Hide() end
	for i = usedRows + 1, table.getn(repRows) do repRows[i]:Hide() end
	repScroller.SetContentHeight(WM.Px(y + 8))
end

--------------------------------------------------------------------------------
-- Skills tab
-- 1.12 GetSkillLineInfo(i) (vanilla FrameXML SkillFrame.lua shape): name,
-- isHeader, isExpanded, rank, numTempPoints, modifier, maxRank, isAbandonable,
-- stepCost, rankCost, minLevel, costType, description. Headers toggle via
-- Expand/CollapseSkillHeader(i); SKILL_LINES_CHANGED re-renders.
--------------------------------------------------------------------------------

local skillScroller
local skillHeaders = {}
local skillRows = {}

local function AcquireSkillHeader(n)
	local b = skillHeaders[n]
	if b then return b end
	b = WM.CreateTouchButton(skillScroller.child, 100, REP_HEADER_H, nil, 30)
	b.label:ClearAllPoints()
	b.label:SetPoint("LEFT", b, "LEFT", WM.Px(16), 0)
	b.label:SetJustifyH("LEFT")
	skillHeaders[n] = b
	return b
end

local function AcquireSkillRow(n)
	local row = skillRows[n]
	if row then return row end
	row = CreateFrame("Frame", nil, skillScroller.child)
	row:SetHeight(WM.Px(REP_ROW_H))
	WM.SkinFrame(row, { 0.07, 0.07, 0.09, 1 })
	row.name = WM.CreateText(row, 28)
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(16), -WM.Px(10))
	row.name:SetJustifyH("LEFT")
	row.name:SetWidth(WM.Px(520))
	WM.SingleLine(row.name, 28)
	row.rankText = WM.CreateText(row, 26)
	row.rankText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -WM.Px(16), -WM.Px(12))
	row.rankText:SetJustifyH("RIGHT")
	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetStatusBarTexture(WM.TEX_WHITE)
	row.bar:SetStatusBarColor(0.35, 0.6, 0.9)
	row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(16), WM.Px(10))
	row.bar:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -WM.Px(16), WM.Px(10))
	row.bar:SetHeight(WM.Px(16))
	local bg = row.bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(row.bar)
	bg:SetTexture(0.05, 0.05, 0.06, 1)
	skillRows[n] = row
	return row
end

local function RenderSkills()
	local usedHeaders, usedRows = 0, 0
	local y = 0
	local numLines = GetNumSkillLines and GetNumSkillLines() or 0
	for i = 1, numLines do
		local name, isHeader, isExpanded, rank, _, modifier, maxRank =
			GetSkillLineInfo(i)
		if isHeader then
			usedHeaders = usedHeaders + 1
			local b = AcquireSkillHeader(usedHeaders)
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", skillScroller.child, "TOPLEFT", 0, -WM.Px(y))
			b:SetPoint("TOPRIGHT", skillScroller.child, "TOPRIGHT", 0, -WM.Px(y))
			b.label:SetText((isExpanded and "-  " or "+  ") .. (name or ""))
			local index = i
			local expanded = isExpanded
			b:SetScript("OnClick", function()
				if expanded then
					CollapseSkillHeader(index)
				else
					ExpandSkillHeader(index)
				end
			end)
			b:Show()
			y = y + REP_HEADER_H + 6
		else
			usedRows = usedRows + 1
			local row = AcquireSkillRow(usedRows)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", skillScroller.child, "TOPLEFT", 0, -WM.Px(y))
			row:SetPoint("TOPRIGHT", skillScroller.child, "TOPRIGHT", 0, -WM.Px(y))
			row.name:SetText(name or "")
			local text = (rank or 0) .. " / " .. (maxRank or 0)
			if modifier and modifier > 0 then
				text = (rank or 0) .. " |cff33ff33+" .. modifier .. "|r / " .. (maxRank or 0)
			end
			row.rankText:SetText(text)
			if maxRank and maxRank > 0 then
				row.bar:Show()
				row.bar:SetMinMaxValues(0, maxRank)
				row.bar:SetValue(rank or 0)
			else
				-- Class/weapon proficiencies without a rank scale (maxRank 0):
				-- no bar, just the name.
				row.bar:Hide()
			end
			row:Show()
			y = y + REP_ROW_H + 6
		end
	end
	for i = usedHeaders + 1, table.getn(skillHeaders) do skillHeaders[i]:Hide() end
	for i = usedRows + 1, table.getn(skillRows) do skillRows[i]:Hide() end
	skillScroller.SetContentHeight(WM.Px(y + 8))
end

--------------------------------------------------------------------------------
-- Honor tab
-- 1.12 rank system. Accessors (vanilla FrameXML HonorFrame.lua /
-- PaperDollFrame.lua shapes):
--   UnitPVPRank("player")            -> rank value (0 = unranked; ranked
--                                       values are offset, fed straight into
--                                       GetPVPRankInfo like the default UI)
--   GetPVPRankInfo(rankValue)        -> rankName, rankNumber
--   GetPVPRankProgress()             -> 0..1 toward the next rank
--   GetPVPSessionStats()             -> honorableKills, dishonorableKills
--   GetPVPYesterdayStats()           -> hk, dk, contribution (honor)
--   GetPVPThisWeekStats()            -> hk, contribution
--   GetPVPLastWeekStats()            -> hk, dk, contribution, standing
--                                       (1.12 HonorFrame.lua reads exactly
--                                       `hk, dk, contribution, rank` — the
--                                       standing is the FOURTH return)
--   GetPVPLifetimeStats()            -> hk, dk, highestRankValue
-- Every row is pcall-guarded and self-omits if this build lacks the call.
--------------------------------------------------------------------------------

local honorRows = {}
local honorBar

local HONOR_DEFS = {
	{ "Rank", function()
		local rank = UnitPVPRank("player")
		if not rank or rank == 0 then return "Unranked" end
		local rankName, rankNumber = GetPVPRankInfo(rank)
		if rankName and rankNumber then
			return rankName .. "  (rank " .. rankNumber .. ")"
		end
		return rankName or ("Rank value " .. rank)
	end },
	{ "Today HK / DK", function()
		local hk, dk = GetPVPSessionStats()
		return (hk or 0) .. " / " .. (dk or 0)
	end },
	{ "Yesterday HK · honor", function()
		local hk, _, contribution = GetPVPYesterdayStats()
		return (hk or 0) .. " · " .. (contribution or 0)
	end },
	{ "This week HK · honor", function()
		local hk, contribution = GetPVPThisWeekStats()
		return (hk or 0) .. " · " .. (contribution or 0)
	end },
	{ "Last week HK · standing", function()
		-- Standing is the 4th return on 1.12 (hk, dk, contribution, standing).
		local hk, _, _, standing = GetPVPLastWeekStats()
		return (hk or 0) .. " · " .. (standing or 0)
	end },
	{ "Lifetime HK / DK", function()
		local hk, dk = GetPVPLifetimeStats()
		return (hk or 0) .. " / " .. (dk or 0)
	end },
	{ "Highest rank", function()
		local _, _, highest = GetPVPLifetimeStats()
		if not highest or highest == 0 then return "None" end
		local rankName = GetPVPRankInfo(highest)
		return rankName or tostring(highest)
	end },
}

local function UpdateHonor()
	for i = 1, table.getn(HONOR_DEFS) do
		local row = honorRows[i]
		local ok, value = pcall(HONOR_DEFS[i][2])
		if ok and value ~= nil then
			row.value:SetText(value)
			row:Show()
		else
			row:Hide()
		end
	end
	local ok, progress = pcall(function()
		if not GetPVPRankProgress then return nil end
		return GetPVPRankProgress()
	end)
	if ok and progress ~= nil then
		honorBar:Show()
		honorBar:SetMinMaxValues(0, 1)
		honorBar:SetValue(progress)
		honorBar.text:SetText(string.format("Rank progress  %d%%", progress * 100))
	else
		honorBar:Hide()
	end
end

--------------------------------------------------------------------------------
-- Tab switching / refresh routing
--------------------------------------------------------------------------------

local function Refresh()
	if not panel:IsShown() then return end
	if activeTab == "gear" then
		UpdateSlots()
		UpdateStats()
	elseif activeTab == "rep" then
		RenderReputation()
	elseif activeTab == "skills" then
		RenderSkills()
	else
		UpdateHonor()
	end
end

local function SelectTab(key)
	activeTab = key
	for i = 1, table.getn(tabButtons) do
		local b = tabButtons[i]
		WM.TintBorder(b, (b.tabKey == key) and WM.Colors.accent or WM.Colors.border)
	end
	for k, v in pairs(views) do
		WM.SetShown(v, k == key)
	end
	Refresh()
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local TAB_DEFS = {
	{ key = "gear",   label = "Gear" },
	{ key = "rep",    label = "Reputation" },
	{ key = "skills", label = "Skills" },
	{ key = "honor",  label = "Honor" },
}

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("character", "Character")

	-- Tab row: 4 x 250 px + 3 x 8 gap = 1024 <= 1064 content width.
	for i = 1, table.getn(TAB_DEFS) do
		local def = TAB_DEFS[i]
		local b = WM.CreateTouchButton(panel.content, 250, TAB_H, def.label, 28)
		b:SetPoint("TOPLEFT", panel.content, "TOPLEFT", WM.Px((i - 1) * 258), 0)
		b.tabKey = def.key
		b:SetScript("OnClick", function()
			SelectTab(this.tabKey)
		end)
		tabButtons[i] = b
	end

	-- One deck-filling view frame per tab, below the tab row.
	for i = 1, table.getn(TAB_DEFS) do
		local v = CreateFrame("Frame", nil, panel.content)
		v:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(TAB_H + 8))
		v:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, 0)
		v:Hide()
		views[TAB_DEFS[i].key] = v
	end

	-- ---- Gear view -------------------------------------------------------
	local gear = views.gear
	for i = 1, table.getn(SLOTS) do
		local slotName, label = SLOTS[i][1], SLOTS[i][2]
		local cell = CreateFrame("Button", nil, gear)
		cell:SetWidth(WM.Px(CELL))
		cell:SetHeight(WM.Px(CELL))
		WM.SkinFrame(cell, { 0.07, 0.07, 0.09, 1 })
		local col = math.mod(i - 1, COLS)
		local row = math.floor((i - 1) / COLS)
		cell:SetPoint("TOPLEFT", gear, "TOPLEFT",
			WM.Px(col * (CELL + GAP)), -WM.Px(row * (CELL + GAP)))

		local slotID, emptyTexture = GetInventorySlotInfo(slotName)
		cell.slotID, cell.emptyTexture = slotID, emptyTexture

		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetWidth(WM.Px(60))
		cell.icon:SetHeight(WM.Px(60))
		cell.icon:SetPoint("TOP", cell, "TOP", 0, -WM.Px(6))

		local name = WM.CreateText(cell, 18)
		name:SetPoint("BOTTOM", cell, "BOTTOM", 0, WM.Px(6))
		name:SetText(label)
		name:SetTextColor(0.7, 0.7, 0.75)

		cell.dura = CreateFrame("StatusBar", nil, cell)
		cell.dura:SetStatusBarTexture(WM.TEX_WHITE)
		cell.dura:SetWidth(WM.Px(60))
		cell.dura:SetHeight(WM.Px(8))
		cell.dura:SetPoint("TOP", cell.icon, "BOTTOM", 0, -WM.Px(2))
		local bg = cell.dura:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(cell.dura)
		bg:SetTexture(0.05, 0.05, 0.06, 1)

		-- Plain tap keeps its old meaning (tooltip via the injected hover);
		-- long-press (client right click) = MoveMode pickup of the equipped
		-- item; while a carry is active a tap drops here (equip / swap).
		cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		cell:SetScript("OnClick", function()
			-- CursorForeign: an un-adopted Blizzard-loaded cursor (bank
			-- withdraw) drops/equips here too; DropOnInventory adopts it.
			if WM.MoveMode.IsActive() or WM.MoveMode.CursorForeign() then
				WM.MoveMode.DropOnInventory(this.slotID)
			elseif arg1 == "RightButton" then
				WM.MoveMode.BeginFromInventory(this.slotID)
			end
		end)
		WM.MoveMode.MakeTarget(cell, "inv")

		cell.slotLabel = label
		WM.AttachTooltip(cell, function(tt, self)
			-- Decide emptiness from the data API, not the tooltip setter.
			if GetInventoryItemLink("player", self.slotID) then
				tt:SetInventoryItem("player", self.slotID)
			else
				tt:SetText(self.slotLabel)
			end
		end)
		slotCells[i] = cell
	end

	-- Stat column, right side of the gear view.
	local statX = COLS * (CELL + GAP) + 24
	for i = 1, table.getn(STAT_DEFS) do
		local row = CreateFrame("Frame", nil, gear)
		row:SetWidth(WM.Px(1064 - statX - 16))
		row:SetHeight(WM.Px(48))
		row:SetPoint("TOPLEFT", gear, "TOPLEFT", WM.Px(statX), -WM.Px((i - 1) * 52))
		local label = WM.CreateText(row, 28)
		label:SetPoint("LEFT", row, "LEFT", 0, 0)
		label:SetText(STAT_DEFS[i][1])
		label:SetTextColor(0.75, 0.75, 0.8)
		row.value = WM.CreateText(row, 28)
		row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		statRows[i] = row
	end

	durabilityText = WM.CreateText(gear, 28)
	durabilityText:SetPoint("TOPLEFT", gear, "TOPLEFT",
		WM.Px(statX), -WM.Px(table.getn(STAT_DEFS) * 52 + 12))

	-- ---- Reputation / Skills views (scrolling lists) ---------------------
	repScroller = WM.Deck.CreateScroller(views.rep)
	skillScroller = WM.Deck.CreateScroller(views.skills)

	-- ---- Honor view ------------------------------------------------------
	local honor = views.honor
	for i = 1, table.getn(HONOR_DEFS) do
		local row = CreateFrame("Frame", nil, honor)
		row:SetPoint("TOPLEFT", honor, "TOPLEFT", 0, -WM.Px((i - 1) * 60))
		row:SetPoint("TOPRIGHT", honor, "TOPRIGHT", 0, -WM.Px((i - 1) * 60))
		row:SetHeight(WM.Px(54))
		local label = WM.CreateText(row, 30)
		label:SetPoint("LEFT", row, "LEFT", WM.Px(8), 0)
		label:SetText(HONOR_DEFS[i][1])
		label:SetTextColor(0.75, 0.75, 0.8)
		row.value = WM.CreateText(row, 30)
		row.value:SetPoint("RIGHT", row, "RIGHT", -WM.Px(8), 0)
		honorRows[i] = row
	end
	honorBar = CreateFrame("StatusBar", nil, honor)
	honorBar:SetStatusBarTexture(WM.TEX_WHITE)
	honorBar:SetStatusBarColor(1, 0.82, 0)
	honorBar:SetPoint("TOPLEFT", honor, "TOPLEFT", WM.Px(8),
		-WM.Px(table.getn(HONOR_DEFS) * 60 + 16))
	honorBar:SetWidth(WM.Px(940))
	honorBar:SetHeight(WM.Px(28))
	local hbg = honorBar:CreateTexture(nil, "BACKGROUND")
	hbg:SetAllPoints(honorBar)
	hbg:SetTexture(0.05, 0.05, 0.06, 1)
	honorBar.text = WM.CreateText(honorBar, 22, "OUTLINE")
	honorBar.text:SetPoint("CENTER", honorBar, "CENTER", 0, 0)

	-- ---- Lifecycle / events ---------------------------------------------
	panel.OnOpen = function()
		SelectTab(activeTab)
	end

	WM.On("UNIT_INVENTORY_CHANGED", function(_, unit)
		if unit == "player" and activeTab == "gear" then Refresh() end
	end)
	WM.On("UNIT_STATS", function(_, unit)
		if unit == "player" and activeTab == "gear" then Refresh() end
	end)
	-- 1.12's durability signal is UPDATE_INVENTORY_ALERTS; the _DURABILITY
	-- event is a later addition — TryOn covers both spellings.
	WM.TryOn("UPDATE_INVENTORY_ALERTS", function()
		if activeTab == "gear" then Refresh() end
	end)
	WM.TryOn("UPDATE_INVENTORY_DURABILITY", function()
		if activeTab == "gear" then Refresh() end
	end)
	WM.TryOn("UNIT_ATTACK_POWER", function(_, unit)
		if unit == "player" and activeTab == "gear" then Refresh() end
	end)

	WM.On("UPDATE_FACTION", function()
		if activeTab == "rep" then Refresh() end
	end)
	WM.On("SKILL_LINES_CHANGED", function()
		if activeTab == "skills" then Refresh() end
	end)
	-- Honor signals; both are 1.11+ additions, TryOn in case a build lacks one.
	WM.TryOn("PLAYER_PVP_KILLS_CHANGED", function()
		if activeTab == "honor" then Refresh() end
	end)
	WM.TryOn("PLAYER_PVP_RANK_CHANGED", function()
		if activeTab == "honor" then Refresh() end
	end)
end)
