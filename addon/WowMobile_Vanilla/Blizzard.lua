--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Blizzard
-- Hides/neuters every default UI element this addon replaces, and re-fits the
-- Blizzard frames that stay (party frames, game menu, taxi window, static
-- popups). Banished frames are reparented under a hidden frame
-- (WM.BanishFrame); most frames named below exist in 1.12 FrameXML at init.
-- The LoD exceptions on this client — AuctionFrame (Blizzard_AuctionUI),
-- TradeSkillFrame (Blizzard_TradeSkillUI), CraftFrame (Blizzard_CraftUI),
-- ClassTrainerFrame (Blizzard_TrainerUI), MacroFrame (Blizzard_MacroUI),
-- KeyBindingFrame (Blizzard_BindingUI) — are handled by dropping their
-- UIParent show events and/or via the shared ADDON_LOADED dispatch below.
--
-- Deliberately NOT touched:
--   * ChatFrame1..N — Chat.lua owns those (the edit box must survive),
--   * WorldMapFrame — WorldMap.lua reflows it instead of hiding it,
--   * TalentFrame — Talents.lua reflows it on demand (LoD Blizzard_TalentUI
--     on 1.12, loaded by ToggleTalentFrame's TalentFrame_LoadUI();
--     Talents.lua owns its own ADDON_LOADED install),
--   * GameTooltip / UIErrorsFrame — re-anchored, still Blizzard-driven.
--------------------------------------------------------------------------------

local WM = WowMobile

-- PartyMemberFrame is 120x53 UI UNITS, not px: at ~2.5 physical px per UI
-- unit that is already ~300x133 px unscaled. 0.9 yields ~270x119 px frames —
-- inside the ~120-145 px touch band. This is the scale CEILING: the re-home
-- below shrinks it further when a reduced viewport.height can't fit the full
-- chain.
local PARTY_SCALE = 0.9

-- 1.12 handlers run with `this` set for the whole invocation, so calling the
-- original inside the wrapper keeps its `this` reads working — the standard
-- vanilla OnShow-hook pattern.
local function HookOnShow(frame, fn)
	if not frame then return end
	local orig = frame:GetScript("OnShow")
	frame:SetScript("OnShow", function()
		if orig then orig() end
		fn(this)
	end)
end

