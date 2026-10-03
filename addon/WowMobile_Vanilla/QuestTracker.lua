--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · QuestTracker
-- One tracked quest, pinned in the world square just below the target's
-- aura rows (field request v0.6.4: "track 1 quest at a time and pin it below
-- the buff placement"). Replaces Blizzard's QuestWatchFrame, which sat at
-- mouse size somewhere the phone never showed.
--
-- The tracked quest is Blizzard's own watch list (Track in the deck quest
-- log, shift-click, auto-watch), held to ONE entry: tracking a quest replaces
-- the previous one, and MAX_WATCHABLE_QUESTS = 1 makes Blizzard's auto-watch
-- (a quest that progresses) only kick in when nothing is tracked, never
-- steal the slot. Tap the tracker to open the quest log.
--
-- Placement (design px in the world square): x 210..680, from y 220 down —
-- right of the stance column / pet block (x <= 190, ActionBars.lua /
-- Pet.lua), below the target debuff row (y 124..208, Auras.lua), left of the
-- party frames (x >= ~690, Blizzard.lua) and far above the phone's joystick
-- band (bottom of the world area).
--------------------------------------------------------------------------------

local WM = WowMobile

local X, Y, W = 210, 220, 470
local PAD, TITLE_H, LINE_H = 10, 34, 30
local MAX_LINES = 6

local frame, title
local lines = {}

local function TrackedIndex()
	if (GetNumQuestWatches() or 0) == 0 then return nil end
	return GetQuestIndexForWatch(1)
end

local function Update()
	if not frame then return end
	local idx = TrackedIndex()
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

	-- One quest at a time: tracking replaces the tracked quest.
	MAX_WATCHABLE_QUESTS = 1
	local origAdd, origRemove = AddQuestWatch, RemoveQuestWatch
	AddQuestWatch = function(index)
		for i = GetNumQuestWatches(), 1, -1 do
			local w = GetQuestIndexForWatch(i)
			if w and w ~= index then origRemove(w) end
		end
		origAdd(index)
		Update()
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

	Update()
end)

WM.On("QUEST_LOG_UPDATE", Update)
WM.On("QUEST_WATCH_UPDATE", Update)
WM.On("UNIT_QUEST_LOG_CHANGED", Update)
WM.On("PLAYER_ENTERING_WORLD", Update)
