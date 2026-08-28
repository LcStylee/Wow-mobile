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
