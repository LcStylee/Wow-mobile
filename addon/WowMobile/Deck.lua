--------------------------------------------------------------------------------
-- WowMobile · Deck
-- The control deck: the 2D region below the world square. This module owns
--   * the deck container frame (WM.Deck),
--   * the bottom menu row (spellbook / talents / character / quests / map /
--     settings),
--   * the panel system (deck-filling, one visible at a time, 100px close),
--   * the touch scroller used by every scrolling panel,
--   * "exclusive" coordination so panels, the NPC bottom sheet and the world
--     map never stack on top of each other.
--
-- Deck stack (design px, bottom → top), each module publishing its frame in
-- WM.Layout for the next one to anchor to:
--   bottomRow(92) · secondBar(84) · mainBar(286 = 2*mainButtonH + 6 gap)
--   · xpBlock(70) · unitRow(180) · chat (remaining space up to the deck top)
--------------------------------------------------------------------------------

local _, WM = ...

local deck = CreateFrame("Frame", "WowMobileDeck", UIParent)
deck:SetPoint("TOPLEFT", WM.WorldSquare, "BOTTOMLEFT", 0, 0)
deck:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
deck:SetFrameStrata("LOW")
deck:EnableMouse(false)
WM.Deck = deck

-- Shared deck metrics (design px), consumed by the bar/HUD modules.
WM.DeckMetrics = {
	margin = 8,   -- outer margin inside the deck
	gap = 6,      -- vertical gap between stacked rows
	rowBottom = 92,
	secondBar = 84,
	mainButtonH = 140,
	mainButtonW = 172,
	xpBlock = 70,
	unitRow = 180,
}

--------------------------------------------------------------------------------
-- Exclusive surfaces (panels / bottom sheet / world map)
--------------------------------------------------------------------------------

local panels = {}     -- key -> panel frame
local exclusives = {} -- key -> close function (bottom sheet, world map)

function deck.RegisterExclusive(key, closeFn)
	exclusives[key] = closeFn
end

local function RunExclusives(skipKey)
	for key, close in pairs(exclusives) do
		if key ~= skipKey then
			close()
		end
	end
end

function deck.CloseAllPanels()
	for _, panel in pairs(panels) do
		panel:Hide()
	end
end

-- Called by the bottom sheet / world map when THEY take the stage.
function deck.YieldTo(key)
	deck.CloseAllPanels()
	RunExclusives(key)
end

function deck.Open(key)
	local panel = panels[key]
	if not panel then return end
	deck.CloseAllPanels()
	RunExclusives(nil)
	panel:Show()
	if panel.OnOpen then panel.OnOpen(panel) end
end

function deck.Toggle(key)
	local panel = panels[key]
	if not panel then return end
	if panel:IsShown() then
		panel:Hide()
	else
		deck.Open(key)
	end
end

--------------------------------------------------------------------------------
-- Panel factory
-- Deck-filling (not fullscreen) on purpose: the world stays visible and the
-- encoder keeps spending nothing on the static deck region. Title bar with a
-- 100x96 close button (>=90 px touch targets, ARCHITECTURE §4); content below.
--------------------------------------------------------------------------------

local TITLE_H = 104 -- title bar height; the close button is TITLE_H-8 = 96 px

function deck.CreatePanel(key, title)
	local p = CreateFrame("Frame", "WowMobilePanel_" .. key, UIParent)
	p:SetAllPoints(deck)
	p:SetFrameStrata("HIGH")
	p:EnableMouse(true) -- swallow taps so deck buttons underneath can't be hit
	WM.SkinFrame(p, WM.Colors.panel)
	p:Hide()

	local titleText = WM.CreateText(p, 40)
	titleText:SetPoint("TOPLEFT", WM.Px(24), -WM.Px(26))
	titleText:SetText(title)
	p.titleText = titleText

	local close = WM.CreateTouchButton(p, 100, TITLE_H - 8, "X", 44)
	close:SetPoint("TOPRIGHT", -WM.Px(4), -WM.Px(4))
	close:SetScript("OnClick", function() p:Hide() end)
	p.closeButton = close

	local content = CreateFrame("Frame", nil, p)
	content:SetPoint("TOPLEFT", WM.Px(8), -WM.Px(TITLE_H))
	content:SetPoint("BOTTOMRIGHT", -WM.Px(8), WM.Px(8))
	p.content = content

	panels[key] = p
	return p
end

--------------------------------------------------------------------------------
-- Touch scroller
-- ScrollFrame + big page-up/page-down buttons in a right-hand column (a thumb
-- can't mouse-wheel; wheel still works because the client maps pinch to wheel
-- events, which land on the hovered frame).
--------------------------------------------------------------------------------

local SCROLL_COL = 92

