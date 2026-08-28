--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · CastBar
-- Player cast/channel bar. Overlays the top of the unit-frame row (only
-- visible while casting, so it costs no permanent deck height). The fill is
-- OnUpdate-driven — the explicitly permitted polling exception.
--
-- 1.12 cast events are player-only and argument-based (no UnitCastingInfo):
--   SPELLCAST_START(name, castTimeMs)      SPELLCAST_DELAYED(deltaMs)
--   SPELLCAST_STOP                          SPELLCAST_FAILED / _INTERRUPTED
--   SPELLCAST_CHANNEL_START(durationMs, name)
--   SPELLCAST_CHANNEL_UPDATE(remainingMs)   SPELLCAST_CHANNEL_STOP
-- No event carries a spell texture, so the bar is icon-less by design.
--------------------------------------------------------------------------------

local WM = WowMobile

local bar
local casting, channeling = false, false
local startTime, endTime = 0, 0 -- seconds
local shownTenths -- last tenth-of-a-second rendered, to throttle SetText

local function StartCast(name, durationMs, isChannel)
	casting, channeling = not isChannel, isChannel
	shownTenths = nil
	startTime = GetTime()
	endTime = startTime + (durationMs or 0) / 1000
	bar.name:SetText(name or "")
	if isChannel then
		bar.fill:SetStatusBarColor(0.30, 0.80, 0.35)
	else
		bar.fill:SetStatusBarColor(1.00, 0.70, 0.00)
	end
	bar:Show()
end

local function StopCast()
	casting, channeling = false, false
	bar:Hide()
end

-- Brief red flash so an interrupt is visible on a phone screen.
local failToken = 0
local function FailCast(label)
	casting, channeling = false, false
	failToken = failToken + 1
	local token = failToken
	bar.fill:SetStatusBarColor(0.85, 0.2, 0.2)
	bar.fill:SetMinMaxValues(0, 1)
	bar.fill:SetValue(1)
	bar.name:SetText(label)
	bar.time:SetText("")
	bar:Show()
	WM.After(0.7, function()
		-- A newer cast may have started during the flash; don't hide it.
		if token == failToken and not casting and not channeling then
			bar:Hide()
		end
	end)
end

local function OnUpdate()
	if not (casting or channeling) then return end
	local now = GetTime()
	local duration = endTime - startTime
	if duration <= 0 or now >= endTime then
		StopCast()
		return
	end
	bar.fill:SetMinMaxValues(0, duration)
	-- Channels drain right-to-left; casts fill left-to-right.
	bar.fill:SetValue(channeling and (endTime - now) or (now - startTime))
	-- The text has 0.1s granularity, so format/SetText (per-frame string
	-- garbage otherwise) only needs to run when the displayed tenth changes.
	local remain = endTime - now
	local tenths = math.floor(remain * 10)
	if tenths ~= shownTenths then
		shownTenths = tenths
		bar.time:SetText(string.format("%.1fs", remain))
	end
end

WM.OnInit(function()
	local row = WM.Layout.unitRow
	bar = CreateFrame("Frame", "WowMobileCastBar", row)
	bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, WM.Px(4))
	bar:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, WM.Px(4))
	bar:SetHeight(WM.Px(64))
	bar:SetFrameLevel(row:GetFrameLevel() + 30) -- above both unit buttons
	bar:EnableMouse(false) -- taps must fall through to the unit frames
	WM.SkinFrame(bar, { 0.04, 0.04, 0.05, 0.95 })
	bar:Hide()

	bar.fill = CreateFrame("StatusBar", nil, bar)
	bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", WM.Px(4), -WM.Px(4))
	bar.fill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	bar.fill:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar.fill:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar.fill)
	bg:SetTexture(0.10, 0.10, 0.12, 1)

	bar.name = WM.CreateText(bar.fill, 28, "OUTLINE")
	bar.name:SetPoint("LEFT", bar.fill, "LEFT", WM.Px(10), 0)
	bar.time = WM.CreateText(bar.fill, 26, "OUTLINE")
	bar.time:SetPoint("RIGHT", bar.fill, "RIGHT", -WM.Px(10), 0)

	bar:SetScript("OnUpdate", OnUpdate)

	WM.On("SPELLCAST_START", function(_, name, castTimeMs)
		StartCast(name, castTimeMs, false)
	end)
	WM.On("SPELLCAST_DELAYED", function(_, deltaMs)
		if casting then
			endTime = endTime + (deltaMs or 0) / 1000
		end
	end)
	WM.On("SPELLCAST_CHANNEL_START", function(_, durationMs, name)
		StartCast(name, durationMs, true)
	end)
	WM.On("SPELLCAST_CHANNEL_UPDATE", function(_, remainingMs)
		if channeling then
			endTime = GetTime() + (remainingMs or 0) / 1000
		end
	end)
	-- 1.12 event order for a broken cast is SPELLCAST_FAILED (or
	-- SPELLCAST_INTERRUPTED) followed by a trailing SPELLCAST_STOP. FailCast
	-- has already cleared `casting` by the time that STOP arrives, so the
	-- guard below keeps the STOP from hiding the bar mid-flash — the flash's
	-- WM.After(0.7) closer is then the only thing that hides it. An unguarded
	-- StopCast here would cancel the advertised interrupt flash every time.
	WM.On("SPELLCAST_STOP", function()
		if casting then StopCast() end
	end)
	WM.On("SPELLCAST_CHANNEL_STOP", function()
		if channeling then StopCast() end
	end)
	WM.On("SPELLCAST_INTERRUPTED", function()
		-- Only flash if the fail killed a cast we were showing (instant-cast
		-- failures fire these events too, with no bar up).
		if casting then FailCast("Interrupted") end
	end)
	WM.On("SPELLCAST_FAILED", function()
		if casting then FailCast("Failed") end
	end)
end)
