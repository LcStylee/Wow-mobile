--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · QuestLog
-- Deck-filling quest log with two views inside one scroller:
--   list   — collapsible zone headers (Expand/CollapseQuestHeader) + quest
--            rows colored by difficulty,
--   detail — objectives (GetNumQuestLeaderBoards/GetQuestLogLeaderBoard),
--            description, Track toggle, two-tap Abandon, Back.
-- Also re-homes the Blizzard quest tracker (QuestWatchFrame) into the world
-- square.
--
-- 1.12's GetQuestLogTitle returns 6 values — title, level, questTag,
-- isHeader, isCollapsed, isComplete — and NO questID, so the detail view must
-- re-find its quest after every QUEST_LOG_UPDATE (indices shift). Titles
-- alone are NOT unique inside one log: a 1.12 player can simultaneously hold
-- identically named quests (e.g. "A Donation of Runecloth" from the
-- Stormwind, Ironforge and Darnassus quartermasters), so the re-find keys on
-- the full signature {zone header, title, level}. If even that matches more
-- than one entry — or nothing — the panel falls back to the list view
-- instead of acting (Track/Abandon) on a guess.
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 88
local panel, scroller
local view = "list"       -- "list" | "detail"
local detailSig           -- { header, title, level } of the quest shown in detail
local abandonArmed = false

local rows = { used = 0 } -- pooled row buttons
local texts = { used = 0 } -- pooled detail FontStrings
local cursorY = 0

local function DifficultyColor(level)
	if GetDifficultyColor then return GetDifficultyColor(level) end
	return { r = 1, g = 0.82, b = 0 }
end

-- isComplete on 1.12: 1 = complete, -1 = failed, nil = in progress.
local function StatusTag(isComplete)
	if isComplete == 1 then
		return " |cff33ff33(complete)|r"
	elseif isComplete == -1 then
		return " |cffcc3333(failed)|r"
	end
	return ""
end

