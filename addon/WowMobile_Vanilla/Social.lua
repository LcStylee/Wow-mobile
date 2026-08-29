--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Social
-- Deck panel with Friends and Guild tabs.
--   Friends — Add-friend entry row (the shared edit-box pattern: tap focuses,
--             the phone keyboard types), then the list sorted online-first;
--             tap a row to unfold Whisper / Invite / Remove actions.
--   Guild   — guild name + MOTD, roster sorted online-first (name, level,
--             class, zone, rank); tap a row to unfold Whisper / Invite /
--             Promote / Demote, the latter two only where CanGuildPromote /
--             CanGuildDemote allow; a guild-invite entry row appears only for
--             CanGuildInvite.
--
-- Entry point: long-press the bottom row's "Char / Social" button (Deck.lua).
--
-- 1.12 API notes:
--   * GetFriendInfo(i) -> name, level, class, area, connected (level/class
--     can be 0/nil while offline); ShowFriends() requests a server refresh
--     that lands as FRIENDLIST_UPDATE. AddFriend/RemoveFriend by name.
--   * Group invite by name is InviteByName on 1.12 (renamed InviteUnit in
--     2.x) — both spellings are tried so a renamed private-server core works.
--   * Guild mutations are the *ByName forms on 1.12: GuildInviteByName /
--     GuildPromoteByName / GuildDemoteByName (every 1.12 FrameXML call site —
--     ChatFrame.lua's /ginvite //gpromote //gdemote, StaticPopup.lua's
--     ADD_GUILDMEMBER, FriendsFrame.xml's promote/demote buttons — uses
--     these; the short GuildInvite/GuildPromote/GuildDemote names are the
--     2.4 renames). Same fallback pattern as the group invite above.
--   * GetGuildRosterInfo(i) -> name, rank, rankIndex, level, class, zone,
--     note, officernote, online, status; GuildRoster() requests the roster
--     (GUILD_ROSTER_UPDATE), SetGuildRosterShowOffline(1) makes offline
--     members enumerable, GetGuildRosterMOTD() reads the MOTD.
--   * Whisper = ChatFrame_OpenChat("/w Name ") pre-fills the rescued edit
--     box (Chat.lua); the phone keyboard types the message.
--   * Class strings here are LOCALIZED names; RAID_CLASS_COLORS keying
--     differed across vanilla FrameXML revisions, so both the raw and the
--     upper-cased spelling are tried before falling back to plain text color.
--------------------------------------------------------------------------------

local WM = WowMobile

local ROW_H = 96
local GAP = 6
-- Very large guilds would grow the widget pool without bound; online members
-- sort first, so a cap keeps the pool sane and loses only deep-offline tail.
local MAX_GUILD_ROWS = 150

local panel, scroller
local tabButtons = {}
local tab = "friends"   -- "friends" | "guild"
local selectedName      -- unfolded row (per tab; cleared on tab switch)

local rows = {}         -- pooled person rows
local texts = {}        -- pooled info texts
local actionBtns = {}   -- pooled action buttons
local entryBox, entryBtn -- add-friend / guild-invite entry row (created once)
local entryHadFocus      -- focus snapshot across a re-render (see ResetContent)
local usedRows, usedTexts, usedActions, cursorY

