--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Talents
-- Touch access to talents (a point to spend every level from 10). The talent
-- tree's rank buttons and learn confirmations are Blizzard flows we must not
-- rebuild, so the frame is scaled up into the world square (the tall tree
-- needs the square's full 1080 px height to reach tappable icon sizes; the
-- ~840 px deck cannot give that) and given a big close button.
--
-- LoD note (corrected): on 1.12 TalentFrame is NOT plain FrameXML — the
-- client ships AddOns/Blizzard_TalentUI as LoadOnDemand (FrameXML.toc has no
-- Talent file), and UIParent's ToggleTalentFrame calls TalentFrame_LoadUI()
-- before showing. So TalentFrame is nil at PLAYER_LOGIN and the touch chrome
-- installs from ADDON_LOADED ("Blizzard_TalentUI") — same pattern as
-- Blizzard_TrainerUI in Blizzard.lua — with an init-time path only for a
-- pre-login force-load by some other addon. ADDON_LOADED fires synchronously
-- inside TalentFrame_LoadUI, before ShowUIPanel runs, so the OnShow wrap is
-- in place for the very first open.
--------------------------------------------------------------------------------

local WM = WowMobile

local Talents = {}
WM.Talents = Talents

local closeButton

local function Reflow()
	local f = TalentFrame
	if not f then return end
	-- Fit inside the square in both axes; the tree is taller than wide, so
	-- the height ratio usually wins (~2.1x — 32px talent icons become ~67px,
	-- comfortably tappable with the icon spacing around them).
	local scale = math.min(
		WM.WorldSquare:GetWidth() / f:GetWidth(),
		WM.WorldSquare:GetHeight() / f:GetHeight())
	f:SetScale(scale)
	f:ClearAllPoints()
	f:SetPoint("TOP", UIParent, "TOP", 0, 0)
	-- The close button lives inside the scaled frame: compensate so it stays
	-- ~100 physical px.
	closeButton:SetWidth(WM.Px(100) / scale)
	closeButton:SetHeight(WM.Px(88) / scale)
end

function Talents.Toggle()
	-- ToggleTalentFrame is 1.12's canonical open/close path; it runs
	-- TalentFrame_LoadUI() itself, which fires ADDON_LOADED and installs our
	-- chrome (below) before the frame first shows.
	if ToggleTalentFrame then
		ToggleTalentFrame()
	end
end

function Talents.Close()
	local f = TalentFrame
	if f and f:IsShown() then
		HideUIPanel(f)
	end
end

local installed

local function Install()
	local f = TalentFrame
	if not f or installed then return end
	installed = true

	closeButton = WM.CreateTouchButton(f, 100, 88, "X", 44)
	closeButton:SetFrameStrata("FULLSCREEN_DIALOG") -- above every tree overlay
	closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	closeButton:SetScript("OnClick", Talents.Close)

	-- Runs after Blizzard's own UIPanel positioning for the frame, so our
	-- anchors win (manual wrap; no HookScript on 1.12).
	local origOnShow = f:GetScript("OnShow")
	f:SetScript("OnShow", function()
		if origOnShow then origOnShow() end
		WM.Deck.YieldTo("talents")
		Reflow()
	end)

	WM.Deck.RegisterExclusive("talents", Talents.Close)
end

WM.OnInit(function()
	-- Force-load path: some other addon loaded Blizzard_TalentUI during the
	-- load screen (its ADDON_LOADED fired before PLAYER_LOGIN), so the frame
	-- already exists at init.
	Install()
	-- Normal path: the LoD addon loads on the first ToggleTalentFrame tap.
	-- Registered from init (like Blizzard.lua's shared dispatch) so it can
	-- never run before the deck/Px machinery Install depends on is up.
	WM.On("ADDON_LOADED", function(_, addonName)
		if addonName == "Blizzard_TalentUI" then
			Install()
		end
	end)
end)