-- Re-find a quest by its {header, title, level} signature (see the header
-- comment). Returns the log index only when EXACTLY one visible entry
-- matches; nil on zero or several matches (collapsed headers hide their
-- quests from 1.12's enumeration, which also lands in the safe nil path).
local function FindBySig(sig)
	if not sig then return nil end
	local header = nil
	local found = nil
	local count = 0
	for i = 1, GetNumQuestLogEntries() do
		local title, level, _, isHeader = GetQuestLogTitle(i)
		if isHeader then
			header = title
		elseif title == sig.title and level == sig.level and header == sig.header then
			count = count + 1
			found = i
		end
	end
	if count == 1 then return found end
	return nil
end

--------------------------------------------------------------------------------
-- Pools
--------------------------------------------------------------------------------

local function ResetContent()
	for i = 1, table.getn(rows) do rows[i]:Hide() end
	for i = 1, table.getn(texts) do texts[i]:Hide() end
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
	b:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", 0, -WM.Px(cursorY))
	b:SetPoint("TOPRIGHT", scroller.child, "TOPRIGHT", 0, -WM.Px(cursorY))
	b:SetHeight(WM.Px(ROW_H))
	b.label:SetPoint("LEFT", b, "LEFT", WM.Px(16 + indentPx), 0)
	b.label:SetWidth(scroller.ContentWidth() - WM.Px(40 + indentPx))
	b.label:SetText(label)
	b.label:SetTextColor(0.92, 0.92, 0.92)
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
		texts[texts.used] = fs
	end
	WM.SetFont(fs, sizePx or 28)
	fs:SetTextColor(r or 0.92, g or 0.92, b or 0.92)
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px(6), -WM.Px(cursorY))
	fs:SetWidth(scroller.ContentWidth() - WM.Px(12))
	fs:SetText(text)
	fs:Show()
	-- No GetStringHeight on 1.12; GetHeight() of a width-constrained
	-- FontString returns the wrapped text height.
	cursorY = cursorY + fs:GetHeight() / WM.Px(1) + 10
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
	local currentHeader = nil
	for i = 1, numEntries do
		local title, level, _, isHeader, isCollapsed, isComplete = GetQuestLogTitle(i)
		if isHeader then
			currentHeader = title
			local index = i
			local collapsed = isCollapsed
			AddRow((isCollapsed and "+  " or "-  ") .. (title or "Other"), 0, function()
				-- Header toggle shifts every index below it; the resulting
				-- QUEST_LOG_UPDATE re-renders the list.
				if collapsed then ExpandQuestHeader(index) else CollapseQuestHeader(index) end
			end)
		else
			local sig = { header = currentHeader, title = title, level = level }
			local c = DifficultyColor(level or 1)
			local tag = StatusTag(isComplete)
			local watched = IsQuestWatched(i) and " |cffffcc00[tracked]|r" or ""
			local row = AddRow(string.format("[%d] %s%s%s", level or 0, title or "", tag, watched), 40, function()
				view, detailSig, abandonArmed = "detail", sig, false
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
	local index = FindBySig(detailSig)
	if not index then
		-- Quest vanished (turned in / abandoned elsewhere) or the signature is
		-- ambiguous: back to the list rather than showing a guess.
		view = "list"
		RenderList()
		return
	end

	local title, level, _, _, _, isComplete = GetQuestLogTitle(index)
	SelectQuestLogEntry(index)
	local description, objectivesText = GetQuestLogQuestText()

	AddRow("< Back", 0, function()
		view = "list"
		Render()
	end)

	local c = DifficultyColor(level or 1)
	AddText(string.format("[%d] %s%s", level or 0, title or "",
		StatusTag(isComplete)), 36, c.r, c.g, c.b)

	local numObjectives = GetNumQuestLeaderBoards(index)
	if numObjectives > 0 then
		AddText("Objectives", 32, 1, 0.82, 0)
		for j = 1, numObjectives do
			local text, _, finished = GetQuestLogLeaderBoard(j, index)
			if finished then
				AddText("- " .. (text or ""), 28, 0.3, 0.85, 0.35)
			else
				AddText("- " .. (text or ""), 28, 0.92, 0.92, 0.92)
			end
		end
	elseif objectivesText and objectivesText ~= "" then
		AddText("Objectives", 32, 1, 0.82, 0)
		AddText(objectivesText)
	end

	local watched = IsQuestWatched(index)
	AddRow(watched and "Untrack quest" or "Track quest", 0, function()
		local idx = FindBySig(detailSig)
		if not idx then
			view = "list"
			Render()
			return
		end
		if IsQuestWatched(idx) then
			RemoveQuestWatch(idx)
		else
			AddQuestWatch(idx)
		end
		Render()
	end)

	-- Two-tap abandon: first tap arms, second tap (same visit) commits. Every
	-- tap re-finds by signature so the abandon can never land on a different
	-- quest than the one displayed.
	local abandonRow = AddRow(abandonArmed and "Really abandon? Tap to confirm" or "Abandon quest", 0, function()
		local idx = FindBySig(detailSig)
		if not idx then
			view = "list"
			Render()
			return
		end
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

	-- Blizzard's on-screen quest tracker: keep it, but move it into the world
	-- square's left edge, clear of aura rows, stance column and minimap. 1.12
	-- has no UIParent frame-position manager, so a one-time anchor sticks.
	local tracker = getglobal("QuestWatchFrame")
	if tracker then
		tracker:ClearAllPoints()
		-- x=210 clears the stance column (x<=96, ActionBars.lua) AND the wider
		-- pet action block (x<=190, Pet.lua) for hunter/warlock players;
		-- y=240 clears the aura rows above.
		tracker:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(210), -WM.Px(240))
		if tracker.SetClampedToScreen then
			tracker:SetClampedToScreen(true)
		end
	end
end)