local function ResetContent()
	usedRows, usedTexts, usedActions, cursorY = 0, 0, 0, 0
	for i = 1, table.getn(rows) do rows[i]:Hide() end
	for i = 1, table.getn(texts) do texts[i]:Hide() end
	for i = 1, table.getn(actionBtns) do actionBtns[i]:Hide() end
	-- Hiding the edit box drops its keyboard focus on 1.12, and event-driven
	-- re-renders land mid-typing routinely (FRIENDLIST_UPDATE on any friend
	-- login/logout, GUILD_ROSTER_UPDATE on roster changes). Snapshot the
	-- focus state (Core's CreateEditBox tracks it as eb.wmFocused) BEFORE the
	-- Hide clears it, so AddEntryRow can hand focus back — otherwise the
	-- phone user must re-tap the box to keep typing. Text survives on its own.
	entryHadFocus = entryBox.wmFocused
	entryBox:Hide()
	entryBtn:Hide()
end

local function ContentWidthPx()
	return scroller.ContentWidth() / WM.Px(1)
end

local function ClassColor(class)
	local t = RAID_CLASS_COLORS
	if t and class then
		local c = t[class] or t[string.upper(class)]
		if c then return c.r, c.g, c.b end
	end
	return 0.92, 0.92, 0.92
end

local function Whisper(name)
	-- Pre-fill the chat edit box; the phone's soft keyboard (edge-rail "Aa")
	-- types the rest — the addon-wide whisper affordance.
	ChatFrame_OpenChat("/w " .. name .. " ")
end

local function InviteName(name)
	if InviteByName then
		InviteByName(name)
	elseif InviteUnit then
		InviteUnit(name)
	end
end

-- Guild mutations: 1.12 ships only the *ByName forms (see the header note);
-- the short names cover 2.x-renamed cores, mirroring InviteName above.
local function GuildInviteName(name)
	if GuildInviteByName then
		GuildInviteByName(name)
	elseif GuildInvite then
		GuildInvite(name)
	end
end

local function GuildPromoteName(name)
	if GuildPromoteByName then
		GuildPromoteByName(name)
	elseif GuildPromote then
		GuildPromote(name)
	end
end

local function GuildDemoteName(name)
	if GuildDemoteByName then
		GuildDemoteByName(name)
	elseif GuildDemote then
		GuildDemote(name)
	end
end

--------------------------------------------------------------------------------
-- Layout builders (cursor pattern)
--------------------------------------------------------------------------------

local function AddText(text, sizePx, r, g, b)
	usedTexts = usedTexts + 1
	local fs = texts[usedTexts]
	if not fs then
		fs = WM.CreateText(scroller.child, 28)
		fs:SetJustifyH("LEFT")
		texts[usedTexts] = fs
	end
	WM.SetFont(fs, sizePx or 28)
	fs:SetTextColor(r or 0.92, g or 0.92, b or 0.92)
	fs:ClearAllPoints()
	fs:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", WM.Px(6), -WM.Px(cursorY))
	fs:SetWidth(scroller.ContentWidth() - WM.Px(12))
	fs:SetText(text)
	fs:Show()
	-- Width-constrained FontString GetHeight() = wrapped height (1.12 idiom).
	cursorY = cursorY + fs:GetHeight() / WM.Px(1) + 10
end

local function AddPersonRow(line1, line2, onTap, selected, dim)
	usedRows = usedRows + 1
	local row = rows[usedRows]
	if not row then
		row = WM.CreateTouchButton(scroller.child, 100, ROW_H, nil, 28)
		row.label:Hide()
		row.line1 = WM.CreateText(row, 28)
		row.line1:SetPoint("TOPLEFT", row, "TOPLEFT", WM.Px(20), -WM.Px(14))
		row.line1:SetJustifyH("LEFT")
		WM.SingleLine(row.line1, 28)
		row.line2 = WM.CreateText(row, 22)
		row.line2:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", WM.Px(20), WM.Px(12))
		row.line2:SetJustifyH("LEFT")
		row.line2:SetTextColor(0.65, 0.65, 0.7)
		WM.SingleLine(row.line2, 22)
		rows[usedRows] = row
	end
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", 0, -WM.Px(cursorY))
	row:SetPoint("TOPRIGHT", scroller.child, "TOPRIGHT", 0, -WM.Px(cursorY))
	row:SetHeight(WM.Px(ROW_H))
	row.line1:SetWidth(scroller.ContentWidth() - WM.Px(44))
	row.line2:SetWidth(scroller.ContentWidth() - WM.Px(44))
	row.line1:SetText(line1)
	row.line2:SetText(line2 or "")
	-- Always set the base color: rows are pooled across renders (and shared
	-- by both tabs), so an offline row's dim gray must not leak into a later
	-- online use of the same widget.
	if dim then
		row.line1:SetTextColor(0.55, 0.55, 0.6)
	else
		row.line1:SetTextColor(0.92, 0.92, 0.92)
	end
	WM.TintBorder(row, selected and WM.Colors.accent or WM.Colors.border)
	row:SetScript("OnClick", onTap)
	row:Show()
	cursorY = cursorY + ROW_H + GAP
	return row
end

-- One row of equal-width action buttons under the selected person.
local function AddActionRow(defs)
	local n = table.getn(defs)
	if n == 0 then return end
	local w = (ContentWidthPx() - GAP * (n - 1)) / n
	for i = 1, n do
		usedActions = usedActions + 1
		local b = actionBtns[usedActions]
		if not b then
			b = WM.CreateTouchButton(scroller.child, 100, 92, nil, 28)
			actionBtns[usedActions] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
			WM.Px((i - 1) * (w + GAP)), -WM.Px(cursorY))
		b:SetWidth(WM.Px(w))
		b:SetHeight(WM.Px(92))
		b.label:SetWidth(WM.Px(w - 16))
		b.label:SetText(defs[i].label)
		WM.SetButtonEnabled(b, not defs[i].disabled)
		b:SetScript("OnClick", defs[i].onTap)
		b:Show()
	end
	cursorY = cursorY + 92 + GAP
