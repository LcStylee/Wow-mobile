--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Core
-- Addon namespace, event bus, init sequencing, timers and the shared
-- styling/widget helpers every other module builds on.
--
-- Platform notes for the whole addon (WoW 1.12 = Lua 5.0):
--   * no addon vararg — modules share the global WowMobile table,
--   * frame script handlers receive NO arguments; they read the globals
--     `this`, `event`, `arg1`..`arg9` (OnUpdate: arg1 = elapsed,
--     OnClick: arg1 = button name),
--   * no `#`, no `%` operator, no string.match/gmatch, no select(), no
--     C_Timer — table.getn / math.mod / string.find / string.gfind and the
--     OnUpdate timer wheel below instead,
--   * 1.12 has NO protected frames / combat lockdown: frame layout, action
--     use and attribute-free click handlers are legal at any time, so the
--     1.15 addon's out-of-combat queue and secure templates have no
--     counterpart here.
--------------------------------------------------------------------------------

WowMobile = WowMobile or {}
local WM = WowMobile

WM.name = "WowMobile"
WM.Layout = {} -- named anchor frames of the control-deck stack

-- Solid 8x8 white texture shipped with the 1.12 client; tinted via
-- SetTexture(r,g,b,a) / SetStatusBarColor everywhere we need flat fills.
WM.TEX_WHITE = "Interface\\Buttons\\WHITE8X8"
WM.TEX_QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

WM.Colors = {
	bg     = { 0.09, 0.09, 0.11, 1.00 },
	panel  = { 0.05, 0.05, 0.06, 0.98 },
	button = { 0.13, 0.13, 0.16, 1.00 },
	border = { 0.28, 0.28, 0.33, 1.00 },
	accent = { 1.00, 0.82, 0.00, 1.00 },
	dim    = { 0.55, 0.55, 0.58, 1.00 },
	red    = { 0.85, 0.25, 0.25, 1.00 },
	green  = { 0.30, 0.80, 0.35, 1.00 },
}

WM.FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

--------------------------------------------------------------------------------
-- Design-space conversion
-- All layout constants are written in *physical pixels* of the 1080-wide
-- streamed window. UIParent:GetWidth() is that same 1080 px expressed in UI
-- units (uiScale-dependent), so one factor converts design px -> UI units and
-- keeps physical touch-target sizes constant regardless of the uiScale cvar.
--------------------------------------------------------------------------------

local pxFactor = UIParent:GetWidth() / 1080

function WM.Px(px)
	return px * pxFactor
end

function WM.UpdatePxFactor()
	pxFactor = UIParent:GetWidth() / 1080
end

--------------------------------------------------------------------------------
-- Event bus (1.12 handler convention: read the event/argN globals)
--------------------------------------------------------------------------------

local handlers = {} -- event -> array of fn(event, arg1..arg9)
local dispatcher = CreateFrame("Frame", "WowMobileEventDispatcher", UIParent)

