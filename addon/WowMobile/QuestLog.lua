--------------------------------------------------------------------------------
-- WowMobile · QuestLog
-- Deck-filling quest log with two views inside one scroller:
--   list   — collapsible zone headers (Expand/CollapseQuestHeader) + quest
--            rows colored by difficulty,
--   detail — objectives (GetNumQuestLeaderBoards/GetQuestLogLeaderBoard),
--            description, Track toggle, two-tap Abandon, Back.
-- Quest indices shift on every QUEST_LOG_UPDATE, so the detail view re-finds
-- its quest by questID and falls back to the list when it disappears.
-- Also re-homes the Blizzard quest tracker into the world square.
--------------------------------------------------------------------------------

local _, WM = ...

local ROW_H = 88
local panel, scroller
local view = "list"       -- "list" | "detail"
local detailQuestID       -- questID shown in detail view
local abandonArmed = false

local rows = { used = 0 } -- pooled row buttons
local texts = { used = 0 } -- pooled detail FontStrings
local cursorY = 0

-- GetQuestLogTitle's 3rd return differs across builds (questTag vs
-- suggestedGroup); positions 1,2,4,5,6 and the trailing questID are stable.
-- isComplete is NOT a boolean on Classic Era: 1 = complete, -1 = failed,
-- nil = in progress — render helpers must branch on the value.
local function QuestEntry(index)
	local title, level, _, isHeader, isCollapsed, isComplete, _, questID = GetQuestLogTitle(index)
	return title, level, isHeader, isCollapsed, isComplete, questID
end

-- Colored status suffix for the 1/-1/nil isComplete value above.
local function StatusTag(isComplete)
	if isComplete == 1 then
		return " |cff33ff33(complete)|r"
	elseif isComplete == -1 then
		return " |cffcc3333(failed)|r"
	end
	return ""
end

local function FindByQuestID(questID)
	for i = 1, GetNumQuestLogEntries() do
		local _, _, isHeader, _, _, id = QuestEntry(i)
		if not isHeader and id == questID then return i end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Pools
--------------------------------------------------------------------------------

local function ResetContent()
	for i = 1, #rows do rows[i]:Hide() end
	for i = 1, #texts do texts[i]:Hide() end
	rows.used, texts.used = 0, 0
	cursorY = 0
end

local function AddRow(label, indentPx, onTap)
	rows.used = rows.used + 1
	local b = rows[rows.used]
	if not b then
		b = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 30)
		b.label:ClearAllPoints()
		b.label:SetJustifyH("LEFT")
		rows[rows.used] = b
	end
	b:ClearAllPoints()
	b:SetPoint("TOPLEFT", 0, -WM.Px(cursorY))
	b:SetPoint("TOPRIGHT", 0, -WM.Px(cursorY))
	b:SetHeight(WM.Px(ROW_H))
	b.label:SetPoint("LEFT", WM.Px(16 + indentPx), 0)
	b.label:SetWidth(scroller.ContentWidth() - WM.Px(40 + indentPx))
	b.label:SetText(label)
	WM.SetButtonEnabled(b, true)
	b:SetScript("OnClick", onTap)
	b:Show()
	cursorY = cursorY + ROW_H + 6
	return b
end

local function AddText(text, sizePx, r, g, b)
	texts.used = texts.used + 1
	local fs = texts[texts.used]
	if not fs then
		fs = WM.CreateText(scroller.child, 28)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(true)
		fs:SetSpacing(WM.Px(6))
		texts[texts.used] = fs
	end
	WM.SetFont(fs, sizePx or 28)
	fs:SetTextColor(r or 0.92, g or 0.92, b or 0.92)
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", WM.Px(6), -WM.Px(cursorY))
	fs:SetWidth(scroller.ContentWidth() - WM.Px(12))
	fs:SetText(text)
	fs:Show()
	cursorY = cursorY + fs:GetStringHeight() / WM.Px(1) + 10
end

local function FinishLayout()
	scroller.SetContentHeight(WM.Px(cursorY + 8))
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local Render -- forward: view dispatcher

local function RenderList()
	ResetContent()
	local numEntries = GetNumQuestLogEntries()
	for i = 1, numEntries do
		local title, level, isHeader, isCollapsed, isComplete, questID = QuestEntry(i)
		if isHeader then
			local index = i
			AddRow((isCollapsed and "+  " or "-  ") .. (title or OTHER), 0, function()
				-- Header toggle shifts every index below it; the resulting
				-- QUEST_LOG_UPDATE re-renders the list.
				if isCollapsed then ExpandQuestHeader(index) else CollapseQuestHeader(index) end
			end)
		else
			local id = questID
			local c = GetQuestDifficultyColor(level or 1)
			local tag = StatusTag(isComplete)
			local watched = IsQuestWatched(i) and " |cffffcc00[tracked]|r" or ""
			local row = AddRow(string.format("[%d] %s%s%s", level or 0, title or "", tag, watched), 40, function()
				view, detailQuestID, abandonArmed = "detail", id, false
				Render()
			end)
			row.label:SetTextColor(c.r, c.g, c.b)
		end
	end
	if numEntries == 0 then
		AddText("No quests in the log.", 30, 0.7, 0.7, 0.75)
	end
	FinishLayout()