end

-- Entry row: shared edit box + action button (Add friend / Guild invite).
local function AddEntryRow(buttonLabel, onSubmit)
	entryBox:ClearAllPoints()
	entryBox:SetPoint("TOPLEFT", scroller.child, "TOPLEFT", 0, -WM.Px(cursorY))
	entryBox:Show()
	if entryHadFocus then
		entryBox:SetFocus() -- restore the focus a re-render's Hide dropped
		entryHadFocus = nil
	end
	entryBtn:ClearAllPoints()
	entryBtn:SetPoint("TOPLEFT", scroller.child, "TOPLEFT",
		WM.Px(640 + GAP), -WM.Px(cursorY))
	entryBtn.label:SetText(buttonLabel)
	-- The phone keyboard's closing Enter (Core's edit-box protocol) submits
	-- the same way the button does.
	entryBox.onEnter = function(name)
		if name and name ~= "" then
			onSubmit(name)
			entryBox:SetText("")
		end
	end
	entryBtn:SetScript("OnClick", function()
		local name = entryBox:GetText()
		if name and name ~= "" then
			onSubmit(name)
			entryBox:SetText("")
			entryBox:ClearFocus()
		end
	end)
	entryBtn:Show()
	cursorY = cursorY + 92 + GAP
end

--------------------------------------------------------------------------------
-- Friends tab
--------------------------------------------------------------------------------

local Render -- forward

local friendList = {} -- reused array (wiped per render)

local function RenderFriends()
	AddEntryRow("Add friend", function(name)
		AddFriend(name)
		-- FRIENDLIST_UPDATE re-renders once the server confirms.
	end)

	for i = table.getn(friendList), 1, -1 do table.remove(friendList, i) end
	local n = GetNumFriends()
	for i = 1, n do
		local name, level, class, area, connected = GetFriendInfo(i)
		if name then
			table.insert(friendList, {
				name = name, level = level, class = class, area = area,
				online = connected and true or false,
			})
		end
	end
	table.sort(friendList, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)

	if table.getn(friendList) == 0 then
		AddText("No friends on the list yet.", 28, 0.7, 0.7, 0.75)
	end
	for i = 1, table.getn(friendList) do
		local f = friendList[i]
		local line1, line2
		if f.online then
			local r, g, b = ClassColor(f.class)
			line1 = string.format("|cff%02x%02x%02x%s|r  —  %d %s",
				r * 255, g * 255, b * 255, f.name, f.level or 0, f.class or "")
			line2 = f.area or ""
		else
			line1 = f.name
			line2 = "Offline"
		end
		local name = f.name
		local selected = (selectedName == name)
		AddPersonRow(line1, line2, function()
			selectedName = (selectedName == name) and nil or name
			Render()
		end, selected, not f.online)
		if selected then
			AddActionRow({
				{ label = "Whisper", onTap = function() Whisper(name) end },
				{ label = "Invite", disabled = not f.online,
					onTap = function() InviteName(name) end },
				{ label = "Remove", onTap = function()
					RemoveFriend(name)
					selectedName = nil
				end },
			})
		end
	end
end

--------------------------------------------------------------------------------
-- Guild tab
--------------------------------------------------------------------------------

local guildList = {} -- reused array (wiped per render)

