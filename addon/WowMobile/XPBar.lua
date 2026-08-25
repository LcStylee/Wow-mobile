--------------------------------------------------------------------------------
-- WowMobile · XPBar
-- The XP + watched-reputation block above the main action bar. Two thin,
-- full-width status bars with centered text; fixed block height so the deck
-- anchor chain stays static. At max level the XP bar shows a full "Level N"
-- bar; the rep bar hides entirely when no faction is watched.
--------------------------------------------------------------------------------

local _, WM = ...

local xpBar, repBar

local function MakeBar(parent, hPx)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetHeight(WM.Px(hPx))
	bar:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.06, 1)
	bar.text = WM.CreateText(bar, 22, "OUTLINE")
	bar.text:SetPoint("CENTER")
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

-- Watched-faction reader, feature-detected once at load (Compat.lua pattern).
-- Both branches return the classic five-value shape:
-- name, standingID, barMin, barMax, value (nil when nothing is watched).
-- The 1.15.5 C_Reputation rework REMOVED GetWatchedFactionInfo from Classic
-- Era, so on the targeted 1.15.7 client the data comes from
-- C_Reputation.GetWatchedFactionData's table (reaction = standingID,
-- current/nextReactionThreshold = the bar bounds, currentStanding = value);
-- the global stays as the path for older builds.
local GetWatchedFaction
if C_Reputation and C_Reputation.GetWatchedFactionData then
	GetWatchedFaction = function()
		local d = C_Reputation.GetWatchedFactionData()
		if not d then return nil end
		return d.name, d.reaction, d.currentReactionThreshold,
			d.nextReactionThreshold, d.currentStanding
	end
elseif GetWatchedFactionInfo then
	GetWatchedFaction = GetWatchedFactionInfo
end

local function UpdateRep()
	if not GetWatchedFaction then
		-- Clients with neither watched-faction API: no rep bar.
		repBar:Hide()
		return
	end
	local name, standing, barMin, barMax, value = GetWatchedFaction()
	if not name then
		repBar:Hide()
		return
	end
	repBar:Show()
	local span = barMax - barMin
	repBar:SetMinMaxValues(0, span > 0 and span or 1)
	repBar:SetValue(value - barMin)
	local c = FACTION_BAR_COLORS[standing] or { r = 0.5, g = 0.5, b = 0.5 }
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
	xpBar:SetPoint("TOPLEFT")
	xpBar:SetPoint("TOPRIGHT")

	repBar = MakeBar(block, 30)
	repBar:SetPoint("BOTTOMLEFT")
	repBar:SetPoint("BOTTOMRIGHT")

	UpdateXP()
	UpdateRep()

	WM.On("PLAYER_XP_UPDATE", UpdateXP)
	WM.On("PLAYER_LEVEL_UP", UpdateXP)
	WM.On("UPDATE_EXHAUSTION", UpdateXP)
	WM.On("UPDATE_FACTION", UpdateRep)
end)
