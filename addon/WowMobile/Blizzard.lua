--------------------------------------------------------------------------------
-- WowMobile · Blizzard
-- Hides/neuters every default UI element this addon replaces, and re-fits the
-- Blizzard frames that stay (party frames, game menu, taxi/bank/mail/trade
-- windows, static popups). Banished frames are
-- reparented under a hidden frame (WM.BanishFrame) so nothing calls Show/Hide
-- on protected frames later, and every layout touch goes through the
-- combat-lockdown queue.
--
-- Deliberately NOT touched:
--   * ChatFrame1..N — Chat.lua owns those (the edit box must survive),
--   * WorldMapFrame — WorldMap.lua reflows it instead of hiding it,
--   * TalentFrame — Talents.lua reflows Blizzard_TalentUI on demand,
--   * GameTooltip / UIErrorsFrame — re-anchored, still Blizzard-driven.
--------------------------------------------------------------------------------

local _, WM = ...

-- Party-frame scale CEILING: at ~2.5 physical px per UI unit (1080 px window
-- / ~432-unit UIParent at the addon's uiScale) the member frames land in the
-- ~120-145 px touch band at 0.9. The re-home below shrinks further when a
-- reduced viewport.height can't fit the full stack (arithmetic at the
-- re-home).
local PARTY_SCALE = 0.9

