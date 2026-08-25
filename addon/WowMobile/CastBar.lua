--------------------------------------------------------------------------------
-- WowMobile · CastBar
-- Player cast/channel bar. Overlays the top of the unit-frame row (only
-- visible while casting, so it costs no permanent deck height). The fill is
-- OnUpdate-driven — the explicitly permitted polling exception.
--------------------------------------------------------------------------------

local _, WM = ...

local bar
local casting, channeling = false, false
local startTime, endTime = 0, 0 -- seconds
local shownTenths -- last tenth-of-a-second rendered, to throttle SetText

local function SetTimes(startMs, endMs)
	startTime, endTime = startMs / 1000, endMs / 1000
end

local function StartCast(name, texture, startMs, endMs, isChannel)
	casting, channeling = not isChannel, isChannel
	shownTenths = nil
	SetTimes(startMs, endMs)
	bar.icon:SetTexture(texture or WM.TEX_QUESTION)
	bar.name:SetText(name or "")
	bar.fill:SetStatusBarColor(isChannel and 0.30 or 1.00, isChannel and 0.80 or 0.70, isChannel and 0.35 or 0.00)
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
	C_Timer.After(0.7, function()
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
	-- garbage otherwise) only needs to run when the displayed tenth changes —
	-- at most 10x/s (perf-hygiene rule for the one OnUpdate path).
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
	bar:SetPoint("TOPLEFT", 0, WM.Px(4))
	bar:SetPoint("TOPRIGHT", 0, WM.Px(4))
	bar:SetHeight(WM.Px(64))
	bar:SetFrameLevel(row:GetFrameLevel() + 30) -- above both unit buttons
	bar:EnableMouse(false) -- taps must fall through to the unit frames
	WM.SkinFrame(bar, { 0.04, 0.04, 0.05, 0.95 })
	bar:Hide()

	bar.icon = bar:CreateTexture(nil, "ARTWORK")
	bar.icon:SetPoint("TOPLEFT", WM.Px(4), -WM.Px(4))
	bar.icon:SetSize(WM.Px(56), WM.Px(56))

	bar.fill = CreateFrame("StatusBar", nil, bar)
	bar.fill:SetPoint("TOPLEFT", bar.icon, "TOPRIGHT", WM.Px(4), 0)
	bar.fill:SetPoint("BOTTOMRIGHT", -WM.Px(4), WM.Px(4))
	bar.fill:SetStatusBarTexture(WM.TEX_WHITE)
	local bg = bar.fill:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.10, 0.10, 0.12, 1)

	bar.name = WM.CreateText(bar.fill, 28, "OUTLINE")
	bar.name:SetPoint("LEFT", WM.Px(10), 0)
	bar.time = WM.CreateText(bar.fill, 26, "OUTLINE")
	bar.time:SetPoint("RIGHT", -WM.Px(10), 0)

	bar:SetScript("OnUpdate", OnUpdate)

	local function OnCastStart(_, unit)
		if unit ~= "player" then return end
		local name, _, texture, startMs, endMs = WM.CastingInfo()
		if name then StartCast(name, texture, startMs, endMs, false) end
	end

	local function OnChannelStart(_, unit)
		if unit ~= "player" then return end
		local name, _, texture, startMs, endMs = WM.ChannelInfo()
		if name then StartCast(name, texture, startMs, endMs, true) end
	end

	WM.On("UNIT_SPELLCAST_START", OnCastStart)
	WM.On("UNIT_SPELLCAST_DELAYED", OnCastStart)
	WM.On("UNIT_SPELLCAST_CHANNEL_START", OnChannelStart)
	WM.On("UNIT_SPELLCAST_CHANNEL_UPDATE", OnChannelStart)
	WM.On("UNIT_SPELLCAST_STOP", function(_, unit)
		if unit == "player" and not channeling then StopCast() end
	end)
	WM.On("UNIT_SPELLCAST_CHANNEL_STOP", function(_, unit)
		if unit == "player" then StopCast() end
	end)
	WM.On("UNIT_SPELLCAST_INTERRUPTED", function(_, unit)
		if unit == "player" then FailCast("Interrupted") end
	end)
	WM.On("UNIT_SPELLCAST_FAILED", function(_, unit)
		-- Only flash if the fail killed the cast we were showing.
		if unit == "player" and casting and not WM.CastingInfo() then
			FailCast("Failed")
		end
	end)
end)
