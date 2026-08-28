--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Blizzard
-- Hides/neuters every default UI element this addon replaces, and re-fits the
-- Blizzard frames that stay (party frames, game menu, loot/taxi/bank/mail/
-- trade windows, static popups). Banished frames are reparented under a
-- hidden frame (WM.BanishFrame); every frame named below exists in 1.12
-- FrameXML.
--
-- Deliberately NOT touched:
--   * ChatFrame1..N — Chat.lua owns those (the edit box must survive),
--   * WorldMapFrame — WorldMap.lua reflows it instead of hiding it,
--   * TalentFrame — Talents.lua reflows it on demand (FrameXML on 1.12, not
--     a load-on-demand addon),
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
	-- On 1.12 the class trainer UI is plain FrameXML (Blizzard_TrainerUI is a
	-- TBC-era split), so it can be banished directly at init.
	WM.BanishFrame(ClassTrainerFrame)

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

	-- Mouse-scale Blizzard windows that keep driving frequent flows (flight
	-- paths, bank, mail, trade): boost them toward touch size and center them
	-- in the world square. All are UIPanels and 1.12's ShowUIPanel re-anchors
	-- a UIPanel to the screen edge on every open, so the fit runs from an
	-- OnShow hook instead of once at init.
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
	FitPanelToSquare(BankFrame)
	FitPanelToSquare(MailFrame)
	FitPanelToSquare(TradeFrame)
	FitPanelToSquare(TaxiFrame)

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