WM.OnInit(function()
	-- Unit frames: unregistering events first stops their protected OnEvent
	-- handlers from running insecurely-touched paths (the standard
	-- taint-avoidance pattern for replacing default unit frames).
	WM.BanishFrame(PlayerFrame)
	WM.BanishFrame(TargetFrame)
	WM.BanishFrame(PetFrame) -- replaced by Pet.lua's status strip

	-- Action bar art + the bars whose slots we re-expose on our own secure
	-- buttons. MainMenuBar drags most of its children (XP bar, bag buttons,
	-- micro menu, backpack) down with it.
	WM.BanishFrame(MainMenuBar)
	WM.BanishFrame(MultiBarBottomLeft)
	WM.BanishFrame(MultiBarBottomRight)
	WM.BanishFrame(MultiBarLeft)
	WM.BanishFrame(MultiBarRight)
	WM.BanishFrame(PetActionBarFrame) -- replaced by Pet.lua's action block
	-- Stance bar name differs across Classic builds.
	WM.BanishFrame(_G["StanceBarFrame"] or _G["ShapeshiftBarFrame"])

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

	-- Looting is rebuilt by LootSheet.lua. The same banish technique matters
	-- doubly here: LootFrame's OnHide calls CloseLoot(), so hiding an OPEN
	-- default frame would end the loot session — with its events unregistered
	-- it simply never opens and that OnHide can never fire mid-loot.
	-- LootSheet.lua takes over the flows the frame drove (auto-loot pass,
	-- LOOT_BIND_CONFIRM popup, master-looter assignment picker).
	WM.BanishFrame(LootFrame)
	-- Group-loot roll popups are replaced by RollFrames.lua. The container
	-- keeps its events (UIParent-side code may still route rolls into it);
	-- parked under the hidden parent, anything it shows stays invisible.
	if GroupLootContainer then
		WM.BanishFrame(GroupLootContainer, true)
	end
	for i = 1, 4 do
		WM.BanishFrame(_G["GroupLootFrame" .. i])
	end

	-- The trainer UI is load-on-demand (Blizzard_TrainerUI), so there is no
	-- frame to banish at login: UIParent's own TRAINER_SHOW handler is what
	-- loads and shows it. Drop that event from UIParent — BottomSheet.lua
	-- consumes TRAINER_SHOW instead. Should the addon get loaded anyway
	-- (another addon forcing it), the ADDON_LOADED hook below banishes it.
	UIParent:UnregisterEvent("TRAINER_SHOW")
	if ClassTrainerFrame then
		WM.BanishFrame(ClassTrainerFrame)
	end

	-- Party frames stay Blizzard's (secure targeting behavior included), but
	-- at mouse scale/position they'd sit at the square's top-left under the
	-- aura rows. Re-home them on the right edge, scaled to touch size: below
	-- the minimap cluster (top at y=330, x right edge 960 — the ranges the
	-- budget table in Minimap.lua reserves for them, left of the quick-bar
	-- column at x>=976).
	--
	-- On the 1.15 client the member frames are anonymous POOLED children of
	-- the PartyFrame container — Blizzard_UnitFrame Shared/PartyFrame.lua
	-- builds them from a CreateFramePool; the vanilla PartyMemberFrame1..4
	-- globals no longer exist — so the CONTAINER is what gets re-homed: one
	-- SetScale/SetPoint on it carries every pooled member (scale and position
	-- propagate to children), and the container itself is insecure — the
	-- secure targeting machinery lives on the member buttons, untouched. The
	-- reflow still rides the out-of-combat queue with the rest of this file's
	-- layout work.
	--
	-- POSITION OWNER (era 1.15): PartyFrame is an EditMode unit-frame system —
	-- classic_era Blizzard_UnitFrame Shared/PartyFrame.xml inherits
	-- EditModeUnitFrameSystemTemplate, and Blizzard_EditMode loads on era
	-- (AllowLoadGameType classic). It is NOT a UIParent-managed frame (absent
	-- from UIPARENT_MANAGED_FRAME_POSITIONS on this client), so the classic
	-- ignoreFramePositionManager flag is a no-op for it. Instead
	-- EditModeManagerFrame re-applies the saved layout's anchor AND scale on
	-- every layout apply (EditModeSystemMixin:ApplySystemAnchor does
	-- ClearAllPoints+SetPoint from systemInfo.anchorInfo; the FrameSize setting
	-- re-applies SetScale) — including the login-time EDIT_MODE_LAYOUTS_UPDATED
	-- (server-sent, lands AFTER this file's PLAYER_LOGIN re-home and Viewport's
	-- PLAYER_ENTERING_WORLD apply), DISPLAY_SIZE_CHANGED, edit-mode enter/exit,
	-- layout switches, and the raid-style-party-frames toggle. A set-once
	-- re-home therefore snaps back to the square's top-left at EditMode's
	-- scale; the hooks after ReflowParty below RE-ASSERT it after every apply.
	--
	-- Caveat: with "Use Raid-Style Party Frames" enabled (era exposes the
	-- EditMode-backed setting) PartyFrameMixin:ShouldShow() hides the pooled
	-- member frames entirely and the party renders on CompactPartyFrame — a
	-- child of PartyFrame created at Blizzard-addon load, NOT part of the
	-- CompactRaidFrameManager/Container pair, so it needs (and gets) its own
	-- banish + re-hide hook below. Raid.lua's no-raid notice branches on
	-- WM.UseRaidStylePartyFrames() (Compat.lua) so those users are told the
	-- setting, not pointed at frames that don't exist.
	--
	-- y-budget (physical px from the square's top, at 2.5 px/UI-unit): the
	-- container's vertical layout spans <=320 UI units for a full party (4
	-- members at <=80 units of pitch each, pet frames included) -> <=800 px at
	-- scale 1.0. The square's height is configurable (viewport.height, Config
	-- bounds 648..~1130), so the scale is solved per height:
	-- 330 + 800*scale <= height - 6  =>  scale = (height - 336) / 800, capped
	-- at PARTY_SCALE. Default 1080 -> 0.93 -> capped 0.9 (stack ends 1050,
	-- matching the budget table in Minimap.lua); the 648 floor -> 0.39 (stack
	-- ends 642). Either way the secure unit buttons never overhang the control
	-- deck and steal its taps. Registered as a Viewport reflower so /wm
	-- viewport re-solves it; the reflow closure is guaranteed out of combat.
	local function ReflowParty(heightPx)
		local pf = PartyFrame
		if not pf then return end
		local scale = (heightPx - 336) / 800
		if scale > PARTY_SCALE then scale = PARTY_SCALE end
		-- Unreachable through Config (bounds floor 648 -> 0.39); guards a
		-- hand-edited SavedVariables height, where SetScale(<=0) would error.
		if scale < 0.1 then scale = 0.1 end
		pf:SetScale(scale)
		-- No ignoreFramePositionManager here: on this client PartyFrame is
		-- EditMode-owned, not UIParent-managed (see POSITION OWNER above) —
		-- persistence comes from the re-assert hooks below, not a flag.
		pf:ClearAllPoints()
		-- SetPoint offsets are in the frame's own (scaled) space; divide
		-- so the offsets stay 120/330 physical px (right edge fixed at x=960,
		-- left of the quick-bar column, at every scale).
		pf:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT",
			-WM.Px(120) / scale, -WM.Px(330) / scale)
		-- The pooled member template ships HitRectInsets (7,85,6,7) that
		-- shrink the tappable area to roughly the portrait (~81x90 physical
		-- px at the 0.9 cap — under the 90 px minimum). Zero them so the
		-- whole 128x53-unit frame takes taps (legal out of combat — this
		-- closure is guaranteed out of combat — same technique as the
		-- TaxiButton padding below). Runs on every reflow, so pool frames
		-- acquired after a roster change get covered by the re-assert hooks.
		if pf.PartyMemberFramePool then
			for f in pf.PartyMemberFramePool:EnumerateActive() do
				f:SetHitRectInsets(0, 0, 0, 0)
			end
		end
	end
	WM.Viewport.OnApply(ReflowParty)
	-- Re-assert after every EditMode layout apply (see POSITION OWNER above):
	-- hooksecurefunc runs after the hooked body, so the re-home lands on top
	-- of EditMode's ClearAllPoints/SetPoint/SetScale within the same apply.
	-- The reflow itself is only SetScale/SetPoint on the insecure container —
	-- neither re-enters UpdateSystem/UpdateLayoutInfo — but the reentrancy
	-- flag keeps that an invariant rather than an accident, and the keyed
	-- OutOfCombat entry coalesces the login burst (UpdateLayoutInfo + the
	-- EDIT_MODE_LAYOUTS_UPDATED event fire together) into one queued reflow
	-- if a layout apply arrives mid-combat.
	local reflowing = false
	local function QueueReflowParty()
		if reflowing then return end
		WM.OutOfCombat("party-rehome", function()
			reflowing = true
			ReflowParty(WM.Viewport.HeightPx())
			reflowing = false
		end)
	end
	if PartyFrame and PartyFrame.UpdateSystem then
		-- Per-system apply: covers every path EditModeSystemMixin funnels
		-- through (anchor + size re-application for this frame alone).
		hooksecurefunc(PartyFrame, "UpdateSystem", QueueReflowParty)
	end
	if EditModeManagerFrame and EditModeManagerFrame.UpdateLayoutInfo then
		-- Whole-layout apply (login, layout switch, edit-mode exit).
		hooksecurefunc(EditModeManagerFrame, "UpdateLayoutInfo", QueueReflowParty)
	end
	-- Server-sent layout push (arrives at/after PLAYER_ENTERING_WORLD, i.e.
	-- after the initial re-home below AND Viewport's first Apply). TryOn: the
	-- event is in the era APIDocumentation, but a build without EditMode must
	-- not error at RegisterEvent.
	WM.TryOn("EDIT_MODE_LAYOUTS_UPDATED", QueueReflowParty)
	-- This OnInit runs before Viewport's (toc order), i.e. before the first
	-- Apply — do the initial re-home directly.
	WM.OutOfCombat(function() ReflowParty(WM.Viewport.HeightPx()) end)

	-- The client edge rail's Esc opens GameMenuFrame (Logout/Quit are
	-- protected flows we must not rebuild). Scale it to thumb size and center
	-- it in the world square; ToggleGameMenu only Show()s the frame, so a
	-- one-time anchor sticks.
	WM.OutOfCombat(function()
		GameMenuFrame:SetScale(1.8)
		GameMenuFrame:ClearAllPoints()
		GameMenuFrame:SetPoint("CENTER", WM.WorldSquare, "CENTER", 0, 0)
	end)

	-- Mouse-scale Blizzard windows that keep driving flows this addon does not
	-- rebuild: boost toward touch size and center in the world square.
	-- Insecure frames, so SetScale/
	-- SetPoint are legal even in combat — no lockdown queue needed. They are
	-- UIPanels, and ShowUIPanel re-anchors a UIPanel to the screen edge on
	-- every open, so the fit runs from an OnShow hook instead of once at init.
	local PANEL_SCALE = 1.75
	local function FitPanelToSquare(frame)
		if not frame then return end
		frame:HookScript("OnShow", function(f)
			-- Cap the boost so wide classic panels (TaxiFrame is 512 UI units
			-- on a 432-unit-wide portrait window) never overflow the square.
			-- GetWidth/GetHeight return unscaled sizes, so the cap is stable
			-- across re-shows.
			local scale = math.min(PANEL_SCALE,
				WM.WorldSquare:GetWidth() / f:GetWidth(),
				WM.WorldSquare:GetHeight() / f:GetHeight())
			f:SetScale(scale)
			f:ClearAllPoints()
			f:SetPoint("CENTER", WM.WorldSquare, "CENTER", 0, 0)
		end)
	end
	WM.FitPanelToSquare = FitPanelToSquare -- ADDON_LOADED hook below fits LoD frames
	FitPanelToSquare(TaxiFrame)

	-- Deliberately boosted-only (NOT rebuilt as touch sheets), each fitted to
	-- the square like TaxiFrame; a rebuild would cost far more than these rare
	-- one-shot flows are worth, and every one keeps working at fit scale:
	--   * PetitionFrame — guild/arena charter signing: a handful of big-ish
	--     UIPanelButtonTemplate buttons drive the whole flow, made thumb-safe
	--     by the hit-rect padding below.
	--   * TabardFrame — the tabard designer is a preview model plus five
	--     left/right cyclers; its tiny 26-unit arrow nubs can't grow without
	--     covering the preview art, so the tappable area grows instead
	--     (hit-rect padding below, the TaxiButton technique).
	--   * WorldStateScoreFrame — the BG scoreboard is read-only rows; nothing
	--     on it needs a touch target beyond its close button, and rebuilding a
	--     40-row stat table adds no play value on a phone.
	--   * SettingsPanel (macro/keybinding panels below likewise) — options,
	--     macros and keybindings are desk-at-the-PC configuration surfaces,
	--     not phone-play flows; the square fit keeps them fully on-screen (the
	--     ~920-unit-wide SettingsPanel would otherwise clip off the 432-unit
	--     portrait window) at the cost of mouse-sized controls. Accepted.
	-- All are static frames on era except Macro/Binding UIs (LoD, fitted from
	-- the ADDON_LOADED hook below). SettingsPanel is not a classic UIPanel but
	-- is insecure and keeps no per-show anchor logic, so the same hook works.
	FitPanelToSquare(_G["PetitionFrame"])
	FitPanelToSquare(_G["TabardFrame"])
	FitPanelToSquare(_G["WorldStateScoreFrame"])
	FitPanelToSquare(_G["SettingsPanel"])

	-- Trivially padded hit rects on the boosted-only frames (the TaxiButton
	-- technique): the frames are static, so a one-time pad at init sticks.
	-- 12 units ≈ 30 physical px of extra tappable ring per side at fit scale.
	for _, name in next, {
		"PetitionFrameSignButton", "PetitionFrameRequestButton",
		"PetitionFrameRenameButton", "PetitionFrameCancelButton",
		"TabardFrameAcceptButton", "TabardFrameCancelButton",
	} do
		local b = _G[name]
		if b then b:SetHitRectInsets(-12, -12, -12, -12) end
	end
	-- The five tabard cyclers' arrow nubs (classic_era TabardFrame.xml:
	-- TabardFrameCustomization1..5 with $parentLeftButton/$parentRightButton).
	for i = 1, 5 do
		for _, side in next, { "LeftButton", "RightButton" } do
			local b = _G["TabardFrameCustomization" .. i .. side]
			if b then b:SetHitRectInsets(-14, -14, -14, -14) end
		end
	end

	-- Readable objects/letters are rebuilt by Reader.lua. Same load-bearing
	-- banish technique as LootFrame: ItemTextFrame's OnHide calls
	-- CloseItemText() (classic_era ItemTextFrame.xml), which would end the
	-- reading session mid-page — events unregistered + hidden parent means it
	-- never opens and that OnHide can never fire.
	WM.BanishFrame(ItemTextFrame)

	-- The hunter stable is rebuilt by Stable.lua. PetStableFrame's OnHide
	-- calls ClosePetStables() AND clears a carried pet off the cursor
	-- (classic_era PetStable.xml), so the same banish rule applies.
	WM.BanishFrame(_G["PetStableFrame"])

	-- The ready-check prompt is rebuilt by Raid.lua as a fullscreen touch
	-- overlay; the default ReadyCheckFrame registers READY_CHECK in OnLoad,
	-- so unregistering (BanishFrame) is what keeps it from popping.
	WM.BanishFrame(_G["ReadyCheckFrame"])

	-- The compact raid frames duplicate Raid.lua's deck grid at mouse scale:
	-- Blizzard_CompactRaidFrames is a default-enabled (non-LoD) addon on 1.15,
	-- so CompactRaidFrameManager exists at login and shows its left-edge flange
	-- whenever you are in a raid — in the portrait window that lands in/near
	-- the client joystick's bottom-left first-touch zone — with the container's
	-- frames shown under default settings. Same banish technique: events
	-- unregistered stops the roster-driven Show paths on both. Per-member
	-- ready-check answers move to the deck raid grid's cell badges (Raid.lua)
	-- since no default raid frame is left to display them.
	WM.BanishFrame(_G["CompactRaidFrameManager"])
	WM.BanishFrame(_G["CompactRaidFrameContainer"])
	-- CompactPartyFrame is NOT part of that pair: it is created at
	-- Blizzard-addon load as a child of PartyFrame (CompactRaidFrameContainer
	-- mixin AddGroup("PARTY")) and carries the "Use Raid-Style Party Frames"
	-- rendering, so without its own banish it would sit at the square's
	-- top-left as live secure unit buttons eating taps. EditMode's apply
	-- path re-Shows it, so re-hide out of combat after every UpdateVisibility.
	local cpf = _G["CompactPartyFrame"]
	if cpf then
		WM.BanishFrame(cpf)
		if cpf.UpdateVisibility then
			hooksecurefunc(cpf, "UpdateVisibility", function()
				WM.OutOfCombat("cpf-rehide", function()
					if cpf:IsShown() then cpf:Hide() end
				end)
			end)
		end
	end

	-- Economy frames replaced by the round-2 touch sheets (Bank.lua / Mail.lua
	-- / Trade.lua). Same banish technique as LootFrame and doubly load-bearing
	-- here: each frame's OnHide ends the live interaction (BankFrame_OnHide →
	-- CloseBankFrame, MailFrame's OnHide path → CloseMail, TradeFrame_OnHide →
	-- CloseTrade — Blizzard_UIPanels_Game in the 1.15 client source), so a
	-- visible default frame being hidden would kill the session the sheet is
	-- serving. Banished (events unregistered + hidden parent) they never
	-- become visible, so those OnHide handlers can never fire. The 10.x-engine
	-- PlayerInteractionFrameManager still runs its showFunc on some of them:
	--   * Banker: showFunc "BankFrame_Open" resolves to nil on era (no such
	--     function in the 1.15 tree), so the manager no-ops.
	--   * MailInfo: showFunc MailFrame_Show is NOT side-effect-free — beyond
	--     ShowUIPanel (harmless against the hidden-parented frame: shown flag
	--     only, no OnShow/OnHide since the frame never becomes visible) it
	--     runs OpenAllBags() — and the default ContainerFrames are NOT
	--     banished (Bags.lua hooks only the toggles), so Blizzard's
	--     mouse-sized bag frames would open under/over the mail sheet on
	--     every mailbox interaction — and it calls CloseMail() whenever
	--     ShowUIPanel left MailFrame's shown flag unset (a panel-refusal edge
	--     that would kill the mail session the sheet is serving). Both side
	--     effects ride one insecure global, so replace it outright: the deck
	--     bags panel supersedes OpenAllBags, Mail.lua issues its own
	--     CheckInbox, and the ShowUIPanel/CloseMail dance has no job left
	--     with MailFrame banished.
	WM.BanishFrame(BankFrame)
	WM.BanishFrame(MailFrame)
	WM.BanishFrame(_G["OpenMailFrame"]) -- separate UIPanel the inbox opens into
	WM.BanishFrame(TradeFrame)
	if MailFrame_Show then
		MailFrame_Show = function() end
	end

	-- The auction house, tradeskill and enchanting UIs are load-on-demand
	-- Blizzard addons (Blizzard_AuctionUI / Blizzard_TradeSkillUI /
	-- Blizzard_CraftUI on era — same trio the classic_era FrameXML ships);
	-- there is no frame to banish at login. UIParent's own handlers for these
	-- events are what load and show them (UIParent.lua: AUCTION_HOUSE_SHOW →
	-- AuctionFrame_LoadUI, TRADE_SKILL_SHOW → TradeSkillFrame_LoadUI,
	-- CRAFT_SHOW → CraftFrame_LoadUI) — drop the events from UIParent, the
	-- TRAINER_SHOW technique; AuctionHouse.lua/Crafting.lua consume them
	-- instead. The matching *_CLOSED/_CLOSE handlers stay registered: with
	-- the UIs never loaded they hit nil-guarded Hide paths and do nothing.
	-- Should another addon force-load one anyway, the ADDON_LOADED hook below
	-- banishes its frame.
	UIParent:UnregisterEvent("AUCTION_HOUSE_SHOW")
	UIParent:UnregisterEvent("TRADE_SKILL_SHOW")
	UIParent:UnregisterEvent("CRAFT_SHOW")
	WM.BanishFrame(_G["AuctionFrame"])
	WM.BanishFrame(_G["TradeSkillFrame"])
	WM.BanishFrame(_G["CraftFrame"])

	-- Taxi node buttons are 16x16 UI units (~40 physical px) and the 512-unit
	-- TaxiFrame hits the width cap above, so the fit alone can't rescue them.
	-- Their art can't grow without drowning the route map, but the tappable
	-- area can: negative hit-rect insets pad every node to 48 units (~100
	-- physical px). Padded after Blizzard's TAXIMAP_OPENED handler has run
	-- (it registered at load, so it dispatches before ours) because the
	-- "TaxiButton"..i frames are created lazily per map.
	WM.On("TAXIMAP_OPENED", function()
		for i = 1, NumTaxiNodes() do
			local node = _G["TaxiButton" .. i]
			if node then
				node:SetHitRectInsets(-16, -16, -16, -16)
			end
		end
	end)

	-- StaticPopup confirmations (release spirit, resurrect, BoP loot, ...)
	-- keep Blizzard's dialog logic but get the same touch boost. The popup
	-- chain is (re)anchored by StaticPopup_SetUpPosition on every show, so
	-- the re-home rides that call rather than fighting it. Classic popups are
	-- ~320 units wide, so the width cap — not POPUP_SCALE — usually wins
	-- (≈1.35 on a 432-unit-wide window → ~70 px buttons, the largest that
	-- fits without overflowing the square).
	local POPUP_SCALE = 1.75
	hooksecurefunc("StaticPopup_SetUpPosition", function()
		local shown = StaticPopup_DisplayedFrames
		if not shown or not shown[1] then return end
		for i = 1, #shown do
			local p = shown[i]
			p:SetScale(math.min(POPUP_SCALE, WM.WorldSquare:GetWidth() / p:GetWidth()))
		end
		-- Only the chain's head needs re-homing — popups 2..n anchor to the
		-- one above. Near the square's top, clear of the aura rows; SetPoint
		-- offsets are in the popup's scaled space, hence the divide.
		local head = shown[1]
		head:ClearAllPoints()
		head:SetPoint("TOP", WM.WorldSquare, "TOP", 0, -WM.Px(230) / head:GetScale())
	end)
