--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · XPBar
-- The XP + watched-reputation block above the main action bar. Fixed block
-- height so the deck anchor chain stays static. At max level the XP bar shows
-- a full "Level N" bar; the rep bar hides entirely when no faction is watched.
--
-- The watched-faction machinery is genuine 1.12, not a TBC addition: vanilla
-- FrameXML's ReputationWatchBar_Update reads GetWatchedFactionInfo and
-- ReputationFrame.xml:842 sets the watch via SetWatchedFactionIndex
-- (line-level sources in CharacterPanel.lua's rep-tab block comment). So the
-- `if GetWatchedFactionInfo` guard below DOES fire on the real 1.12 client
-- and the rep bar renders — the guard only lets an odd build lacking the API
-- degrade to XP-only instead of erroring. CharacterPanel's Rep tab is where
-- the watch is toggled (this bar is the stand-in for the stock
-- ReputationWatchBar, whose MainMenuBar parent this layout banishes).
--------------------------------------------------------------------------------

local WM = WowMobile

local xpBar, repBar

local function MakeBar(parent, hPx)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetHeight(WM.Px(hPx))
	bar:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetTexture(0.05, 0.05, 0.06, 1)
	bar.text = WM.CreateText(bar, 22, "OUTLINE")
	bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
	return bar
end

local function UpdateXP()
	local level = UnitLevel("player")
	local maxLevel = MAX_PLAYER_LEVEL or 60
	if level >= maxLevel then
		xpBar:SetMinMaxValues(0, 1)
		xpBar:SetValue(1)
		xpBar:SetStatusBarColor(0.55, 0.15, 0.75)
		xpBar.text:SetText("Level " .. level)
		return
	end
	local xp, xpMax = UnitXP("player"), UnitXPMax("player")
	xpBar:SetMinMaxValues(0, xpMax > 0 and xpMax or 1)
	xpBar:SetValue(xp)
	-- UnitXPMax can transiently report 0 (early login / level-up race); share
	-- the SetMinMaxValues guard so the text never renders "nan%"/"inf%".
	local pct = xpMax > 0 and xp / xpMax * 100 or 0
	local rested = GetXPExhaustion()
	if rested and rested > 0 then
		xpBar:SetStatusBarColor(0.25, 0.45, 0.95) -- rested blue
		xpBar.text:SetText(string.format("Lv %d — %.1f%% (rested)", level, pct))
	else
		xpBar:SetStatusBarColor(0.55, 0.15, 0.75) -- normal purple
		xpBar.text:SetText(string.format("Lv %d — %.1f%%", level, pct))
	end
end

local function UpdateRep()
	if not repBar then return end
	local name, standing, barMin, barMax, value = GetWatchedFactionInfo()
	if not name then
		repBar:Hide()
		return
	end
	repBar:Show()
	local span = barMax - barMin
	repBar:SetMinMaxValues(0, span > 0 and span or 1)
	repBar:SetValue(value - barMin)
	local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing] or { r = 0.5, g = 0.5, b = 0.5 }
	repBar:SetStatusBarColor(c.r, c.g, c.b)
	repBar.text:SetText(string.format("%s  %s / %s", name,
		WM.ShortNum(value - barMin), WM.ShortNum(span)))
end

WM.OnInit(function()
	local m = WM.DeckMetrics
	local block = CreateFrame("Frame", "WowMobileXPBlock", WM.Deck)
	block:SetPoint("BOTTOMLEFT", WM.Layout.mainBar, "TOPLEFT", 0, WM.Px(m.gap))
	block:SetPoint("BOTTOMRIGHT", WM.Layout.mainBar, "TOPRIGHT", 0, WM.Px(m.gap))
	block:SetHeight(WM.Px(m.xpBlock))
	WM.Layout.xpBlock = block

	xpBar = MakeBar(block, 34)
	xpBar:SetPoint("TOPLEFT", block, "TOPLEFT", 0, 0)
	xpBar:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, 0)

	-- GetWatchedFactionInfo is genuine 1.12 (see header), so this fires on
	-- the real client; the guard only covers odd builds lacking the API.
	if GetWatchedFactionInfo then
		repBar = MakeBar(block, 30)
		repBar:SetPoint("BOTTOMLEFT", block, "BOTTOMLEFT", 0, 0)
		repBar:SetPoint("BOTTOMRIGHT", block, "BOTTOMRIGHT", 0, 0)
		UpdateRep()
		WM.On("UPDATE_FACTION", UpdateRep)
		-- CharacterPanel's watch toggle repaints through this hook — 1.12
		-- promises no UPDATE_FACTION for a pure watch flip.
		WM.RefreshWatchedRep = UpdateRep
	end

	UpdateXP()
	WM.On("PLAYER_XP_UPDATE", UpdateXP)
	WM.On("PLAYER_LEVEL_UP", UpdateXP)
	WM.On("UPDATE_EXHAUSTION", UpdateXP)
	WM.On("PLAYER_ENTERING_WORLD", UpdateXP)
end)
