--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · QuestTracker
-- One tracked quest, pinned in the world square just below the target's
-- aura rows (field request v0.6.4: "track 1 quest at a time and pin it below
-- the buff placement"). Replaces Blizzard's QuestWatchFrame, which sat at
-- mouse size somewhere the phone never showed.
--
-- The tracked quest is Blizzard's own watch list (Track in the deck quest
-- log, shift-click), held to ONE entry: tracking a quest replaces the
-- previous one. The quest the player picked is PINNED by title: the 1.12
-- client's auto-watch (AutoQuestWatch_Update) adds progressing quests and
-- drops them again on a timer, which untracked the pinned quest the moment
-- an objective progressed (field report v0.6.6). Auto-watch only fills an
-- empty slot now, and a pinned quest that vanished from the watch list is
-- re-added — until the player untracks it (WM.QuestTracker.Untrack, the
-- quest log's button) or it leaves the log (turned in / abandoned). Tap the
-- tracker to open the quest log.
--
-- Placement (design px in the world square): x 210..680, right under the
-- buff row (y 130) — right of the stance column / pet block (x <= 190,
-- ActionBars.lua / Pet.lua), left of the party frames (x >= ~690,
-- Blizzard.lua). The target debuff row shares x 210 at y 124..208
-- (Auras.lua): while the target HAS debuffs the tracker slides below it
-- (y 214).
--------------------------------------------------------------------------------

local WM = WowMobile

local X, Y, Y_BELOW_DEBUFFS, W = 210, 130, 214, 470
local PAD, TITLE_H, LINE_H = 10, 34, 30
local MAX_LINES = 6

local frame, title
local lines = {}
local pinned -- title of the quest the player chose to track
local origAdd, origRemove

local Tracker = {}
WM.QuestTracker = Tracker

local function FindByTitle(t)
	for i = 1, GetNumQuestLogEntries() do
		local name, _, _, isHeader = GetQuestLogTitle(i)
		if name == t and not isHeader then return i end
	end
	return nil
end

-- Explicit untrack (the quest log's button): clears the pin.
function Tracker.Untrack(index)
	pinned = nil
	RemoveQuestWatch(index)
end

local function TrackedIndex()
	if (GetNumQuestWatches() or 0) == 0 then return nil end
	return GetQuestIndexForWatch(1)
end

local function Update()
	if not frame then return end
	local idx = TrackedIndex()
	if not idx and pinned and origAdd then
		-- Something other than the player dropped the pinned quest.
		local again = FindByTitle(pinned)
		if again then
			origAdd(again)
			idx = TrackedIndex()
		else
			pinned = nil -- turned in or abandoned
		end
	end
	local name, level, _, isHeader, _, isComplete
	if idx then
		name, level, _, isHeader, _, isComplete = GetQuestLogTitle(idx)
	end
	if not idx or not name or isHeader then
		frame:Hide()
		return
	end
	title:SetText(string.format("[%d] %s", level or 0, name))

	local shown = 0
	local n = GetNumQuestLeaderBoards(idx) or 0
	for i = 1, n do
		if shown < MAX_LINES then
			local text, _, finished = GetQuestLogLeaderBoard(i, idx)
			shown = shown + 1
			lines[shown]:SetText("- " .. (text or ""))
			if finished then
				lines[shown]:SetTextColor(0.45, 0.95, 0.45)
			else
				lines[shown]:SetTextColor(0.92, 0.92, 0.92)
			end
		end
	end
	if shown == 0 and isComplete == 1 then
		shown = 1
		lines[1]:SetText("- Ready to turn in")
		lines[1]:SetTextColor(0.45, 0.95, 0.45)
	end
	for i = 1, MAX_LINES do
		WM.SetShown(lines[i], i <= shown)
	end
	frame:SetHeight(WM.Px(PAD * 2 + TITLE_H + shown * LINE_H))
	frame:Show()
end

WM.OnInit(function()
	-- Blizzard's tracker: replaced by this one.
	if QuestWatchFrame then WM.BanishFrame(QuestWatchFrame, true) end

	frame = CreateFrame("Button", "WowMobileQuestTracker", WM.WorldSquare)
	frame:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(X), -WM.Px(Y))
	frame:SetWidth(WM.Px(W))
	frame:SetHeight(WM.Px(PAD * 2 + TITLE_H))
	WM.SkinFrame(frame, { 0.04, 0.04, 0.06, 0.55 }, { 0.83, 0.63, 0.09, 0.6 })
	frame:SetScript("OnClick", function()
		if WM.Deck and WM.Deck.Open then WM.Deck.Open("questlog") end
	end)

	title = WM.CreateText(frame, 26, "OUTLINE")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", WM.Px(PAD), -WM.Px(PAD))
	title:SetWidth(WM.Px(W - 2 * PAD))
	title:SetJustifyH("LEFT")
	title:SetTextColor(1, 0.82, 0)
	WM.SingleLine(title, 26)

	for i = 1, MAX_LINES do
		local l = WM.CreateText(frame, 22, "OUTLINE")
		l:SetPoint("TOPLEFT", frame, "TOPLEFT", WM.Px(PAD),
			-WM.Px(PAD + TITLE_H + (i - 1) * LINE_H))
		l:SetWidth(WM.Px(W - 2 * PAD))
		l:SetJustifyH("LEFT")
		WM.SingleLine(l, 22)
		lines[i] = l
	end
	frame:Hide()

	-- One quest at a time: tracking replaces the tracked quest (and pins it).
	origAdd, origRemove = AddQuestWatch, RemoveQuestWatch
	AddQuestWatch = function(index)
		for i = GetNumQuestWatches(), 1, -1 do
			local w = GetQuestIndexForWatch(i)
			if w and w ~= index then origRemove(w) end
		end
		if not IsQuestWatched(index) then origAdd(index) end
		pinned = GetQuestLogTitle(index)
		Update()
	end
	-- 1.12 auto-watch: only ever fills an EMPTY slot, never through the
	-- timed list that later removes its entries again.
	if AutoQuestWatch_Update then
		AutoQuestWatch_Update = function(index)
			if GetNumQuestWatches() == 0 and index then
				origAdd(index)
				pinned = GetQuestLogTitle(index)
				Update()
			end
		end
	end
	if type(QUEST_WATCH_LIST) == "table" then
		for k in pairs(QUEST_WATCH_LIST) do QUEST_WATCH_LIST[k] = nil end
	end
	RemoveQuestWatch = function(index)
		origRemove(index)
		Update()
	end
	-- Saved watches from before (Blizzard allowed five): keep the first.
	for i = GetNumQuestWatches(), 2, -1 do
		local w = GetQuestIndexForWatch(i)
		if w then origRemove(w) end
	end

	-- Pin whatever is tracked at login.
	local first = TrackedIndex()
	if first then pinned = GetQuestLogTitle(first) end

	Update()

	-- Slide below the target's debuff row while it is in use.
	local below = nil
	WM.Ticker(0.25, function()
		local want = UnitExists("target") and UnitDebuff("target", 1) and true or false
		if want == below then return end
		below = want
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", WM.WorldSquare, "TOPLEFT", WM.Px(X),
			-WM.Px(want and Y_BELOW_DEBUFFS or Y))
	end)
end)

WM.On("QUEST_LOG_UPDATE", Update)
WM.On("QUEST_WATCH_UPDATE", Update)
WM.On("UNIT_QUEST_LOG_CHANGED", Update)
WM.On("PLAYER_ENTERING_WORLD", Update)