end)

WM.On("ADDON_LOADED", function(_, name)
	if name == "Blizzard_TrainerUI" then
		WM.BanishFrame(ClassTrainerFrame)
	elseif name == "Blizzard_AuctionUI" then
		WM.BanishFrame(_G["AuctionFrame"])
	elseif name == "Blizzard_TradeSkillUI" then
		WM.BanishFrame(_G["TradeSkillFrame"])
	elseif name == "Blizzard_CraftUI" then
		WM.BanishFrame(_G["CraftFrame"])
	elseif name == "Blizzard_InspectUI" then
		-- Inspect.lua rebuilds the inspect view. The default InspectFrame's
		-- OnHide calls ClearInspectPlayer() — banished (never visible), that
		-- can't fire and end the inspect session the touch sheet is showing.
		-- InspectFrame_Show (still called by the unit menu's Inspect) keeps
		-- doing the useful part: CanInspect + NotifyInspect, which Inspect.lua
		-- hooks to drive its sheet.
		WM.BanishFrame(_G["InspectFrame"])
	elseif name == "Blizzard_MacroUI" then
		-- Boosted-only, see the FitPanelToSquare block above (LoD frame, so
		-- the fit attaches at load rather than at init). Guarded: another
		-- addon force-loading these BEFORE this addon's init would find the
		-- helper unpublished; the panels then simply stay at mouse scale.
		if WM.FitPanelToSquare then WM.FitPanelToSquare(_G["MacroFrame"]) end
	elseif name == "Blizzard_BindingUI" then
		-- Boosted-only, same rationale.
		if WM.FitPanelToSquare then WM.FitPanelToSquare(_G["KeyBindingFrame"]) end
	end
end)
