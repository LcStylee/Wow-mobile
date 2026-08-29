--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Chat
-- Read-focused chat for a phone screen:
--   * compact ScrollingMessageFrame strip at the top of the deck; tap it to
--     open a deck-filling reader panel with paging buttons,
--   * both views are fed from CHAT_MSG_* events directly (the default chat
--     windows are banished),
--   * the shared edit box (1.12 has ONE global ChatFrameEditBox, not one per
--     chat frame) is rescued BEFORE ChatFrame1 is banished, restyled large,
--     and re-anchored over the chat strip — typing arrives via the streaming
--     client's keyboard (edge-rail Aa opens it).
--------------------------------------------------------------------------------

local WM = WowMobile

-- event -> short channel tag ("" = no tag). CHAT_MSG_CHANNEL derives its tag
-- from the channel number at runtime.
local EVENTS = {
	CHAT_MSG_SAY = "",              CHAT_MSG_YELL = "Yell",
	CHAT_MSG_WHISPER = "From",      CHAT_MSG_WHISPER_INFORM = "To",
	CHAT_MSG_PARTY = "P",
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

-- 1.12 CHAT_MSG_CHANNEL: arg8 = channel number.
local function OnChat(ev, msg, sender, a3, a4, a5, a6, a7, channelIndex)
	local chatType = string.sub(ev, 10) -- strip "CHAT_MSG_"
	local tag = EVENTS[ev]
	if ev == "CHAT_MSG_CHANNEL" then
		tag = tostring(channelIndex or "?")
		chatType = "CHANNEL"
	end
	local info = (ChatTypeInfo and (ChatTypeInfo[chatType] or ChatTypeInfo["SAY"]))
		or { r = 1, g = 1, b = 1 }

	local name = sender and sender ~= "" and sender or nil

	-- The emote family never uses the generic "name: msg" shape:
	local line
	if ev == "CHAT_MSG_TEXT_EMOTE" then
		-- arg1 is the complete pre-baked line ("Bob waves at you.") — the
		-- sender is already embedded, so a name prefix would double it.
		line = msg
	elseif ev == "CHAT_MSG_MONSTER_EMOTE" then
		-- arg1 is a format pattern with a literal %s for the mob's name; the
		-- default UI renders it as format(arg1, arg2), so do the same.
		line = string.format(msg, sender or "")
	elseif ev == "CHAT_MSG_EMOTE" then
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
	local eb = ChatFrameEditBox
	if not eb then return end
	eb:SetParent(UIParent)
	eb:SetFrameStrata("DIALOG")
	eb:ClearAllPoints()
	eb:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", WM.Px(8), -WM.Px(4))
	eb:SetPoint("TOPRIGHT", WM.Deck, "TOPRIGHT", -WM.Px(8), -WM.Px(4))
	eb:SetHeight(WM.Px(70))
	if eb.SetFont then
		eb:SetFont(WM.FONT, WM.Px(32))
	end
	if eb.SetAltArrowKeyMode then
		eb:SetAltArrowKeyMode(false)
	end
	-- Strip the parchment art; give it the deck's flat look instead.
	local suffixes = { "Left", "Mid", "Right" }
	for i = 1, table.getn(suffixes) do
		local tex = getglobal("ChatFrameEditBox" .. suffixes[i])
		if tex then tex:SetAlpha(0) end
	end
	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(eb)
	bg:SetTexture(0.08, 0.08, 0.10, 0.95)
end

local function BanishDefaultChat()
	for i = 1, NUM_CHAT_WINDOWS or 7 do
		-- keepEvents: chat frames keep processing so Blizzard-side chat state
		-- (history, sticky channels, the edit box) stays coherent while the
		-- windows themselves are invisible.
		WM.BanishFrame(getglobal("ChatFrame" .. i), true)
		WM.BanishFrame(getglobal("ChatFrame" .. i .. "Tab"), true)
	end
	WM.BanishFrame(getglobal("ChatFrameMenuButton"))
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	-- Rescue the edit box FIRST: banishing ChatFrame1 would drag it into the
	-- hidden parent otherwise (it is parented to ChatFrame1 in 1.12 XML).
	SetupEditBox()
	BanishDefaultChat()

	-- Compact strip: deck top edge down to the unit row.
	local strip = CreateFrame("Frame", "WowMobileChatStrip", WM.Deck)
	strip:SetPoint("TOPLEFT", WM.Deck, "TOPLEFT", WM.Px(8), -WM.Px(6))
	strip:SetPoint("TOPRIGHT", WM.Deck, "TOPRIGHT", -WM.Px(8), -WM.Px(6))
	strip:SetPoint("BOTTOMLEFT", WM.Layout.unitRow, "TOPLEFT", 0, WM.Px(6))
	WM.SkinFrame(strip, { 0.03, 0.03, 0.04, 0.6 }, { 0.18, 0.18, 0.22, 0.6 })
	WM.Layout.chat = strip

	compact = CreateFrame("ScrollingMessageFrame", nil, strip)
	compact:SetPoint("TOPLEFT", strip, "TOPLEFT", WM.Px(10), -WM.Px(4))
	compact:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", -WM.Px(10), WM.Px(4))
	compact:SetFont(WM.FONT, WM.Px(24))
	compact:SetJustifyH("LEFT")
	if compact.SetFading then compact:SetFading(false) end
	if compact.SetMaxLines then compact:SetMaxLines(64) end
	compact:EnableMouse(true)
	compact:SetScript("OnMouseUp", function()
		WM.Deck.Open("chat")
	end)

	-- Reader panel.
	local panel = WM.Deck.CreatePanel("chat", "Chat")
	reader = CreateFrame("ScrollingMessageFrame", nil, panel.content)
	reader:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, 0)
	reader:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, WM.Px(104))
	reader:SetFont(WM.FONT, WM.Px(28))
	reader:SetJustifyH("LEFT")
	if reader.SetFading then reader:SetFading(false) end
	if reader.SetMaxLines then reader:SetMaxLines(300) end
	reader:EnableMouseWheel(true)
	reader:SetScript("OnMouseWheel", function()
		if arg1 > 0 then this:ScrollUp() else this:ScrollDown() end
	end)

	local older = WM.CreateTouchButton(panel.content, 330, 96, "Older", 30)
	older:SetPoint("BOTTOMLEFT", panel.content, "BOTTOMLEFT", 0, 0)
	older:SetScript("OnClick", function() reader:PageUp() end)
	local newer = WM.CreateTouchButton(panel.content, 330, 96, "Newer", 30)
	newer:SetPoint("BOTTOM", panel.content, "BOTTOM", 0, 0)
	newer:SetScript("OnClick", function() reader:PageDown() end)
	local latest = WM.CreateTouchButton(panel.content, 330, 96, "Latest", 30)
	latest:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, 0)
	latest:SetScript("OnClick", function() reader:ScrollToBottom() end)

	panel.OnOpen = function() reader:ScrollToBottom() end

	for ev in pairs(EVENTS) do
		WM.TryOn(ev, OnChat)
	end

	-- With the default chat windows banished, this strip is the only visible
	-- chat surface — publish delivery so WM.Print lands here (Core.lua falls
	-- back to DEFAULT_CHAT_FRAME only before this point).
	WM.ChatDeliver = Deliver

	Deliver("WowMobile chat ready — tap this strip to expand.", 0.4, 0.8, 1.0)
end)