local function RenderGuild()
	if not IsInGuild() then
		AddText("You are not in a guild.", 30, 0.7, 0.7, 0.75)
		return
	end

	local guildName = GetGuildInfo("player")
	AddText(guildName or "Guild", 36, 1, 0.82, 0)
	local motd = GetGuildRosterMOTD and GetGuildRosterMOTD() or ""
	if motd and motd ~= "" then
		AddText("MOTD: " .. motd, 26, 0.4, 0.8, 1.0)
	end

	if CanGuildInvite and CanGuildInvite() then
		AddEntryRow("Guild invite", function(name)
			GuildInviteName(name)
		end)
	end

	for i = table.getn(guildList), 1, -1 do table.remove(guildList, i) end
	local n = GetNumGuildMembers()
	for i = 1, n do
		local name, rank, _, level, class, zone, _, _, online = GetGuildRosterInfo(i)
		if name then
			table.insert(guildList, {
				name = name, rank = rank, level = level, class = class,
				zone = zone, online = online and true or false,
			})
		end
	end
	table.sort(guildList, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)

	local shown = table.getn(guildList)
	local capped = false
	if shown > MAX_GUILD_ROWS then
		shown = MAX_GUILD_ROWS
		capped = true
	end
	local canPromote = CanGuildPromote and CanGuildPromote()
	local canDemote = CanGuildDemote and CanGuildDemote()
	local playerName = UnitName("player")

	for i = 1, shown do
		local m = guildList[i]
		local line1, line2
		if m.online then
			local r, g, b = ClassColor(m.class)
			line1 = string.format("|cff%02x%02x%02x%s|r  —  %d %s",
				r * 255, g * 255, b * 255, m.name, m.level or 0, m.class or "")
			line2 = (m.rank or "") .. "  ·  " .. (m.zone or "")
		else
			line1 = m.name
			line2 = (m.rank or "") .. "  ·  Offline"
		end
		local name = m.name
		local selected = (selectedName == name)
		AddPersonRow(line1, line2, function()
			selectedName = (selectedName == name) and nil or name
			Render()
		end, selected, not m.online)
		if selected and name ~= playerName then
			local defs = {
				{ label = "Whisper", onTap = function() Whisper(name) end },
				{ label = "Invite", disabled = not m.online,
					onTap = function() InviteName(name) end },
			}
			-- Rank changes only where the guild grants them; the server
			-- enforces relative-rank rules on top — errors surface in
			-- UIErrorsFrame like the default UI.
			if canPromote then
				table.insert(defs, { label = "Promote",
					onTap = function() GuildPromoteName(name) end })
			end
			if canDemote then
				table.insert(defs, { label = "Demote",
					onTap = function() GuildDemoteName(name) end })
			end
			AddActionRow(defs)
		end
	end
	if capped then
		AddText("Only the first " .. MAX_GUILD_ROWS ..
			" members are listed (offline tail truncated).", 24, 0.6, 0.6, 0.65)
	end
end

--------------------------------------------------------------------------------
-- Render dispatch
--------------------------------------------------------------------------------

Render = function()
	if not panel:IsShown() then return end
	for i = 1, table.getn(tabButtons) do
		local b = tabButtons[i]
		WM.TintBorder(b, (b.tabKey == tab) and WM.Colors.accent or WM.Colors.border)
	end
	ResetContent()
	if tab == "guild" then
		RenderGuild()
	else
		RenderFriends()
	end
	scroller.SetContentHeight(WM.Px(cursorY + 8))
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

WM.OnInit(function()
	panel = WM.Deck.CreatePanel("social", "Social")

	local defs = {
		{ key = "friends", label = "Friends" },
		{ key = "guild",   label = "Guild" },
	}
	for i = 1, 2 do
		local b = WM.CreateTouchButton(panel.content, 300, 92, defs[i].label, 30)
		b:SetPoint("TOPLEFT", panel.content, "TOPLEFT", WM.Px((i - 1) * 308), 0)
		b.tabKey = defs[i].key
		b:SetScript("OnClick", function()
			tab = this.tabKey
			selectedName = nil
			if tab == "guild" and IsInGuild() then
				GuildRoster() -- request a fresh roster; UPDATE re-renders
			end
			Render()
			scroller.ScrollToTop()
		end)
		tabButtons[i] = b
	end

	local listArea = CreateFrame("Frame", nil, panel.content)
	listArea:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -WM.Px(100))
	listArea:SetPoint("BOTTOMRIGHT", panel.content, "BOTTOMRIGHT", 0, 0)
	scroller = WM.Deck.CreateScroller(listArea)

	-- Entry-row widgets (created once, repositioned per render).
	entryBox = WM.CreateEditBox(scroller.child, 640, 92, 12) -- names cap at 12
	-- Focus tracking for the re-render snapshot in ResetContent comes with
	-- the box: Core's CreateEditBox maintains entryBox.wmFocused (its focus
	-- scripts also drive the phone-keyboard Enter protocol — don't override).
	entryBox:Hide()
	entryBtn = WM.CreateTouchButton(scroller.child, 300, 92, "", 28)
	entryBtn:Hide()

	panel.OnOpen = function()
		selectedName = nil
		ShowFriends() -- server round-trip; FRIENDLIST_UPDATE re-renders
		if IsInGuild() then
			if SetGuildRosterShowOffline then
				SetGuildRosterShowOffline(1) -- offline members enumerable
			end
			GuildRoster()
		end
		Render()
		scroller.ScrollToTop()
	end

	WM.On("FRIENDLIST_UPDATE", function()
		if tab == "friends" then Render() end
	end)
	WM.On("GUILD_ROSTER_UPDATE", function()
		if tab == "guild" then Render() end
	end)
	WM.TryOn("GUILD_MOTD", function()
		if tab == "guild" then Render() end
	end)
	-- Membership changes flip the whole guild tab's availability.
	WM.TryOn("PLAYER_GUILD_UPDATE", function()
		if tab == "guild" then Render() end
	end)
end)