end

local function RenderDetail()
	ResetContent()
	local index = FindByQuestID(detailQuestID)
	if not index then
		-- Quest vanished (turned in / abandoned elsewhere): back to the list.
		view = "list"
		RenderList()
		return
	end

	local title, level, _, _, isComplete = QuestEntry(index)
	SelectQuestLogEntry(index)
	local description, objectivesText = GetQuestLogQuestText()

	AddRow("< Back", 0, function()
		view = "list"
		Render()
	end)

	local c = GetQuestDifficultyColor(level or 1)
	AddText(string.format("[%d] %s%s", level or 0, title or "",
		StatusTag(isComplete)), 36, c.r, c.g, c.b)

	local numObjectives = GetNumQuestLeaderBoards(index)
	if numObjectives > 0 then
		AddText("Objectives", 32, 1, 0.82, 0)
		for j = 1, numObjectives do
			local text, _, finished = GetQuestLogLeaderBoard(j, index)
			if finished then
				AddText("· " .. (text or ""), 28, 0.3, 0.85, 0.35)
			else
				AddText("· " .. (text or ""), 28, 0.92, 0.92, 0.92)
			end
		end
	elseif objectivesText and objectivesText ~= "" then
		AddText("Objectives", 32, 1, 0.82, 0)
		AddText(objectivesText)
	end

	local watched = IsQuestWatched(index)
	AddRow(watched and "Untrack quest" or "Track quest", 0, function()
		local idx = FindByQuestID(detailQuestID)
		if not idx then return end
		if IsQuestWatched(idx) then
			RemoveQuestWatch(idx)
		else
			AddQuestWatch(idx)
		end
		Render()
	end)

	-- Two-tap abandon: first tap arms, second tap (same visit) commits.
	local abandonRow = AddRow(abandonArmed and "Really abandon? Tap to confirm" or "Abandon quest", 0, function()
		local idx = FindByQuestID(detailQuestID)
		if not idx then return end
		if not abandonArmed then
			abandonArmed = true
			Render()
			return
		end
		SelectQuestLogEntry(idx)
		SetAbandonQuest()
		AbandonQuest()
		view, abandonArmed = "list", false
		-- QUEST_LOG_UPDATE re-renders the list once the abandon lands.
	end)
	abandonRow.label:SetTextColor(0.9, 0.35, 0.35)

	if description and description ~= "" then
		AddText("Description", 32, 1, 0.82, 0)
		AddText(description)
	end
	FinishLayout()
end

Render = function()
	if not panel:IsShown() then return end
	if view == "detail" then
		RenderDetail()
	else
		RenderList()
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("questlog", "Quest Log")
	scroller = WM.Deck.CreateScroller(panel.content)

	panel.OnOpen = function()
		view, abandonArmed = "list", false
		Render()
		scroller.ScrollToTop()
	end

	WM.On("QUEST_LOG_UPDATE", Render)
	WM.TryOn("QUEST_WATCH_LIST_CHANGED", Render) -- not present on every build

	-- Blizzard's on-screen quest tracker: keep it, but move it into the world
	-- square's left edge, clear of aura rows, stance column and minimap.
	local tracker = _G["QuestWatchFrame"]
	if tracker then
		-- QuestWatchFrame is UIParent-managed: any UIParent_ManageFramePositions
		-- pass (buff/durability/pet changes) would snap it back to its default
		-- top-right slot. Drop it from the managed table AND set the ignore
		-- flag the manager honors, so this anchor sticks for the session.
		tracker.ignoreFramePositionManager = true
		if type(UIPARENT_MANAGED_FRAME_POSITIONS) == "table" then
			UIPARENT_MANAGED_FRAME_POSITIONS["QuestWatchFrame"] = nil
		end
		tracker:ClearAllPoints()
		-- x=210 clears the stance column (x<=96, ActionBars.lua) AND the wider
		-- pet action block (x<=190, Pet.lua) for hunter/warlock players;
		-- y=240 clears the aura rows above. The tracker text is not
		-- mouse-enabled, but it still gets its own lane for readability.
		tracker:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(210), -WM.Px(240))
		tracker:SetClampedToScreen(true)
	end
end)