WM.OnInit(function()
	-- Unit frames replaced by UnitFrames.lua / Pet.lua.
	WM.BanishFrame(PlayerFrame)
	WM.BanishFrame(TargetFrame)
	WM.BanishFrame(PetFrame)

	-- Action bar art + the bars whose slots we re-expose on our own buttons.
	-- MainMenuBar drags most of its children (XP bar, bag buttons, micro
	-- menu, backpack, BonusActionBarFrame) down with it.
	WM.BanishFrame(MainMenuBar)
	WM.BanishFrame(MultiBarBottomLeft)
	WM.BanishFrame(MultiBarBottomRight)
	WM.BanishFrame(MultiBarLeft)
	WM.BanishFrame(MultiBarRight)
	WM.BanishFrame(PetActionBarFrame)     -- replaced by Pet.lua's action block
	WM.BanishFrame(ShapeshiftBarFrame)    -- 1.12 name for the stance bar

	-- HUD pieces replaced by Auras.lua / CastBar.lua / Minimap.lua.
	WM.BanishFrame(BuffFrame)
	WM.BanishFrame(TemporaryEnchantFrame)
	WM.BanishFrame(CastingBarFrame)
	WM.BanishFrame(MinimapCluster, true) -- keep events: Minimap.lua reparents the map itself out of it
	WM.BanishFrame(DurabilityFrame)      -- durability lives in the character panel

	-- NPC interaction frames replaced by BottomSheet.lua. Unregistering their
	-- events is what actually stops them from popping up on GOSSIP_SHOW /
	-- MERCHANT_SHOW etc. — each frame registers its own show event in OnLoad.
	WM.BanishFrame(GossipFrame)
	WM.BanishFrame(QuestFrame)
	WM.BanishFrame(MerchantFrame)
	-- The class trainer UI is NOT plain FrameXML on 1.12 — FrameXML.toc loads
	-- only ClassTrainerFrameTemplates.xml; ClassTrainerFrame itself lives in
	-- the LoD addon Blizzard_TrainerUI, loaded by UIParent's TRAINER_SHOW
	-- handler. Suppression therefore works like the AH: drop UIParent's
	-- show/close events (below, with the others) so the LoD addon never even
	-- loads, banish a frame that a pre-login force-load already created, and
	-- let the ADDON_LOADED handler (bottom of this file) banish it if some
	-- other addon force-loads Blizzard_TrainerUI later — its OnHide calls
	-- CloseTrainer, the usual session-killing hazard.
	if ClassTrainerFrame then
		WM.BanishFrame(ClassTrainerFrame)
	end

	-- Loot: LootSheet.lua rebuilds looting in the deck. The unregister-events
	-- banish matters doubly here — LootFrame's OnHide handler calls
	-- CloseLoot(), so a merely-hidden LootFrame that Blizzard code Show()s
	-- and re-Hide()s would kill the loot session server-side; with its
	-- events gone it never shows at all. Unregistering also drops its
	-- OPEN_MASTER_LOOT_LIST / UPDATE_MASTER_LOOT_LIST handling (the
	-- GroupLootDropDown) — LootSheet.lua re-implements master-loot
	-- assignment with its own touch candidate picker. (This frame previously
	-- went through FitPanelToSquare below; the sheet replaces that boost.)
	WM.BanishFrame(LootFrame)
	-- Group need/greed rolls: RollFrames.lua replaces GroupLootFrame1..4.
	-- On the 1.12 client the frames themselves only register CANCEL_LOOT_ROLL
	-- in GroupLootFrame_OnLoad; START_LOOT_ROLL is registered and handled by
	-- UIParent.lua, whose handler calls GroupLootFrame_OpenNewFrame(arg1,
	-- arg2) directly — so the banish's UnregisterAllEvents alone would not
	-- stop new rolls from being driven into the (hidden) frames. Unregister
	-- START_LOOT_ROLL on UIParent too (safe: RollFrames.lua listens on the
	-- addon dispatcher, and nothing else in 1.12 UIParent_OnEvent keys off
	-- it); the reparent under WM.Hider then keeps the frames invisible even
	-- if some other code Show()s them.
	UIParent:UnregisterEvent("START_LOOT_ROLL")
	for i = 1, NUM_GROUP_LOOT_FRAMES or 4 do
		WM.BanishFrame(getglobal("GroupLootFrame" .. i))
	end

	-- Party frames stay Blizzard's, but at mouse scale/position they'd sit at
	-- the square's top-left under the aura rows. Re-home them on the right
	-- edge, scaled to touch size: below the minimap cluster (top at y=330,
	-- right edge x=960 — the ranges the budget table in Minimap.lua reserves,
	-- left of the quick-bar column at x>=976). Only PartyMemberFrame1 needs
	-- re-anchoring — 2..4 chain-anchor to it in 1.12's XML — but every frame
	-- needs its own SetScale (scale does not travel via anchors).
	--
	-- y-budget: each member's vertical pitch is <=80 UI units -> 200 px at
	-- scale 1.0, so a full party chained from y=330 ends by 330 + 800*scale.
	-- The square height is configurable (Config bounds 648..~1130), so the
	-- scale is solved per height: scale = (height - 336) / 800, capped at
	-- PARTY_SCALE. 1.12 has no UIParent frame-position manager, so the anchor
	-- sticks once set.
	local function ReflowParty(heightPx)
		local first = PartyMemberFrame1
		if not first then return end
		local scale = (heightPx - 336) / 800
		if scale > PARTY_SCALE then scale = PARTY_SCALE end
		if scale < 0.1 then scale = 0.1 end -- guards a hand-edited SavedVariables height
		for i = 1, MAX_PARTY_MEMBERS or 4 do
			local f = getglobal("PartyMemberFrame" .. i)
			if f then
				f:SetScale(scale)
			end
		end
		first:ClearAllPoints()
		-- SetPoint offsets are in the frame's own (scaled) space; divide so
		-- the offsets stay 120/330 physical px at every scale.
		first:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT",
			-WM.Px(120) / scale, -WM.Px(330) / scale)
	end
	WM.Viewport.OnApply(ReflowParty)
	-- This OnInit runs before Viewport's (toc order), i.e. before the first
	-- Apply — do the initial re-home directly.
	ReflowParty(WM.Viewport.HeightPx())

	-- The client edge rail's Esc opens GameMenuFrame (Logout/Quit flows we do
	-- not rebuild). Scale it to thumb size and center it in the world square;
	-- ToggleGameMenu only Show()s the frame, so a one-time anchor sticks.
	GameMenuFrame:SetScale(1.8)
	GameMenuFrame:ClearAllPoints()
	GameMenuFrame:SetPoint("CENTER", WM.WorldSquare, "CENTER", 0, 0)

	-- Economy frames replaced by deck rebuilds (round 2): Bank.lua, Mail.lua,
	-- Trade.lua, AuctionHouse.lua, Crafting.lua. Same unregister-events banish
	-- as the NPC frames — and it matters doubly for every one of these, the
	-- LootFrame rationale: each frame's OnHide ends the server interaction
	-- (CloseBankFrame / CloseMail / CloseTrade / CloseTradeSkill / CloseCraft),
	-- so a merely-hidden frame that Blizzard code Show()s and re-Hide()s would
	-- kill the session mid-use. With their events unregistered they never show
	-- at all. (Bank/mail/trade previously went through FitPanelToSquare below;
	-- the rebuilds replace that boost.)
	WM.BanishFrame(BankFrame)
	WM.BanishFrame(MailFrame)     -- drags InboxFrame/SendMailFrame down with it
	WM.BanishFrame(OpenMailFrame) -- the letter-reading panel is its own UIPanel
	WM.BanishFrame(TradeFrame)
	-- TradeSkillFrame and CraftFrame are NOT core FrameXML on 1.12: the
	-- client ships Blizzard_TradeSkillUI and Blizzard_CraftUI as LoadOnDemand
	-- (Interface 11200 tocs), loaded by UIParent's TRADE_SKILL_SHOW /
	-- CRAFT_SHOW handlers. The load-bearing suppression is dropping those
	-- events off UIParent (below); these direct banishes only catch a
	-- pre-login force-load, and the ADDON_LOADED handler at the bottom of
	-- this file covers force-loads after login — each frame's OnHide calls
	-- CloseTradeSkill / CloseCraft, the usual session-killing hazard.
	if TradeSkillFrame then
		WM.BanishFrame(TradeSkillFrame)
	end
	if CraftFrame then
		WM.BanishFrame(CraftFrame)
	end
	-- Round-3 rebuild targets, same OnHide hazard as the frames above:
	-- PetStableFrame's OnHide calls ClosePetStables (Stable.lua rebuilds the
	-- stable) and ItemTextFrame's calls CloseItemText (Reader.lua rebuilds
	-- reading), so both get the unregister-events banish.
	WM.BanishFrame(PetStableFrame)
	WM.BanishFrame(ItemTextFrame)
	-- Some of these windows are shown by UIParent's own OnEvent rather than
	-- (only) by the frames' handlers; drop those show paths too, the
	-- START_LOOT_ROLL technique above. UnregisterEvent on an event UIParent
	-- never registered is a harmless no-op, so the whole set goes belt-and-
	-- braces. AUCTION_HOUSE_SHOW is the load-bearing one: the 1.12 AH UI is
	-- the LoD addon Blizzard_AuctionUI, loaded by UIParent's handler
	-- (AuctionFrame_LoadUI) — with the event dropped the default AH UI never
	-- even loads, and AuctionHouse.lua drives the AH purely through the C API.
	UIParent:UnregisterEvent("AUCTION_HOUSE_SHOW")
	UIParent:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	UIParent:UnregisterEvent("TRADE_SHOW")
	UIParent:UnregisterEvent("BANKFRAME_OPENED")
	UIParent:UnregisterEvent("MAIL_SHOW")
	UIParent:UnregisterEvent("TRADE_SKILL_SHOW")
	UIParent:UnregisterEvent("CRAFT_SHOW")
	UIParent:UnregisterEvent("PET_STABLE_SHOW")
	UIParent:UnregisterEvent("TRAINER_SHOW")
	UIParent:UnregisterEvent("TRAINER_CLOSED")
	-- READY_CHECK's default answer UI on 1.12 is ReadyCheckFrame (in the LoD
	-- addon Blizzard_RaidUI, NOT a StaticPopup), shown by UIParent's
	-- READY_CHECK handler calling ShowReadyCheck() with no arguments;
	-- Raid.lua renders its own fullscreen answer overlay, so the event is
	-- dropped from UIParent exactly like START_LOOT_ROLL above (harmless
	-- no-op if this build never registered it).
	UIParent:UnregisterEvent("READY_CHECK")
	-- If another addon force-loads Blizzard_AuctionUI anyway, banish its
	-- frame (its OnHide calls CloseAuctionHouse — same hazard). Two paths:
	-- a force-load during the load screen already happened (ADDON_LOADED
	-- fired before PLAYER_LOGIN, i.e. before this handler existed), so catch
	-- an AuctionFrame that exists right now; the shared ADDON_LOADED handler
	-- at the bottom of this file covers force-loads after login.
	if AuctionFrame then
		WM.BanishFrame(AuctionFrame)
	end

	-- Mouse-scale Blizzard windows that keep driving frequent flows (flight
	-- paths): boost them toward touch size and center them in the world
	-- square. All are UIPanels and 1.12's ShowUIPanel re-anchors a UIPanel to
	-- the screen edge on every open, so the fit runs from an OnShow hook
	-- instead of once at init.
	local PANEL_SCALE = 1.75
	local function FitPanelToSquare(frame)
		if not frame then return end
		HookOnShow(frame, function(f)
			-- Cap the boost so wide classic panels (TaxiFrame is 512 UI
			-- units) never overflow the square. GetWidth/GetHeight return
			-- unscaled sizes, so the cap is stable across re-shows.
			local scale = math.min(PANEL_SCALE,
				WM.WorldSquare:GetWidth() / f:GetWidth(),
				WM.WorldSquare:GetHeight() / f:GetHeight())
			f:SetScale(scale)
			f:ClearAllPoints()
			f:SetPoint("CENTER", WM.WorldSquare, "CENTER", 0, 0)
		end)
	end
	FitPanelToSquare(TaxiFrame)

	-- Round-3 decision: the following Blizzard windows stay BOOSTED-ONLY, not
	-- rebuilt in the deck. Each drives a rare, stateful flow whose logic
	-- (multi-step server round-trips, text-entry popups, drag/paint
	-- interactions) gains little from a rebuild and risks much, and the
	-- capped 1.75x fit already lifts their standard ~22-unit buttons past the
	-- 90 px touch floor (22 units x ~2.5 px/unit x 1.75 ~= 96 px):
	--   * PetitionFrame — guild/charter signing: a handful of full-size
	--     Sign/Request buttons, used once per guild ever.
	--   * TabardFrame — the tabard designer: five arrow-stepper pairs +
	--     Accept/Cancel around a live model preview we could not reproduce;
	--     its small arrows are the one sub-90px case, hit-rect-padded below.
	--   * WorldStateScoreFrame — the BG scoreboard is read-only rows; only
	--     its close affordance is ever tapped.
	--   * MacroFrame / KeyBindingFrame — keyboard-centric editors that assume
	--     a physical keyboard anyway; boosted for occasional touch-ups (the
	--     binding list's per-row buttons stay mouse-sized — padding them
	--     without overlap needs a re-layout, not a trivial inset — accepted).
	--     Both are LoD on 1.12 (Blizzard_MacroUI / Blizzard_BindingUI, loaded
	--     via UIParent's MacroFrame_LoadUI / KeyBindingFrame_LoadUI from the
	--     game menu), so their globals are nil here — the fit hooks are
	--     attached from the shared ADDON_LOADED handler below instead.
	--   * GuildRegistrarFrame — the guild-charter purchase panel (guild
	--     master's gossip option): a name edit box plus Purchase/Cancel/
	--     Goodbye buttons (hit-rect padded below), used once per guild ever.
	--     A default-anchored UIPanel that would otherwise open at the
	--     window's LEFT edge, outside the landscape band crop.
	--   * OptionsFrame / SoundOptionsFrame / UIOptionsFrame — the GameMenu
	--     options screens; visited rarely, and their checkbox rows work at
	--     the boosted scale.
	FitPanelToSquare(PetitionFrame)
	FitPanelToSquare(TabardFrame)
	FitPanelToSquare(WorldStateScoreFrame)
	FitPanelToSquare(GuildRegistrarFrame)
	FitPanelToSquare(OptionsFrame)
	FitPanelToSquare(SoundOptionsFrame)
	FitPanelToSquare(UIOptionsFrame)

	-- Thumb-safe pads on the guild registrar's three flow buttons (the
	-- TaxiButton technique; static frame on 1.12, so a one-time pad sticks).
	for _, name in next, {
		"GuildRegistrarFramePurchaseButton", "GuildRegistrarFrameCancelButton",
		"GuildRegistrarFrameGoodbyeButton",
	} do
		local b = getglobal(name)
		if b and b.SetHitRectInsets then
			b:SetHitRectInsets(-12, -12, -12, -12)
		end
	end

	-- The tabard designer's arrow steppers are 32x32 UI units, which the
	-- boosted fit already lifts past the touch floor (32 x ~2.5 px/unit x
	-- 1.75 ~= 140 physical px) — no negative padding needed for size. The
	-- real hazard is the opposite: the five rows sit on a 25-unit vertical
	-- pitch, so the native 32-unit buttons already OVERLAP siblings by 7
	-- units, an ambiguous equal-strata/level hit-test band (the unspecified
	-- z-order hazard documented in RollFrames.lua / Core.lua). So the insets
	-- go both ways: widen horizontally (-14 each side, no horizontal
	-- neighbor) but SHRINK vertically (+4 top/bottom -> 24-unit-tall hit
	-- rect, under the 25-unit pitch) so every tap lands on exactly one row.
	-- The 1.12 XML names the five customization rows
	-- TabardFrameCustomization1..5 (template children $parentLeftButton /
	-- $parentRightButton -> TabardFrameCustomization1LeftButton, ...);
	-- TabardCharacterCustomization* is the later-era spelling, tried second
	-- for renamed cores. Nil-guarded so an unmatched build just skips.
	if TabardFrame then
		local sides = { "LeftButton", "RightButton" }
		HookOnShow(TabardFrame, function()
			for i = 1, 5 do
				for s = 1, 2 do
					local b = getglobal("TabardFrameCustomization" .. i .. sides[s])
						or getglobal("TabardCharacterCustomization" .. i .. sides[s])
					if b and b.SetHitRectInsets then
						b:SetHitRectInsets(-14, -14, 4, 4)
					end
				end
			end
		end)
	end

	-- Shared ADDON_LOADED dispatch for the LoD Blizzard addons this file
	-- cares about (defined after FitPanelToSquare so the closure can reach
	-- it): banish the session-killing frames when some other addon
	-- force-loads their UI after login — each frame registers its own show
	-- events in OnLoad, and its OnHide ends the server session (CloseAuctionHouse
	-- / CloseTradeSkill / CloseCraft / CloseTrainer), the hazard described at
	-- each banish site above — and attach the touch fit to the LoD editors
	-- (Macro / KeyBinding) once their frames actually exist.
	WM.On("ADDON_LOADED", function(_, addonName)
		if addonName == "Blizzard_AuctionUI" then
			WM.BanishFrame(AuctionFrame)
		elseif addonName == "Blizzard_TradeSkillUI" then
			WM.BanishFrame(TradeSkillFrame)
		elseif addonName == "Blizzard_CraftUI" then
			WM.BanishFrame(CraftFrame)
		elseif addonName == "Blizzard_TrainerUI" then
			WM.BanishFrame(ClassTrainerFrame)
		elseif addonName == "Blizzard_MacroUI" then
			FitPanelToSquare(MacroFrame)
		elseif addonName == "Blizzard_BindingUI" then
			FitPanelToSquare(KeyBindingFrame)
		end
	end)

	-- Taxi node buttons are 16x16 UI units (~40 physical px) and the 512-unit
	-- TaxiFrame hits the width cap above, so the fit alone can't rescue them.
	-- Their art can't grow without drowning the route map, but the tappable
	-- area can: negative hit-rect insets pad every node toward ~100 physical
	-- px. Padded after Blizzard's TAXIMAP_OPENED handler has run (it
	-- registered at load, so it dispatches before ours) because the
	-- "TaxiButton"..i frames are created lazily per map.
	WM.On("TAXIMAP_OPENED", function()
		for i = 1, NumTaxiNodes() do
			local node = getglobal("TaxiButton" .. i)
			if node and node.SetHitRectInsets then
				node:SetHitRectInsets(-16, -16, -16, -16)
			end
		end
	end)

	-- StaticPopup confirmations (release spirit, resurrect, BoP loot, ...)
	-- keep Blizzard's dialog logic but get the same touch boost. SetScale is
	-- one-time (nothing in 1.12 StaticPopup.lua ever resets scale); the
	-- chain-head anchor is re-asserted after every StaticPopup_Show so it
	-- holds regardless of how this client build anchors dialog 1 internally
	-- (dialogs 2..4 anchor to the one above them and follow the head). Plain
	-- global wrap — no hooksecurefunc on 1.12, and nothing here is protected.
	local POPUP_SCALE = 1.75
	for i = 1, STATICPOPUP_NUMDIALOGS or 4 do
		local p = getglobal("StaticPopup" .. i)
		if p then
			p:SetScale(math.min(POPUP_SCALE, WM.WorldSquare:GetWidth() / p:GetWidth()))
		end
	end
	local function RehomePopupHead()
		local head = StaticPopup1
		if head and head:IsShown() then
			-- Near the square's top, clear of the aura rows; SetPoint offsets
			-- are in the popup's scaled space, hence the divide.
			head:ClearAllPoints()
			head:SetPoint("TOP", WM.WorldSquare, "TOP", 0, -WM.Px(230) / head:GetScale())
		end
	end
	local origStaticPopupShow = StaticPopup_Show
	StaticPopup_Show = function(which, text_arg1, text_arg2, data)
		local dialog = origStaticPopupShow(which, text_arg1, text_arg2, data)
		RehomePopupHead()
		return dialog
	end
	RehomePopupHead()
end)
