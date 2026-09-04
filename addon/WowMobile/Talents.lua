--------------------------------------------------------------------------------
-- WowMobile · Talents
-- Touch access to talents (a point to spend every level from 10). The talent
-- tree lives in the load-on-demand Blizzard_TalentUI — rank buttons and learn
-- confirmations are Blizzard flows we must not rebuild — so the frame is
-- scaled up into the world square (talents are deliberately NOT in
-- ARCHITECTURE §4's deck-panel list: the tall tree needs the square's full
-- 1080 px height to reach tappable icon sizes; the 840 px deck cannot give
-- that) and given a big close button. Opened from the deck menu row (Deck.lua
-- "Talents"); coordinates with the exclusive system so it never stacks with
-- panels / sheet / map.
--------------------------------------------------------------------------------

local _, WM = ...

local Talents = {}
WM.Talents = Talents

local closeButton

local function Reflow()
	local f = _G["TalentFrame"]
	if not f then return end
	-- Fit inside the square in both axes; the tree is taller than wide, so
	-- the height ratio usually wins (~2.1x — 32px talent icons become ~67px,
	-- comfortably tappable with the icon spacing around them).
	local scale = math.min(
		WM.WorldSquare:GetWidth() / f:GetWidth(),
		WM.WorldSquare:GetHeight() / f:GetHeight())
	f:SetScale(scale)
	f:ClearAllPoints()
	-- Top-center of the SQUARE (== band top-center), not UIParent: in
	-- landscape band mode the window's top-center coincides with the band's,
	-- but anchoring to the square keeps the confinement explicit.
	f:SetPoint("TOP", WM.WorldSquare, "TOP", 0, 0)
	-- The close button lives inside the scaled frame: compensate so it stays
	-- ~100 physical px.
	closeButton:SetSize(WM.Px(100) / scale, WM.Px(88) / scale)
end

local function OnTalentUILoaded()
	local f = _G["TalentFrame"]
	if not f or closeButton then return end
	closeButton = WM.CreateTouchButton(f, 100, 88, "X", 44)
	closeButton:SetFrameStrata("FULLSCREEN_DIALOG") -- above every tree overlay
	closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	closeButton:SetScript("OnClick", Talents.Close)

	-- Runs after Blizzard's own UIPanel positioning for the frame, so our
	-- anchors win. TalentFrame is insecure — SetScale/SetPoint are legal in
	-- combat — so the reflow runs immediately instead of waiting out a fight.
	f:HookScript("OnShow", function()
		WM.Deck.YieldTo("talents")
		Reflow()
	end)
end

function Talents.Toggle()
	-- ToggleTalentFrame (UIParent.lua) loads Blizzard_TalentUI on first use;
	-- the ADDON_LOADED handler below installs our reflow hook synchronously
	-- during that load, before the frame first shows.
	if ToggleTalentFrame then
		ToggleTalentFrame()
	end
end

function Talents.Close()
	local f = _G["TalentFrame"]
	if f and f:IsShown() then
		HideUIPanel(f)
	end
end

WM.On("ADDON_LOADED", function(_, name)
	if name == "Blizzard_TalentUI" then
		OnTalentUILoaded()
	end
end)

WM.OnInit(function()
	OnTalentUILoaded() -- another addon may have force-loaded the talent UI already
	WM.Deck.RegisterExclusive("talents", Talents.Close)
end)
