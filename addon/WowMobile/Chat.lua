--------------------------------------------------------------------------------
-- WowMobile · Chat
-- Read-focused chat for a phone screen:
--   * compact ScrollingMessageFrame strip at the top of the deck; tap it to
--     open a deck-filling reader panel with paging buttons,
--   * both views are fed from CHAT_MSG_* events directly (the default chat
--     windows are banished),
--   * ChatFrame1's edit box is rescued BEFORE its parent is banished,
--     restyled large, and re-anchored over the chat strip — typing arrives
--     via the streaming client's keyboard (edge-rail Enter opens it).
--------------------------------------------------------------------------------

local _, WM = ...

-- event -> short channel tag ("" = no tag). CHAT_MSG_CHANNEL derives its tag
-- from the channel number at runtime.
local EVENTS = {
	CHAT_MSG_SAY = "",              CHAT_MSG_YELL = "Yell",
	CHAT_MSG_WHISPER = "From",      CHAT_MSG_WHISPER_INFORM = "To",
	CHAT_MSG_PARTY = "P",           CHAT_MSG_PARTY_LEADER = "P",
	CHAT_MSG_RAID = "R",            CHAT_MSG_RAID_LEADER = "R",
	CHAT_MSG_RAID_WARNING = "RW",
	CHAT_MSG_GUILD = "G",           CHAT_MSG_OFFICER = "O",
	CHAT_MSG_EMOTE = "",            CHAT_MSG_TEXT_EMOTE = "",
	CHAT_MSG_MONSTER_SAY = "",      CHAT_MSG_MONSTER_YELL = "",
	CHAT_MSG_MONSTER_EMOTE = "",    CHAT_MSG_MONSTER_WHISPER = "",
	CHAT_MSG_CHANNEL = false,       -- tag derived from the channel number at runtime
	CHAT_MSG_SYSTEM = "",           CHAT_MSG_LOOT = "",
	CHAT_MSG_MONEY = "",            CHAT_MSG_SKILL = "",
}

local compact, reader

local function Deliver(line, r, g, b)
	compact:AddMessage(line, r, g, b)
	if reader then
		reader:AddMessage(line, r, g, b)
	end
end

local function OnChat(event, msg, sender, _, _, _, _, _, channelIndex)
	local chatType = string.sub(event, 10) -- strip "CHAT_MSG_"
	local tag = EVENTS[event]
	if event == "CHAT_MSG_CHANNEL" then
		tag = tostring(channelIndex or "?")
		chatType = "CHANNEL" .. (channelIndex or 0)
	end
	local info = ChatTypeInfo[chatType] or ChatTypeInfo["SAY"]

	local name = sender and sender ~= "" and sender or nil
	if name and Ambiguate then
		name = Ambiguate(name, "short")
	end

	-- The emote family never uses the generic "name: msg" shape:
	local line
	if event == "CHAT_MSG_TEXT_EMOTE" then
		-- arg1 is the complete pre-baked line ("Bob waves at you.") — the
		-- sender is already embedded, so a name prefix would double it.
		line = msg
	elseif event == "CHAT_MSG_MONSTER_EMOTE" then
		-- arg1 is a format pattern with a literal %s for the mob's name; the
		-- default UI renders it as format(arg1, arg2) (ChatFrame.lua's
		-- MONSTER_EMOTE handling), so do the same.
		line = string.format(msg, sender or "")
	elseif event == "CHAT_MSG_EMOTE" then
		-- Player /emotes read as prose: "Bob flexes." — no colon separator.
		line = (name and (name .. " ") or "") .. msg
	elseif name then
		line = (tag ~= "" and ("[" .. tag .. "] ") or "") .. name .. ": " .. msg
	else
		line = msg
	end
	Deliver(line, info.r, info.g, info.b)
end

--------------------------------------------------------------------------------
-- Edit box rescue + default chat banishment
--------------------------------------------------------------------------------

local function SetupEditBox()
	local eb = ChatFrame1EditBox
	eb:SetParent(UIParent)
	eb:SetFrameStrata("DIALOG")
	eb:ClearAllPoints()
	eb:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", WM.Px(8), -WM.Px(4))
	eb:SetPoint("TOPRIGHT", WM.Deck, "TOPRIGHT", -WM.Px(8), -WM.Px(4))
	eb:SetHeight(WM.Px(70))
	eb:SetFont(STANDARD_TEXT_FONT, WM.Px(32), "")
	eb:SetAltArrowKeyMode(false)
	-- Strip the parchment art; give it the deck's flat look instead.
	for _, suffix in next, { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" } do
		local tex = _G["ChatFrame1EditBox" .. suffix]
		if tex then tex:SetAlpha(0) end
	end
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.08, 0.08, 0.10, 0.95)
	local header = _G["ChatFrame1EditBoxHeader"]
	if header then
		header:SetFont(STANDARD_TEXT_FONT, WM.Px(32), "")
	end
