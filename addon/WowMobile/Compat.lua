--------------------------------------------------------------------------------
-- WowMobile · Compat
-- Feature-detecting wrappers around APIs that differ across Classic client
-- builds. Callers never branch on client version themselves:
--   WM.Gossip.*     – C_GossipInfo (structured tables)  vs  legacy variadic
--                     GetGossipOptions / GetGossipAvailableQuests / ...
--   WM.Container.*  – C_Container.*                     vs  GetContainerNumSlots,
--                     GetContainerItemLink, UseContainerItem & co.
--   WM.GetAura      – UnitAura/UnitBuff positional API  vs  C_UnitAuras aura data tables
--   WM.CastingInfo / WM.ChannelInfo – UnitCastingInfo   vs  player-only CastingInfo
--   WM.PickupSpellBookSlot – PickupSpellBookItem        vs  PickupSpell(spellID)
--   WM.Friends.*    – C_FriendList                      vs  GetNumFriends & co.
--   WM.Guild*/WM.InviteToGroup/WM.WhisperTo/WM.*ReadyCheck/WM.SetWatchedFaction
--                   – C_GuildInfo / C_PartyInfo / ChatFrameUtil vs their
--                     deprecated-shim globals (see each section's source notes)
-- Detection is done once at load; each wrapper is a plain closure with no
-- per-call branching.
--------------------------------------------------------------------------------

local _, WM = ...

--------------------------------------------------------------------------------
-- Gossip
-- Normalized entry shape handed to the UI:
--   option:   { name, icon, key, index }       key (may be nil) is the real
--                                              gossipOptionID; index is the
--                                              1-based list position fallback.
--                                              Pass the whole entry back to
--                                              SelectOption.
--   available:{ title, isTrivial, key }        key feeds SelectAvailableQuest
--   active:   { title, isComplete, key }       key feeds SelectActiveQuest
--------------------------------------------------------------------------------

local Gossip = {}
WM.Gossip = Gossip

local ICON_GOSSIP    = "Interface\\GossipFrame\\GossipGossipIcon"
local ICON_AVAILABLE = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_ACTIVE    = "Interface\\GossipFrame\\ActiveQuestIcon"

if C_GossipInfo and C_GossipInfo.GetOptions then
	Gossip.GetText = function() return C_GossipInfo.GetText() or "" end

	Gossip.GetOptions = function()
		local out = {}
		local opts = C_GossipInfo.GetOptions() or {}
		for i = 1, #opts do
			local o = opts[i]
			out[i] = {
				name = o.name or "",
				icon = (type(o.icon) == "number" and o.icon) or ICON_GOSSIP,
				-- Newer builds select by gossipOptionID. It can be nil (and
				-- orderIndex is a 0-BASED position, not an ID — feeding it to
				-- SelectOption selects nothing or the wrong option), so the
				-- fallback is selection by 1-based list position, kept
				-- separately in `index`.
				key   = o.gossipOptionID,
				index = i,
			}
		end
		return out
	end

	-- 1.15 ships C_GossipInfo.SelectOptionByIndex for position-based
	-- selection; feature-detected so pre-ByIndex C_GossipInfo builds (where
	-- SelectOption itself took the list index) keep working.
	local SelectByIndex = C_GossipInfo.SelectOptionByIndex

	Gossip.SelectOption = function(entry)
		if entry.key then
			C_GossipInfo.SelectOption(entry.key)
		elseif SelectByIndex then
			SelectByIndex(entry.index)
		else
			C_GossipInfo.SelectOption(entry.index)
		end
	end

	Gossip.GetAvailableQuests = function()
		local out = {}
		local quests = C_GossipInfo.GetAvailableQuests() or {}
		for i = 1, #quests do
			local q = quests[i]
			out[i] = { title = q.title or "", isTrivial = q.isTrivial or false, key = q.questID or i }
		end
		return out
	end

	Gossip.SelectAvailableQuest = function(entry) C_GossipInfo.SelectAvailableQuest(entry.key) end

	Gossip.GetActiveQuests = function()
		local out = {}
		local quests = C_GossipInfo.GetActiveQuests() or {}
		for i = 1, #quests do
			local q = quests[i]
			out[i] = { title = q.title or "", isComplete = q.isComplete or false, key = q.questID or i }
		end
		return out
	end

	Gossip.SelectActiveQuest = function(entry) C_GossipInfo.SelectActiveQuest(entry.key) end
	Gossip.Close = function() C_GossipInfo.CloseGossip() end
else
	-- Legacy variadic API: values arrive as flat multi-returns with a fixed
	-- stride per entry, and selection is by 1-based entry index. Strides match
	-- the 1.13-era return shapes; the trailing isIgnored field is a retail
	-- 8.2.5 addition that never existed on the clients that take this branch.
	local STRIDE_OPTION = 2    -- text, gossipType
	local STRIDE_AVAILABLE = 6 -- title, level, isTrivial, frequency, isRepeatable, isLegendary
	local STRIDE_ACTIVE = 5    -- title, level, isTrivial, isComplete, isLegendary

	Gossip.GetText = function() return GetGossipText() or "" end

	Gossip.GetOptions = function()
		local out = {}
		local raw = { GetGossipOptions() }
		for i = 1, #raw, STRIDE_OPTION do
			local idx = math.floor(i / STRIDE_OPTION) + 1
			out[idx] = { name = raw[i] or "", icon = ICON_GOSSIP, key = idx }
		end
		return out
	end

	Gossip.SelectOption = function(entry) SelectGossipOption(entry.key) end

	Gossip.GetAvailableQuests = function()
		local out = {}
		local raw = { GetGossipAvailableQuests() }
		for i = 1, #raw, STRIDE_AVAILABLE do
			local idx = math.floor(i / STRIDE_AVAILABLE) + 1
			out[idx] = { title = raw[i] or "", isTrivial = raw[i + 2] or false, key = idx }
		end
		return out
	end

	Gossip.SelectAvailableQuest = function(entry) SelectGossipAvailableQuest(entry.key) end

	Gossip.GetActiveQuests = function()
		local out = {}
		local raw = { GetGossipActiveQuests() }
		for i = 1, #raw, STRIDE_ACTIVE do
			local idx = math.floor(i / STRIDE_ACTIVE) + 1
			out[idx] = { title = raw[i] or "", isComplete = raw[i + 3] or false, key = idx }
		end
		return out
	end

	Gossip.SelectActiveQuest = function(entry) SelectGossipActiveQuest(entry.key) end
	Gossip.Close = function() CloseGossip() end
end

Gossip.ICON_AVAILABLE = ICON_AVAILABLE
Gossip.ICON_ACTIVE = ICON_ACTIVE

--------------------------------------------------------------------------------
-- Containers
--------------------------------------------------------------------------------

local Container = {}
WM.Container = Container

if C_Container and C_Container.GetContainerNumSlots then
	Container.GetNumSlots = function(bag) return C_Container.GetContainerNumSlots(bag) or 0 end
	Container.GetFreeSlots = function(bag) return (C_Container.GetContainerNumFreeSlots(bag)) or 0 end
	-- Returns: icon, count, locked, quality (nil when the slot is empty).
	Container.GetItemInfo = function(bag, slot)
		local info = C_Container.GetContainerItemInfo(bag, slot)
		if not info then return nil end
		return info.iconFileID, info.stackCount, info.isLocked, info.quality
	end
	Container.GetItemLink = function(bag, slot) return C_Container.GetContainerItemLink(bag, slot) end
	-- Use/equip the slot's item — which SELLS it while a merchant window is
	-- open (the default bags' behavior; the sell view of the bottom sheet
	-- relies on this). Hardware-event gated, so only call from click handlers.
	Container.UseItem = function(bag, slot) C_Container.UseContainerItem(bag, slot) end
	Container.BagInventoryID = function(bag) return C_Container.ContainerIDToInventoryID(bag) end
	-- Cursor carry (MoveMode.lua): Pickup lifts the slot's item onto the
	-- cursor — or, with something already held, places/swaps it into the slot
	-- (the one call does both, Blizzard's own container-button semantics).
	-- Split puts n of a stack on the cursor. Neither is protected.
	Container.Pickup = function(bag, slot) C_Container.PickupContainerItem(bag, slot) end
	Container.Split = function(bag, slot, n) C_Container.SplitContainerItem(bag, slot, n) end
else
	Container.GetNumSlots = function(bag) return GetContainerNumSlots(bag) or 0 end
	Container.GetFreeSlots = function(bag) return (GetContainerNumFreeSlots(bag)) or 0 end
	Container.GetItemInfo = function(bag, slot)
		local icon, count, locked, quality = GetContainerItemInfo(bag, slot)
		if not icon then return nil end
		return icon, count, locked, quality
	end
	Container.GetItemLink = function(bag, slot) return GetContainerItemLink(bag, slot) end
	Container.UseItem = function(bag, slot) UseContainerItem(bag, slot) end
	Container.BagInventoryID = function(bag) return ContainerIDToInventoryID(bag) end
	Container.Pickup = function(bag, slot) PickupContainerItem(bag, slot) end
	Container.Split = function(bag, slot, n) SplitContainerItem(bag, slot, n) end
end

--------------------------------------------------------------------------------
-- Spellbook pickup (MoveMode.lua)
-- Classic Era 1.15 ships PickupSpellBookItem(slot, bookType) — its own
-- FrameXML SpellBookFrame drag handlers call it. Builds without it fall back
-- to PickupSpell(spellID), resolving the ID through GetSpellBookItemInfo
-- (second return on classic-lineage clients). Not protected, but only ever
-- called out of combat by MoveMode.
--------------------------------------------------------------------------------

if PickupSpellBookItem then
	WM.PickupSpellBookSlot = function(slot, bookType)
		PickupSpellBookItem(slot, bookType)
	end
elseif PickupSpell then
	WM.PickupSpellBookSlot = function(slot, bookType)
		local _, id = GetSpellBookItemInfo(slot, bookType)
		if id then PickupSpell(id) end
	end
else
	WM.PickupSpellBookSlot = function() end
end

--------------------------------------------------------------------------------
-- Auras
-- WM.GetAura(unit, index, filter) -> name, icon, count, dispelType, duration,
-- expirationTime — the classic UnitAura positional shape, synthesized from
-- C_UnitAuras aura-data tables on clients that removed the positional API.
--------------------------------------------------------------------------------

if UnitAura then
	WM.GetAura = function(unit, index, filter)
		return UnitAura(unit, index, filter)
	end
else
	WM.GetAura = function(unit, index, filter)
		local a = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
		if not a then return nil end
		return a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime
	end
end

--------------------------------------------------------------------------------
-- Auction deposit + posting (AuctionHouse.lua)
-- Verified against the 1.15 client's own UI source (Blizzard_AuctionUI/
-- Classic/Blizzard_AuctionUI.lua, gethe/wow-ui-source classic_era branch):
--   * deposit:  GetAuctionDeposit(duration, minBid, buyoutPrice, stackSize,
--               numStacks) — NOT the old CalculateAuctionDeposit(runTime),
--   * posting:  PostAuction(minBid, buyoutPrice, duration, stackSize,
--               numStacks, confirmed) — NOT vanilla's StartAuction. It
--               returns true when the post went through; false means the
--               server raised AUCTION_HOUSE_POST_WARNING (re-post with
--               confirmed = true to accept) or AUCTION_HOUSE_POST_ERROR.
--   * duration: the radio index 1|2|3 (labels AUCTION_DURATION_ONE/TWO/
--               THREE = 2h/8h/24h on era), not minutes.
-- Older classic builds (pre-1.14 throttle rework) shipped
-- CalculateAuctionDeposit(runTime) and StartAuction(minBid, buyout, runTime,
-- stackSize, numStacks) with no return, where runTime is in MINUTES
-- (120/480/1440), not the 1|2|3 index — the fallback maps the index. Both
-- fallbacks are best-effort (dead code on the 11507 target, unverifiable in
-- this sandbox) and report "posted" unconditionally, since no confirm
-- handshake existed on those builds.
--------------------------------------------------------------------------------

if GetAuctionDeposit then
	WM.AuctionDeposit = function(duration, minBid, buyout, stackSize, numStacks)
		return GetAuctionDeposit(duration, minBid, buyout, stackSize, numStacks) or 0
	end
elseif CalculateAuctionDeposit then
	WM.AuctionDeposit = function(duration)
		return CalculateAuctionDeposit(duration) or 0
	end
else
	WM.AuctionDeposit = function() return 0 end
end

if PostAuction then
	WM.PostAuction = function(minBid, buyout, duration, stackSize, numStacks, confirmed)
		return PostAuction(minBid, buyout, duration, stackSize, numStacks, confirmed)
	end
elseif StartAuction then
	local RUN_TIME_MINUTES = { 120, 480, 1440 } -- index 1|2|3 -> minutes
	WM.PostAuction = function(minBid, buyout, duration, stackSize, numStacks)
		StartAuction(minBid, buyout, RUN_TIME_MINUTES[duration] or duration,
			stackSize, numStacks)
		return true
	end
else
	WM.PostAuction = function() return true end
end

--------------------------------------------------------------------------------
-- Trade money offer (Trade.lua)
-- On 1.15 (10.x engine) the money-offer setter lives on C_TradeInfo only: the
-- 1.15.9 client UI source has zero bare-global SetTradeMoney callers
-- (Blizzard_UIPanels_Game/Classic/TradeFrame.lua and Blizzard_MoneyFrame both
-- call C_TradeInfo.SetTradeMoney), TradeInfoDocumentation.lua lists it only
-- under C_TradeInfo, and the Blizzard_DeprecatedTradeInfo shim restores only
-- PickupTradeMoney — the bare global was removed. Pre-C_TradeInfo classic
-- builds keep the global setter, hence the fallback branch. The GETTERS
-- (GetPlayerTradeMoney / GetTargetTradeMoney) are still plain globals on
-- 1.15 (MoneyFrame.lua localizes them), so no wrapper is needed for those.
--------------------------------------------------------------------------------

if C_TradeInfo and C_TradeInfo.SetTradeMoney then
	WM.SetTradeMoney = function(copper) C_TradeInfo.SetTradeMoney(copper) end
elseif SetTradeMoney then
	local set = SetTradeMoney
	WM.SetTradeMoney = function(copper) set(copper) end
else
	WM.SetTradeMoney = function() end
end

--------------------------------------------------------------------------------
-- Bag space + mail command state (Mail.lua's collect-all loop)
-- C_Container.CalculateTotalNumberOfFreeBagSlots and C_Mail.IsCommandPending
-- both exist on 1.15 (the default OpenAllMailMixin uses exactly these);
-- pre-C_Container builds sum the per-bag free counts, and without C_Mail the
-- collector falls back to its fixed inter-take delay alone.
--------------------------------------------------------------------------------

if C_Container and C_Container.CalculateTotalNumberOfFreeBagSlots then
	WM.FreeBagSlots = function()
		return C_Container.CalculateTotalNumberOfFreeBagSlots() or 0
	end
else
	WM.FreeBagSlots = function()
		local free = 0
		for bag = 0, NUM_BAG_SLOTS or 4 do
			free = free + Container.GetFreeSlots(bag)
		end
		return free
	end
end

if C_Mail and C_Mail.IsCommandPending then
	WM.MailCommandPending = function() return C_Mail.IsCommandPending() end
else
	WM.MailCommandPending = function() return false end
end

--------------------------------------------------------------------------------
-- Player cast info
-- Both wrappers return: name, displayText, texture, startTimeMs, endTimeMs.
--------------------------------------------------------------------------------

if UnitCastingInfo then
	WM.CastingInfo = function() return UnitCastingInfo("player") end
	WM.ChannelInfo = function() return UnitChannelInfo("player") end
else
	WM.CastingInfo = function() return CastingInfo() end
	WM.ChannelInfo = function() return ChannelInfo() end
end

--------------------------------------------------------------------------------
-- Friends list (Social.lua)
-- On 1.15 the friends list lives on C_FriendList (the classic_era
-- FriendsFrame.lua calls C_FriendList.GetFriendInfoByIndex / AddFriend /
-- ShowFriends exclusively); pre-C_FriendList classic builds keep the flat
-- globals. GetInfo normalizes both to:
--   name, level, className (localized), area, connected
--------------------------------------------------------------------------------

local Friends = {}
WM.Friends = Friends

if C_FriendList and C_FriendList.GetNumFriends then
	Friends.Num = function() return C_FriendList.GetNumFriends() or 0 end
	Friends.GetInfo = function(i)
		local info = C_FriendList.GetFriendInfoByIndex(i)
		if not info or not info.name then return nil end
		return info.name, info.level or 0, info.className, info.area,
			info.connected and true or false
	end
	Friends.Add = function(name) C_FriendList.AddFriend(name) end
	Friends.Remove = function(name) C_FriendList.RemoveFriend(name) end
	Friends.Request = function() C_FriendList.ShowFriends() end
else
	Friends.Num = function() return GetNumFriends() or 0 end
	Friends.GetInfo = function(i)
		local name, level, class, area, connected = GetFriendInfo(i)
		if not name then return nil end
		return name, level or 0, class, area, connected and true or false
	end
	Friends.Add = function(name) AddFriend(name) end
	Friends.Remove = function(name) RemoveFriend(name) end
	Friends.Request = function() ShowFriends() end
end

--------------------------------------------------------------------------------
-- Guild roster (Social.lua)
-- The roster request moved to C_GuildInfo.GuildRoster on 1.15 (the bare
-- GuildRoster global is gone from the client; classic_era FriendsFrame.lua
-- calls the C_ form). Promote/Demote/Uninvite exist BOTH ways on 1.15 —
-- C_GuildInfo natively, plus the Blizzard_DeprecatedGuildScript shims
-- (GuildPromote = C_GuildInfo.Promote, ...) — so the C_ form is preferred and
-- the globals are the fallback for older builds. Same for the MOTD getter
-- (GetGuildRosterMOTD = C_GuildInfo.GetMOTD in the shim). The permission
-- predicates (CanGuildInvite/Promote/Demote/Remove) and the roster getters
-- (GetNumGuildMembers, GetGuildRosterInfo, Get/SetGuildRosterShowOffline)
-- are still plain globals on 1.15, so those need no wrapper.
--------------------------------------------------------------------------------

do
	local request = (C_GuildInfo and C_GuildInfo.GuildRoster) or GuildRoster
	WM.GuildRosterRequest = request and function() request() end or function() end

	local promote = (C_GuildInfo and C_GuildInfo.Promote) or GuildPromote
	WM.GuildPromote = promote and function(name) promote(name) end or function() end

	local demote = (C_GuildInfo and C_GuildInfo.Demote) or GuildDemote
	WM.GuildDemote = demote and function(name) demote(name) end or function() end

	local uninvite = (C_GuildInfo and C_GuildInfo.Uninvite) or GuildUninvite
	WM.GuildRemove = uninvite and function(name) uninvite(name) end or function() end

	local motd = GetGuildRosterMOTD or (C_GuildInfo and C_GuildInfo.GetMOTD)
	WM.GuildMOTD = motd and function() return motd() or "" end or function() return "" end
end

--------------------------------------------------------------------------------
-- Whisper pre-fill + group invite (Social.lua / Raid.lua)
-- SendTell opens the (rescued, Chat.lua) edit box pre-filled with "/w name":
-- on 1.15 it lives on ChatFrameUtil (classic_era ChatFrameUtil.lua), with the
-- ChatFrame_SendTell global kept as a Blizzard_DeprecatedChatInfo alias —
-- prefer the native home, fall back through the alias to a raw OpenChat.
-- Group invites moved to C_PartyInfo.InviteUnit on 1.15 (InviteUnit global is
-- the deprecated alias).
--------------------------------------------------------------------------------

if ChatFrameUtil and ChatFrameUtil.SendTell then
	WM.WhisperTo = function(name) ChatFrameUtil.SendTell(name) end
elseif ChatFrame_SendTell then
	WM.WhisperTo = function(name) ChatFrame_SendTell(name) end
elseif ChatFrame_OpenChat then
	WM.WhisperTo = function(name) ChatFrame_OpenChat("/w " .. name .. " ") end
else
	WM.WhisperTo = function() end
end

do
	local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
	WM.InviteToGroup = invite and function(name) invite(name) end or function() end
end

--------------------------------------------------------------------------------
-- Ready check (Raid.lua)
-- On 1.15 both live on C_PartyInfo (classic_era ReadyCheck.xml calls
-- C_PartyInfo.ConfirmReadyCheck(true/false) directly; DoReadyCheck /
-- ConfirmReadyCheck globals are Blizzard_DeprecatedPartyInfo shims onto the
-- same C_ functions). Prefer the native home, keep the globals as fallback.
--------------------------------------------------------------------------------

do
	local confirm = (C_PartyInfo and C_PartyInfo.ConfirmReadyCheck) or ConfirmReadyCheck
	WM.ConfirmReadyCheck = confirm and function(ready) confirm(ready) end or function() end

	local start = (C_PartyInfo and C_PartyInfo.DoReadyCheck) or DoReadyCheck
	WM.DoReadyCheck = start and function() start() end or function() end
end

--------------------------------------------------------------------------------
-- Watched faction (CharacterPanel.lua's Rep tab)
-- Classic Era 1.15 keeps the vanilla-shaped global: the classic_era
-- Vanilla/ReputationFrame.xml calls SetWatchedFactionIndex(index) and
-- SetWatchedFactionIndex(0) to clear. Newer lineages renamed it to
-- C_Reputation.SetWatchedFactionByIndex. WM.SetWatchedFaction is nil when
-- neither exists — the Rep tab then renders without the watch toggle
-- (watch-toggle only where the platform supports it).
--------------------------------------------------------------------------------

if SetWatchedFactionIndex then
	WM.SetWatchedFaction = function(index) SetWatchedFactionIndex(index or 0) end
elseif C_Reputation and C_Reputation.SetWatchedFactionByIndex then
	WM.SetWatchedFaction = function(index) C_Reputation.SetWatchedFactionByIndex(index or 0) end
end