dispatcher:SetScript("OnEvent", function()
	local list = handlers[event]
	if not list then return end
	for i = 1, table.getn(list) do
		list[i](event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
	end
end)

local function AddHandler(ev, fn)
	local list = handlers[ev]
	if not list then
		list = {}
		handlers[ev] = list
	end
	table.insert(list, fn)
end

function WM.On(ev, fn)
	if not handlers[ev] then
		dispatcher:RegisterEvent(ev)
	end
	AddHandler(ev, fn)
end

-- For events that may not exist on this client build; pcall soaks up any
-- RegisterEvent complaint so the handler is simply never called.
function WM.TryOn(ev, fn)
	if not handlers[ev] then
		local ok = pcall(dispatcher.RegisterEvent, dispatcher, ev)
		if not ok then return end
	end
	AddHandler(ev, fn)
end

--------------------------------------------------------------------------------
-- Init sequencing
--------------------------------------------------------------------------------

local inits = {}

function WM.OnInit(fn)
	table.insert(inits, fn)
end

WM.On("PLAYER_LOGIN", function()
	for i = 1, table.getn(inits) do
		inits[i]()
	end
	inits = {} -- PLAYER_LOGIN fires once per session; free the closures
end)

--------------------------------------------------------------------------------
-- Timers (no C_Timer on 1.12): a single OnUpdate wheel drives one-shot
-- WM.After and repeating WM.Ticker callbacks. Coarse (frame granularity),
-- which is all the cooldown/range/duration texts need.
--------------------------------------------------------------------------------

local timers = {} -- array of { at, fn, interval? }
local timerFrame = CreateFrame("Frame", "WowMobileTimerFrame", UIParent)

timerFrame:SetScript("OnUpdate", function()
	local now = GetTime()
	for i = table.getn(timers), 1, -1 do
		local t = timers[i]
		if now >= t.at then
			if t.interval then
				t.at = now + t.interval
				t.fn()
			else
				table.remove(timers, i)
				t.fn()
			end
		end
	end
end)

function WM.After(delay, fn)
	table.insert(timers, { at = GetTime() + delay, fn = fn })
end

function WM.Ticker(interval, fn)
	table.insert(timers, { at = GetTime() + interval, interval = interval, fn = fn })
end

--------------------------------------------------------------------------------
-- Hidden parent for neutered Blizzard frames
--------------------------------------------------------------------------------

local hider = CreateFrame("Frame", "WowMobileHiddenParent", UIParent)
hider:Hide()
WM.Hider = hider

-- Reparenting under a hidden frame keeps the target hidden without calling
-- Show/Hide on it again later. Events are unregistered so the frame stops
-- doing per-event work while banished (this is also what stops the default
-- NPC frames from popping up on GOSSIP_SHOW etc.).
function WM.BanishFrame(frame, keepEvents)
	if not frame then return end
	if not keepEvents and frame.UnregisterAllEvents then
		frame:UnregisterAllEvents()
	end
	frame:Hide()
	frame:SetParent(hider)
end

--------------------------------------------------------------------------------
-- Styling / widget helpers
--------------------------------------------------------------------------------

function WM.SetShown(frame, on)
	if on then frame:Show() else frame:Hide() end
end

function WM.SetFont(fs, sizePx, flags)
	fs:SetFont(WM.FONT, WM.Px(sizePx), flags or "")
end

function WM.CreateText(parent, sizePx, flags)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	WM.SetFont(fs, sizePx, flags)
	fs:SetTextColor(0.92, 0.92, 0.92)
	return fs
end

-- 1.12 FontStrings have no SetWordWrap; capping the height to one line is the
-- vanilla idiom for "no wrap" (overflow clips).
function WM.SingleLine(fs, sizePx)
	fs:SetHeight(WM.Px(sizePx + 8))
end

-- Flat 2px border + fill, the base look of every deck surface.
-- (1.12 has no SetColorTexture; SetTexture(r,g,b,a) tints a solid fill.)
function WM.SkinFrame(frame, bg, border)
	bg = bg or WM.Colors.bg
	border = border or WM.Colors.border
	local edge = frame:CreateTexture(nil, "BACKGROUND")
	edge:SetAllPoints(frame)
	edge:SetTexture(border[1], border[2], border[3], border[4] or 1)
	local fill = frame:CreateTexture(nil, "BORDER")
	fill:SetPoint("TOPLEFT", frame, "TOPLEFT", WM.Px(2), -WM.Px(2))
	fill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	fill:SetTexture(bg[1], bg[2], bg[3], bg[4] or 1)
	frame.borderTex, frame.fillTex = edge, fill
	return frame
end

-- Border/fill recolor helpers (SetTexture re-tint on 1.12).
function WM.TintBorder(frame, c)
	frame.borderTex:SetTexture(c[1], c[2], c[3], c[4] or 1)
end

-- Big flat touch button with a centered label.
function WM.CreateTouchButton(parent, wPx, hPx, label, fontPx)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(WM.Px(wPx))
	b:SetHeight(WM.Px(hPx))
	WM.SkinFrame(b, WM.Colors.button)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b)
	hl:SetTexture(1, 1, 1, 0.10)
	b.label = WM.CreateText(b, fontPx or 30)
	b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.label:SetWidth(WM.Px(wPx - 16))
	b.label:SetJustifyH("CENTER")
	if label then b.label:SetText(label) end
	return b
end

function WM.SetButtonEnabled(b, on)
	if on then
		b:Enable()
		b.label:SetTextColor(0.92, 0.92, 0.92)
	else
		b:Disable()
		local d = WM.Colors.dim
		b.label:SetTextColor(d[1], d[2], d[3])
	end
end

-- "cover"-crop a texture into a non-square region so icons never stretch.
function WM.CropIcon(tex, wPx, hPx)
	local ratio = wPx / hPx
	if ratio > 1 then
		local inset = 0.5 - 0.5 / ratio
		tex:SetTexCoord(0, 1, inset, 1 - inset)
	elseif ratio < 1 then
		local inset = 0.5 - 0.5 * ratio
		tex:SetTexCoord(inset, 1 - inset, 0, 1)
	else
		tex:SetTexCoord(0, 1, 0, 1)
	end
end