function deck.CreateScroller(parent)
	local s = {}

	local sf = CreateFrame("ScrollFrame", nil, parent)
	sf:SetPoint("TOPLEFT")
	sf:SetPoint("BOTTOMRIGHT", -WM.Px(SCROLL_COL + 6), 0)
	local child = CreateFrame("Frame", nil, sf)
	child:SetSize(1, 1) -- real size set in SetContentHeight
	sf:SetScrollChild(child)
	s.frame, s.child = sf, child

	local up = WM.CreateTouchButton(parent, SCROLL_COL, 120, "Up", 30)
	up:SetPoint("TOPRIGHT")
	local down = WM.CreateTouchButton(parent, SCROLL_COL, 120, "Down", 30)
	down:SetPoint("BOTTOMRIGHT")

	local function MaxScroll()
		local range = child:GetHeight() - sf:GetHeight()
		return range > 0 and range or 0
	end

	local function UpdateButtons()
		local cur, max = sf:GetVerticalScroll(), MaxScroll()
		WM.SetButtonEnabled(up, cur > 0.5)
		WM.SetButtonEnabled(down, cur < max - 0.5)
	end

	local function ScrollBy(delta)
		local target = sf:GetVerticalScroll() + delta
		local max = MaxScroll()
		if target < 0 then target = 0 end
		if target > max then target = max end
		sf:SetVerticalScroll(target)
		UpdateButtons()
	end

	up:SetScript("OnClick", function() ScrollBy(-sf:GetHeight() * 0.7) end)
	down:SetScript("OnClick", function() ScrollBy(sf:GetHeight() * 0.7) end)
	sf:EnableMouseWheel(true)
	sf:SetScript("OnMouseWheel", function(_, dir) ScrollBy(-dir * sf:GetHeight() * 0.35) end)

	function s.ContentWidth()
		return sf:GetWidth()
	end

	function s.SetContentHeight(h)
		child:SetWidth(sf:GetWidth())
		child:SetHeight(h > 1 and h or 1)
		-- Re-clamp after content shrank.
		local max = MaxScroll()
		if sf:GetVerticalScroll() > max then sf:SetVerticalScroll(max) end
		UpdateButtons()
	end

	function s.ScrollToTop()
		sf:SetVerticalScroll(0)
		UpdateButtons()
	end

	return s
end

--------------------------------------------------------------------------------
-- Bottom row: 8 menu buttons on the left (Spells / Talents / Char / Quests /
-- Social / Raid / Map / Config); Bags.lua fills the right end with its single
-- bags button.
--------------------------------------------------------------------------------

-- 8 menu buttons (110) + 7 gaps (4) = 908 px; the bags button on the right
-- takes 120 px (Bags.lua) — 1028 px total inside the 1064 px row. (Round 3
-- collapsed Bags' five per-bag buttons — all of which toggled the same panel —
-- into one, freeing the width for the Social and Raid entries.)
local MENU_W = 110

WM.OnInit(function()
	local m = WM.DeckMetrics
	local row = CreateFrame("Frame", "WowMobileBottomRow", deck)
	row:SetPoint("BOTTOMLEFT", WM.Px(m.margin), WM.Px(m.margin))
	row:SetPoint("BOTTOMRIGHT", -WM.Px(m.margin), WM.Px(m.margin))
	row:SetHeight(WM.Px(m.rowBottom))
	WM.Layout.bottomRow = row

	local entries = {
		{ label = "Spells",  onTap = function() deck.Toggle("spellbook") end },
		{ label = "Talents", onTap = function()
			-- Talents live in the world square (reflowed Blizzard_TalentUI).
			if WM.Talents then WM.Talents.Toggle() end
		end },
		{ label = "Char",    onTap = function() deck.Toggle("character") end },
		{ label = "Quests",  onTap = function() deck.Toggle("questlog") end },
		{ label = "Social",  onTap = function() deck.Toggle("social") end },
		{ label = "Raid",    onTap = function() deck.Toggle("raid") end },
		{ label = "Map",     onTap = function()
			-- The map overlays the deck as a reflowed Blizzard frame, not a
			-- Deck.CreatePanel; WorldMap.lua joins the exclusive system.
			if WM.WorldMap then WM.WorldMap.Toggle() end
		end },
		{ label = "Config",  onTap = function() deck.Toggle("settings") end },
	}

	local prev
	for i = 1, #entries do
		local b = WM.CreateTouchButton(row, MENU_W, m.rowBottom, entries[i].label, 24)
		if prev then
			b:SetPoint("LEFT", prev, "RIGHT", WM.Px(4), 0)
		else
			b:SetPoint("LEFT", row, "LEFT", 0, 0)
		end
		b:SetScript("OnClick", entries[i].onTap)
		prev = b
	end
end)
