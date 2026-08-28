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

-- PartyMemberFrame is 120x53 UI UNITS, not px: at ~2.5 physical px per UI
-- unit (1080 px window / ~432-unit UIParent at the addon's uiScale) that is
-- already ~300x133 px unscaled. 0.9 yields ~270x119 px frames — inside the
-- ~120-145 px touch band. This is the scale CEILING: the re-home below
-- shrinks it further when a reduced viewport.height can't fit the full chain
-- (arithmetic at the re-home).
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
	-- LOOT_BIND_CONFIRM popup).
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
	-- column at x>=976). Only PartyMemberFrame1
	-- needs re-anchoring — 2..4 chain-anchor to it in Blizzard's XML — but
	-- every frame needs its own SetScale (scale does not travel via anchors).
	--
	-- y-budget (physical px from the square's top, at 2.5 px/UI-unit): each
	-- member's vertical pitch is <=80 UI units (53-unit frame + the <=27-unit
	-- chain gap that holds the pet frame) -> 80 * 2.5 = 200 px at scale 1.0,
	-- so a full party chained from y=330 ends by 330 + 4*200*scale px, pet
	-- frames included. The square's height is configurable (viewport.height,
	-- Config bounds 648..~1130), so the scale is solved per height:
	-- 330 + 800*scale <= height - 6  =>  scale = (height - 336) / 800, capped
	-- at PARTY_SCALE. Default 1080 -> 0.93 -> capped 0.9 (chain ends 1050,
	-- matching the budget table in Minimap.lua); the 648 floor -> 0.39 (chain
	-- ends 642). Either way the secure unit buttons never overhang the control
	-- deck and steal its taps. Registered as a Viewport reflower so /wm
	-- viewport re-solves it; the reflow closure is guaranteed out of combat.
	local function ReflowParty(heightPx)
		local first = PartyMemberFrame1
		if not first then return end
		local scale = (heightPx - 336) / 800
		if scale > PARTY_SCALE then scale = PARTY_SCALE end
		-- Unreachable through Config (bounds floor 648 -> 0.39); guards a
		-- hand-edited SavedVariables height, where SetScale(<=0) would error.
		if scale < 0.1 then scale = 0.1 end
		for i = 1, MAX_PARTY_MEMBERS or 4 do
			local f = _G["PartyMemberFrame" .. i]
			if f then
				f:SetScale(scale)
				f.ignoreFramePositionManager = true -- keep any manager pass off our anchor
			end
		end
		first:ClearAllPoints()
		-- SetPoint offsets are in the frame's own (scaled) space; divide
		-- so the offsets stay 120/330 physical px (right edge fixed at x=960,
		-- left of the quick-bar column, at every scale).
		first:SetPoint("TOPRIGHT", WM.WorldSquare, "TOPRIGHT",
			-WM.Px(120) / scale, -WM.Px(330) / scale)
	end
	WM.Viewport.OnApply(ReflowParty)
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

	-- Mouse-scale Blizzard windows that keep driving frequent flows (flight
	-- paths, bank, mail, trade): boost them toward touch size and center them
	-- in the world square. All four are insecure frames, so SetScale/SetPoint
	-- are legal even in combat — no lockdown queue needed. Their item buttons
	-- also place a MoveMode-carried item through their own insecure click
	-- handlers, so cursor-carry works into the bank/mail/trade windows for
	-- free. They are UIPanels, and ShowUIPanel
	-- re-anchors a UIPanel to the screen edge on every open, so the fit runs
	-- from an OnShow hook instead of once at init.
	-- Boost mouse-scale panels toward touch size (same factor as POPUP_SCALE
	-- below). The party frames reach touch size at PARTY_SCALE = 0.9 because
	-- they are natively larger (120x53 UI units).
	local PANEL_SCALE = 1.75
	local function FitPanelToSquare(frame)
		if not frame then return end
		frame:HookScript("OnShow", function(f)
			-- Cap the boost so the wide classic panels (Bank/Mail/Trade are
			-- ~384 UI units on a 432-unit-wide portrait window; TaxiFrame is
			-- 512) never overflow the square. GetWidth/GetHeight return
			-- unscaled sizes, so the cap is stable across re-shows.
			local scale = math.min(PANEL_SCALE,
				WM.WorldSquare:GetWidth() / f:GetWidth(),
				WM.WorldSquare:GetHeight() / f:GetHeight())
			f:SetScale(scale)
			f:ClearAllPoints()
			f:SetPoint("CENTER", WM.WorldSquare, "CENTER", 0, 0)
		end)
	end
	FitPanelToSquare(BankFrame)
	FitPanelToSquare(MailFrame)
	FitPanelToSquare(TradeFrame)
	FitPanelToSquare(TaxiFrame)

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
	end
end)
