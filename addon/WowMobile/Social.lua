--------------------------------------------------------------------------------
-- WowMobile · Social
-- Deck panel with Friends and Guild tabs (own tab row, the Spellbook pattern;
-- rows/stacks via SheetKit's pooled builder over a Deck scroller):
--   Friends — list (online first: name, level, class, zone), tap a row for
--     actions: Whisper (chat pre-fill via WM.WhisperTo, landing in the
--     rescued edit box), Invite to group, Remove (two-tap); Add Friend via
--     the SheetKit text-field entry pattern (phone keyboard).
--   Guild — MOTD, member counts, roster online-first (name, level, class,
--     zone, rank); tap a member for actions gated on permissions: Whisper,
--     Invite to group, Promote/Demote (CanGuildPromote/Demote plus the
--     default UI's rank arithmetic against your own rank), Remove
--     (CanGuildRemove, two-tap). Roster indices shift on every
--     GUILD_ROSTER_UPDATE, so the detail view re-finds its member by name.
-- Both lists are event-driven rebuilds over pooled widgets (FRIENDLIST_UPDATE
-- / GUILD_ROSTER_UPDATE); the offline part of a big guild roster renders in
-- 60-row pages behind a "Show more" button so a 400-member guild does not lay
-- out hundreds of rows per update.
--------------------------------------------------------------------------------

local _, WM = ...

local panel, scroller, st, addField
local tabButtons = {}
local tab = "friends"   -- "friends" | "guild"
local view = "list"     -- "list" | "detail"
local selected          -- { name (full), short } — re-validated by name on render
local removeArmed = false
local offlineShown = 60 -- guild roster offline page size / current cap

-- Localized class name -> class file token (for RAID_CLASS_COLORS): the
-- friends API only hands back the localized class name.
local classFileByName = {}
do
	for _, tbl in next, { LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE } do
		if type(tbl) == "table" then
			for file, localized in pairs(tbl) do
				classFileByName[localized] = file
			end
		end
	end
end

local function ClassColored(name, className)
	local file = className and classFileByName[className]
	local c = file and RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
	if c then
		return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, name)
	end
	return name
end

local function ShortName(name)
	if name and Ambiguate then
		return Ambiguate(name, "guild")
	end
	return name
end

local Render -- forward: view/tab dispatcher

--------------------------------------------------------------------------------
-- Friends tab
--------------------------------------------------------------------------------

local function CollectFriends()
	local out = {}
	for i = 1, WM.Friends.Num() do
		local name, level, className, area, connected = WM.Friends.GetInfo(i)
		if name then
			out[#out + 1] = { name = name, level = level, className = className,
				area = area, connected = connected }
		end
	end
	table.sort(out, function(a, b)
		if a.connected ~= b.connected then return a.connected end
		return a.name < b.name
	end)
	return out
end

local function RenderFriendsList()
	st.Anchor(addField, 96)

	local friends = CollectFriends()
	for i = 1, #friends do
		local f = friends[i]
		local label
		if f.connected then
			label = string.format("%s  |cff33ff33·|r  [%d] %s — %s",
				ClassColored(f.name, f.className), f.level or 0,
				f.className or "?", f.area or "?")
		else
			label = string.format("|cff8a8a8f%s — Offline|r", f.name)
		end
		local entry = f
		st.Button(label, nil, function()
			view, selected, removeArmed = "detail", { name = entry.name, short = entry.name }, false
			Render()
		end)
	end
	if #friends == 0 then
		st.Text("No friends on the list yet — type a name above.", 28, 0.7, 0.7, 0.75)
	end
	st.Finish("friends-list")
end

local function RenderFriendDetail()
	-- Drop the add-friend field on the list->detail transition, same as
	-- SelectTab does on tab switches: SheetKit's Reset never Hide()s a
	-- FOCUSED EditBox (phone-keyboard guard) and only the friends LIST
	-- render re-Anchors it, so a field left focused (row taps don't clear
	-- EditBox focus) would float over this view's Back button and still
	-- submit its leftover text on Enter.
	if addField then
		addField:ClearFocus()
		addField:Hide()
	end
	st.Button("< Back", nil, function()
		view, removeArmed = "list", false
		Render()
	end)
	st.Text(selected.name, 36, 1, 0.82, 0)
	st.Button("Whisper", nil, function()
		WM.WhisperTo(selected.short)
	end)
	st.Button("Invite to group", nil, function()
		WM.InviteToGroup(selected.name)
	end)
	local b = st.Button(removeArmed and "Really remove? Tap to confirm" or "Remove friend", nil, function()
		if not removeArmed then
			removeArmed = true
			Render()
			return
		end
		WM.Friends.Remove(selected.name)
		view, removeArmed = "list", false
		WM.Friends.Request() -- FRIENDLIST_UPDATE re-renders the list
	end)
	b.label:SetTextColor(0.9, 0.35, 0.35)
	st.Finish("friend-detail")
end

--------------------------------------------------------------------------------
-- Guild tab
--------------------------------------------------------------------------------

-- Roster entry by full name; nil when the member left/was removed.
local function FindGuildMember(fullName)
	local total = GetNumGuildMembers()
	for i = 1, total do
		local name, rank, rankIndex, level, class, zone, _, _, online = GetGuildRosterInfo(i)
		if name == fullName then
			return { name = name, rank = rank, rankIndex = rankIndex, level = level,
				class = class, zone = zone, online = online }
		end
	end
	return nil
end

local function RenderGuildList()
	if not IsInGuild() then
		st.Text("You are not in a guild.", 30, 0.7, 0.7, 0.75)
		st.Finish("guild-none")
		return
	end

	local guildName = GetGuildInfo("player")
	local total, online = GetNumGuildMembers()
	st.Text(string.format("%s — %d members, |cff33ff33%d online|r",
		guildName or "Guild", total or 0, online or 0), 32, 1, 0.82, 0)

	local motd = WM.GuildMOTD()
	if motd ~= "" then
		st.Text("MOTD: " .. motd, 28, 0.55, 0.85, 0.55)
	end

	-- Online first, then name; offline capped to `offlineShown` rows.
	local onlineList, offlineList = {}, {}
	for i = 1, total or 0 do
		local name, rank, rankIndex, level, class, zone, _, _, isOnline,
			_, classFile = GetGuildRosterInfo(i)
		if name then
			local e = { name = name, rank = rank, rankIndex = rankIndex,
				level = level, class = class, zone = zone,
				classFile = classFile, online = isOnline }
			if isOnline then
				onlineList[#onlineList + 1] = e
			elseif #offlineList < offlineShown then
				offlineList[#offlineList + 1] = e
			end
		end
	end
	table.sort(onlineList, function(a, b) return a.name < b.name end)

	local function MemberRow(e)
		local display = ShortName(e.name)
		local colored = (e.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.classFile])
			and ClassColored(display, LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[e.classFile] or nil)
			or ClassColored(display, e.class)
		local label
		if e.online then
			label = string.format("%s  [%d] %s — %s  |cff8a8a8f(%s)|r",
				colored, e.level or 0, e.class or "?", e.zone or "?", e.rank or "")
		else
			label = string.format("|cff8a8a8f%s — Offline (%s)|r", display, e.rank or "")
		end
		st.Button(label, nil, function()
			view, selected, removeArmed = "detail", { name = e.name, short = ShortName(e.name) }, false
			Render()
		end)
	end

	for i = 1, #onlineList do MemberRow(onlineList[i]) end
	if #offlineList > 0 then
		st.Text("Offline", 30, 0.7, 0.7, 0.75)
		for i = 1, #offlineList do MemberRow(offlineList[i]) end
	end
	local shownOffline = #offlineList
	local totalOffline = (total or 0) - (online or 0)
	if shownOffline < totalOffline then
		st.Button(string.format("Show more offline (%d of %d shown)",
			shownOffline, totalOffline), nil, function()
			offlineShown = offlineShown + 60
			Render()
		end)
	end
	st.Finish("guild-list")
end

local function RenderGuildDetail()
	-- Re-find the member BEFORE emitting anything: falling back to the list
	-- after a Back button is already in the stack would leave a stray Back
	-- row stacked above the roster.
	local m = FindGuildMember(selected.name)
	if not m then
		-- Member vanished from the roster: back to the list.
		view = "list"
		RenderGuildList()
		return
	end
	st.Button("< Back", nil, function()
		view, removeArmed = "list", false
		Render()
	end)
	st.Text(string.format("%s — [%d] %s, %s", ShortName(m.name), m.level or 0,
		m.class or "?", m.rank or "?"), 34, 1, 0.82, 0)
	if m.online then
		st.Text("Online — " .. (m.zone or "?"), 26, 0.55, 0.85, 0.55)
	else
		st.Text("Offline", 26, 0.6, 0.6, 0.65)
	end

	st.Button("Whisper", nil, function()
		WM.WhisperTo(selected.short)
	end)
	if m.online then
		st.Button("Invite to group", nil, function()
			WM.InviteToGroup(m.name)
		end)
	end

	-- Permission gates: the predicate AND the default UI's rank arithmetic
	-- (classic_era FriendsFrame.lua GuildStatus_Update): promote only ranks
	-- below the one under yours, demote nothing at/above you nor the lowest
	-- rank. rankIndex is 0-based (0 = Guild Master).
	local _, _, myRankIndex = GetGuildInfo("player")
	myRankIndex = myRankIndex or 0
	local numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or nil
	local ri = m.rankIndex or 0

	if CanGuildPromote and CanGuildPromote() and ri > 1 and ri > myRankIndex + 1 then
		st.Button("Promote", nil, function()
			WM.GuildPromote(m.name)
			WM.GuildRosterRequest() -- GUILD_ROSTER_UPDATE re-renders
		end)
	end
	if CanGuildDemote and CanGuildDemote() and ri >= 1 and ri > myRankIndex
			and (not numRanks or ri ~= numRanks - 1) then
		st.Button("Demote", nil, function()
			WM.GuildDemote(m.name)
			WM.GuildRosterRequest()
		end)
	end
	if CanGuildRemove and CanGuildRemove() and ri >= 1 and ri > myRankIndex then
		local b = st.Button(removeArmed and "Really remove from guild? Tap to confirm"
			or "Remove from guild", nil, function()
			if not removeArmed then
				removeArmed = true
				Render()
				return
			end
			WM.GuildRemove(m.name)
			view, removeArmed = "list", false
			WM.GuildRosterRequest()
		end)
		b.label:SetTextColor(0.9, 0.35, 0.35)
	end
	st.Finish("guild-detail")
end

--------------------------------------------------------------------------------
-- Dispatch + tabs
--------------------------------------------------------------------------------

Render = function()
	if not panel:IsShown() then return end
	st.Reset()
	for key, b in pairs(tabButtons) do
		local c = (key == tab) and WM.Colors.accent or WM.Colors.border
		b.borderTex:SetColorTexture(c[1], c[2], c[3], 1)
	end
	if tab == "friends" then
		if view == "detail" then RenderFriendDetail() else RenderFriendsList() end
	else
		if view == "detail" then RenderGuildDetail() else RenderGuildList() end
	end
end

local function SelectTab(key)
	tab, view, removeArmed = key, "list", false
	offlineShown = 60
	-- Drop the add-friend field before rendering: SheetKit's Reset never
	-- Hide()s a FOCUSED EditBox (phone-keyboard guard), and only the friends
	-- render re-Anchors it — so a focused field would otherwise stay visible
	-- (and accept an Enter) over the guild list. ClearFocus first so the
	-- Reset guard no longer protects it; the friends render's Anchor re-shows.
	if addField then
		addField:ClearFocus()
		addField:Hide()
	end
	if key == "guild" and IsInGuild() then
		-- Full roster (offline included) so the counts and the paged offline
		-- section are complete; era keeps the classic show-offline toggle.
		if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
		WM.GuildRosterRequest()
	elseif key == "friends" then
		WM.Friends.Request()
	end
	Render()
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	panel = WM.Deck.CreatePanel("social", "Social")

	-- Tab row (own frames — Deck panels have no built-in tabs).
	for i, def in next, { { "friends", "Friends" }, { "guild", "Guild" } } do
		local b = WM.CreateTouchButton(panel.content, 240, 92, def[2], 30)
		b:SetPoint("TOPLEFT", WM.Px((i - 1) * 248), 0)
		b:SetScript("OnClick", function() SelectTab(def[1]) end)
		tabButtons[def[1]] = b
	end

	local body = CreateFrame("Frame", nil, panel.content)
	body:SetPoint("TOPLEFT", 0, -WM.Px(100))
	body:SetPoint("BOTTOMRIGHT")
	scroller = WM.Deck.CreateScroller(body)
	st = Kit.NewStack(scroller)

	-- Add-friend field (created once; positioned into the flow via Anchor).
	addField = Kit.CreateTextField(scroller.child, 940, "Add friend — type a name, then Enter", 48)
	addField.onEnter = function(text)
		text = text and text:gsub("^%s+", ""):gsub("%s+$", "")
		if text and text ~= "" then
			WM.Friends.Add(text)
			addField:SetText("")
			WM.Friends.Request() -- FRIENDLIST_UPDATE renders the new row
		end
	end

	panel.OnOpen = function()
		view, removeArmed = "list", false
		SelectTab(tab)
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
	WM.TryOn("PLAYER_GUILD_UPDATE", function()
		if tab == "guild" then Render() end
	end)
end)