--------------------------------------------------------------------------------
-- Cooldown spiral helper
-- 1.12 cooldowns are Model frames inheriting CooldownFrameTemplate, driven by
-- CooldownFrame_SetTimer(model, start, duration, enable). The template's
-- native footprint is 36x36 UI units and the spiral does not stretch with
-- SetWidth/SetHeight — SetScale is how it is fitted to a differently sized
-- button (the standard vanilla pattern).
--------------------------------------------------------------------------------

function WM.CreateCooldown(parent, anchorRegion, sizePx)
	local cd = CreateFrame("Model", nil, parent, "CooldownFrameTemplate")
	cd:SetPoint("CENTER", anchorRegion, "CENTER", 0, 0)
	cd:SetScale(WM.Px(sizePx) / 36)
	cd:Hide()
	return cd
end

function WM.SetCooldown(cd, start, duration, enable)
	CooldownFrame_SetTimer(cd, start or 0, duration or 0, enable or 0)
end

function WM.ClearCooldown(cd)
	CooldownFrame_SetTimer(cd, 0, 0, 0)
end

--------------------------------------------------------------------------------
-- Tooltip helpers
-- A thumb covers whatever it touches, so tooltips always anchor ABOVE the
-- touched element (they arrive via the injected pointer-move that precedes
-- every tap, which fires OnEnter like a real mouse).
--------------------------------------------------------------------------------

function WM.AnchorTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_NONE")
	GameTooltip:ClearAllPoints()
	GameTooltip:SetPoint("BOTTOM", owner, "TOP", 0, WM.Px(18))
	if GameTooltip.SetClampedToScreen then
		GameTooltip:SetClampedToScreen(true)
	end
end

function WM.AttachTooltip(frame, setter)
	frame:SetScript("OnEnter", function()
		WM.AnchorTooltip(this)
		setter(GameTooltip, this)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- World-object / default tooltips: park them just above the deck, inside the
-- world square, where no finger ever rests. No hooksecurefunc on 1.12; the
-- insecure global is wrapped directly (nothing here is protected).
local origSetDefaultAnchor = GameTooltip_SetDefaultAnchor
function GameTooltip_SetDefaultAnchor(tooltip, parent)
	origSetDefaultAnchor(tooltip, parent)
	tooltip:ClearAllPoints()
	local anchor = WM.WorldSquare or UIParent
	tooltip:SetPoint("BOTTOM", anchor, "BOTTOM", 0, WM.Px(12))
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

function WM.ShortNum(n)
	if n >= 1000000 then
		return string.format("%.1fm", n / 1000000)
	elseif n >= 10000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(n)
end

function WM.FormatMoney(copper)
	copper = copper or 0
	local g = math.floor(copper / 10000)
	local s = math.mod(math.floor(copper / 100), 100)
	local c = math.mod(copper, 100)
	if g > 0 then
		return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r |cffeda55f%dc|r", g, s, c)
	elseif s > 0 then
		return string.format("|cffc7c7cf%ds|r |cffeda55f%dc|r", s, c)
	end
	return string.format("|cffeda55f%dc|r", c)
end

function WM.FormatDuration(seconds)
	if seconds >= 3600 then
		return string.format("%dh", math.floor(seconds / 3600))
	elseif seconds >= 60 then
		return string.format("%dm", math.floor(seconds / 60))
	end
	return string.format("%d", math.floor(seconds + 0.5))
end

-- Class color for players, reaction color for NPCs. 1.12 UnitClass returns
-- (localizedClass, englishToken); RAID_CLASS_COLORS keying differed across
-- vanilla FrameXML revisions (english token vs localized name), so both are
-- tried before falling back to the reaction color.
function WM.UnitColor(unit)
	if UnitIsPlayer(unit) then
		local localized, english = UnitClass(unit)
		local t = RAID_CLASS_COLORS
		if t then
			local c = (english and t[english]) or (localized and t[localized])
			if c then return c.r, c.g, c.b end
		end
	end
	local reaction = UnitReaction(unit, "player")
	if reaction then
		if reaction <= 3 then
			return 0.85, 0.25, 0.25
		elseif reaction == 4 then
			return 0.95, 0.80, 0.25
		end
		return 0.30, 0.80, 0.35
	end
	return 0.70, 0.70, 0.70
end

function WM.Print(msg)
	local line = "|cff33ccffWowMobile|r " .. tostring(msg)
	-- Chat.lua banishes the default chat windows; route through the addon's
	-- own chat strip once it has published WM.ChatDeliver.
	if WM.ChatDeliver then
		WM.ChatDeliver(line, 0.92, 0.92, 0.92)
	else
		DEFAULT_CHAT_FRAME:AddMessage(line)
	end
end