end

local function BanishDefaultChat()
	for i = 1, NUM_CHAT_WINDOWS do
		-- keepEvents: chat frames keep processing so Blizzard-side chat state
		-- (history, sticky channels, the edit box) stays coherent while the
		-- windows themselves are invisible.
		WM.BanishFrame(_G["ChatFrame" .. i], true)
		WM.BanishFrame(_G["ChatFrame" .. i .. "Tab"], true)
	end
	WM.BanishFrame(_G["ChatFrameMenuButton"])
	WM.BanishFrame(_G["ChatFrameChannelButton"])
	WM.BanishFrame(_G["QuickJoinToastButton"]) -- nil-safe: retail-lineage frame
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Rescue the edit box FIRST: banishing ChatFrame1 would drag it into the
	-- hidden parent otherwise.
	SetupEditBox()
	BanishDefaultChat()

	-- Compact strip: deck top edge down to the unit row.
	local strip = CreateFrame("Frame", "WowMobileChatStrip", WM.Deck)
	strip:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(6))
	strip:SetPoint("TOPRIGHT", -WM.Px(8), -WM.Px(6))
	strip:SetPoint("BOTTOMLEFT", WM.Layout.unitRow, "TOPLEFT", 0, WM.Px(6))
	WM.SkinFrame(strip, { 0.03, 0.03, 0.04, 0.6 }, { 0.18, 0.18, 0.22, 0.6 })
	WM.Layout.chat = strip

	compact = CreateFrame("ScrollingMessageFrame", nil, strip)
	compact:SetPoint("TOPLEFT", WM.Px(10), -WM.Px(4))
	compact:SetPoint("BOTTOMRIGHT", -WM.Px(10), WM.Px(4))
	compact:SetFont(STANDARD_TEXT_FONT, WM.Px(24), "")
	compact:SetJustifyH("LEFT")
	compact:SetFading(false)
	compact:SetMaxLines(64)
	compact:EnableMouse(true)
	compact:SetScript("OnMouseUp", function()
		WM.Deck.Open("chat")
	end)

	-- Reader panel.
	local panel = WM.Deck.CreatePanel("chat", "Chat")
	reader = CreateFrame("ScrollingMessageFrame", nil, panel.content)
	reader:SetPoint("TOPLEFT")
	reader:SetPoint("BOTTOMRIGHT", 0, WM.Px(104))
	reader:SetFont(STANDARD_TEXT_FONT, WM.Px(28), "")
	reader:SetJustifyH("LEFT")
	reader:SetFading(false)
	reader:SetMaxLines(300)
	reader:EnableMouseWheel(true)
	reader:SetScript("OnMouseWheel", function(self, dir)
		if dir > 0 then self:ScrollUp() else self:ScrollDown() end
	end)

	local older = WM.CreateTouchButton(panel.content, 330, 96, "Older", 30)
	older:SetPoint("BOTTOMLEFT")
	older:SetScript("OnClick", function() reader:PageUp() end)
	local newer = WM.CreateTouchButton(panel.content, 330, 96, "Newer", 30)
	newer:SetPoint("BOTTOM")
	newer:SetScript("OnClick", function() reader:PageDown() end)
	local latest = WM.CreateTouchButton(panel.content, 330, 96, "Latest", 30)
	latest:SetPoint("BOTTOMRIGHT")
	latest:SetScript("OnClick", function() reader:ScrollToBottom() end)

	panel.OnOpen = function() reader:ScrollToBottom() end

	for event in pairs(EVENTS) do
		WM.TryOn(event, OnChat)
	end

	-- With the default chat windows banished, this strip is the only visible
	-- chat surface — publish delivery so WM.Print lands here (Core.lua falls
	-- back to DEFAULT_CHAT_FRAME only before this point).
	WM.ChatDeliver = Deliver

	Deliver("WowMobile chat ready — tap this strip to expand.", 0.4, 0.8, 1.0)
end)
