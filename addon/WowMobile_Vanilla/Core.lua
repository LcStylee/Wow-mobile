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
-- Crash guard (Lua 5.0 port of the Classic Era version)
-- Every module-init callback (WM.OnInit) and every event dispatch (WM.On)
-- runs under pcall: one broken module must never take the rest of the deck
-- down or kill the dispatcher loop mid-iteration. The FIRST error per module
-- (module = the .lua file named in the error message) is recorded and
-- surfaced as a red banner at the top of the deck; /wm errors lists all of
-- them, /wm status summarizes health (Config.lua). Zero overhead when
-- healthy: no OnUpdate work, and the banner frame is created lazily on the
-- first error. (pcall is Lua 5.0-native; no varargs/'#'/string.match here.)
--------------------------------------------------------------------------------

local moduleErrors = {} -- file -> first error message
local moduleErrorOrder = {} -- files in first-seen order
local errorBanner

-- Extract the failing module (file) from a Lua error string, which the
-- runtime opens with "Interface\AddOns\WowMobile_Vanilla\<File>.lua:<line>:".
local function ErrorModule(msg)
	local _, _, file = string.find(msg, "([^\\/:]+%.lua)")
	return file or "unknown"
end

local function ShowErrorBanner(file, msg)
	if not errorBanner then
		errorBanner = CreateFrame("Frame", "WowMobileErrorBanner", UIParent)
		errorBanner:SetFrameStrata("DIALOG")
		errorBanner:EnableMouse(false) -- never eat taps; /wm handles actions
		errorBanner:SetHeight(WM.Px(72))
		local bg = errorBanner:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(errorBanner)
		bg:SetTexture(0.55, 0.10, 0.10, 0.95) -- 1.12: SetTexture(r,g,b,a) tints
		errorBanner.text = errorBanner:CreateFontString(nil, "OVERLAY")
		errorBanner.text:SetFont(WM.FONT, WM.Px(24), "")
		errorBanner.text:SetTextColor(1, 0.9, 0.9)
		errorBanner.text:SetPoint("TOPLEFT", errorBanner, "TOPLEFT", WM.Px(16), -WM.Px(8))
		errorBanner.text:SetPoint("BOTTOMRIGHT", errorBanner, "BOTTOMRIGHT", -WM.Px(16), WM.Px(8))
		errorBanner.text:SetJustifyH("CENTER")
	end
	-- Top of the deck = bottom of the world square; before Viewport has run
	-- (or if Viewport itself failed) fall back to the top of the screen.
	errorBanner:ClearAllPoints()
	if WM.WorldSquare then
		errorBanner:SetPoint("TOPLEFT", WM.WorldSquare, "BOTTOMLEFT", 0, 0)
		errorBanner:SetPoint("TOPRIGHT", WM.WorldSquare, "BOTTOMRIGHT", 0, 0)
	else
		errorBanner:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
		errorBanner:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
	end
	errorBanner.text:SetText(string.format(
		"WoW Mobile hit an error in %s: %s — /wm errors for details, /wm reload to retry",
		file, msg))
	errorBanner:Show()
end

-- ReportError records err (any pcall failure) against its module; only the
-- first error per module is kept, so a broken event handler cannot flood
-- memory or repaint the banner on every event.
function WM.ReportError(err)
	local msg = tostring(err)
	local file = ErrorModule(msg)
	if moduleErrors[file] then return end
	moduleErrors[file] = msg
	table.insert(moduleErrorOrder, file)
	ShowErrorBanner(file, msg)
	-- Also line it into chat history for scrollback (banner shows only the
	-- most recent module's error).
	WM.Print("|cffff4040error in " .. file .. ":|r " .. msg)
end

-- GetErrors returns (orderedFiles, file->message) for /wm errors and
-- /wm status. The tables are live; callers must not mutate them.
function WM.GetErrors()
	return moduleErrorOrder, moduleErrors
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
		-- Crash guard: a throwing handler is reported once (per module) and
		-- the remaining handlers for this event still run.
		local ok, err = pcall(list[i], event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
		if not ok then
			WM.ReportError(err)
		end
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
		-- Crash guard: a failed module init is recorded and bannered, and
		-- every later module still initializes (no cascade).
		local ok, err = pcall(inits[i])
		if not ok then
			WM.ReportError(err)
		end
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

--------------------------------------------------------------------------------
-- Economy widgets (shared by the AH / mail / trade / bank / crafting sheets)
--------------------------------------------------------------------------------

-- Gold/silver/copper stepper: three [-] value [+] groups on one 942x96 row.
-- Tap steps by 1, long-press (the client maps long-press to a right click)
-- by 10. Returns a frame with GetCopper()/SetCopper(copper); opts.onChange
-- fires after every user tap (not after SetCopper, so callers seed values
-- without feedback loops).
function WM.CreateMoneyStepper(parent, opts)
	opts = opts or {}
	local f = CreateFrame("Frame", nil, parent)
	f:SetWidth(WM.Px(942))
	f:SetHeight(WM.Px(96))

	local amounts = { g = 0, s = 0, c = 0 }
	local caps = { g = 9999, s = 99, c = 99 }
	local colors = { g = "|cffffd700", s = "|cffc7c7cf", c = "|cffeda55f" }
	local values = {}

	local function Repaint()
		values.g:SetText(colors.g .. amounts.g .. "g|r")
		values.s:SetText(colors.s .. amounts.s .. "s|r")
		values.c:SetText(colors.c .. amounts.c .. "c|r")
	end

	local function Bump(denom, delta)
		local v = amounts[denom] + delta
		if v < 0 then v = 0 end
		if v > caps[denom] then v = caps[denom] end
		if v == amounts[denom] then return end
		amounts[denom] = v
		Repaint()
		if opts.onChange then opts.onChange() end
	end

	local denoms = { "g", "s", "c" }
	local x = 0
	for i = 1, 3 do
		local d = denoms[i]
		local minus = WM.CreateTouchButton(f, 92, 96, "-", 44)
		minus:SetPoint("LEFT", f, "LEFT", WM.Px(x), 0)
		minus:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		minus:SetScript("OnClick", function()
			Bump(d, arg1 == "RightButton" and -10 or -1)
		end)
		local value = WM.CreateText(f, 32)
		value:SetPoint("LEFT", minus, "RIGHT", 0, 0)
		value:SetWidth(WM.Px(118))
		value:SetJustifyH("CENTER")
		values[d] = value
		local plus = WM.CreateTouchButton(f, 92, 96, "+", 44)
		plus:SetPoint("LEFT", minus, "RIGHT", WM.Px(118), 0)
		plus:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		plus:SetScript("OnClick", function()
			Bump(d, arg1 == "RightButton" and 10 or 1)
		end)
		x = x + 320
	end

	function f.GetCopper()
		return amounts.g * 10000 + amounts.s * 100 + amounts.c
	end

	function f.SetCopper(copper)
		copper = copper or 0
		if copper < 0 then copper = 0 end
		amounts.g = math.floor(copper / 10000)
		if amounts.g > caps.g then amounts.g = caps.g end
		amounts.s = math.mod(math.floor(copper / 100), 100)
		amounts.c = math.mod(copper, 100)
		Repaint()
	end

	f.SetCopper(0)
	return f
end

-- Flat touch edit box. Tapping it takes the game's keyboard focus, so the
-- phone's soft keyboard (raised via the client edge rail's "Aa" key) types
-- straight into it — the same keystroke stream the rescued chat edit box in
-- Chat.lua receives. The client brackets every keyboard submission with two
-- VK_RETURN taps (client keyboard.js: "opens the chat box" / "sends the
-- line"), so Enter here is stateful to speak that protocol: an Enter arriving
-- before anything has been typed since focus (the opening bracket) is
-- consumed — it only selects the box's old text so the incoming characters
-- replace it — while an Enter after typing (the closing bracket) drops focus
-- (world keys work again) and fires eb.onEnter(text) when the caller set one.
-- Escape just drops focus. eb.wmFocused tracks focus for callers' re-render
-- snapshots (Social.lua).
function WM.CreateEditBox(parent, wPx, hPx, maxLetters)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetWidth(WM.Px(wPx))
	eb:SetHeight(WM.Px(hPx))
	WM.SkinFrame(eb, { 0.07, 0.07, 0.09, 1 })
	eb:SetAutoFocus(false)
	eb:SetMaxLetters(maxLetters or 60)
	if eb.SetFont then
		eb:SetFont(WM.FONT, WM.Px(30))
	elseif eb.SetFontObject then
		eb:SetFontObject(ChatFontNormal)
	end
	if eb.SetTextInsets then
		eb:SetTextInsets(WM.Px(16), WM.Px(16), 0, 0)
	end
	local typed = false -- keystrokes since focus gain (Enter protocol above)
	eb:SetScript("OnEditFocusGained", function()
		typed = false
		this.wmFocused = true
	end)
	eb:SetScript("OnEditFocusLost", function() this.wmFocused = nil end)
	eb:SetScript("OnTextChanged", function() typed = true end)
	eb:SetScript("OnEnterPressed", function()
		if not typed then
			-- The keyboard's opening RETURN: consume it, select the old text
			-- so the incoming characters replace it.
			this:HighlightText()
			return
		end
		typed = false
		this:ClearFocus()
		if eb.onEnter then eb.onEnter(eb:GetText()) end
	end)
	eb:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	return eb
end

-- Full-sheet confirmation overlay for destructive/paid actions (place bid,
-- buyout, cancel auction, buy bank slot, pay COD, delete mail).
-- FULLSCREEN_DIALOG strata — the LootSheet master-loot-picker technique:
-- within one strata 1.12 draws and hit-tests strictly by frame level, and a
-- sheet's scroller rows are DEEP descendants that would out-level a sibling
-- overlay; the strata is set BEFORE the children are created so they inherit
-- it. Strata alone is not enough, though: other FULLSCREEN_DIALOG overlays
-- on the same sheet (mail detail, AH category picker) sit at the SAME
-- default level as this frame, and equal strata+level draw/hit order is
-- unspecified on 1.12 (it can reshuffle across Hide/Show cycles) — on a
-- money-destructive Confirm a tap must never fall through to an underlying
-- button. So the level is also bumped decisively (+20) before the children
-- are created, so they inherit it and out-level any sibling overlay's deep
-- descendants. o.Ask(msg, confirmLabel, fn): Confirm runs fn; Cancel just
-- hides. The overlay is a child of its sheet, so it hides with it
-- automatically.
function WM.CreateConfirmOverlay(parent)
	local o = CreateFrame("Frame", nil, parent)
	o:SetFrameStrata("FULLSCREEN_DIALOG")
	o:SetFrameLevel(o:GetFrameLevel() + 20)
	o:SetAllPoints(parent)
	o:EnableMouse(true)
	WM.SkinFrame(o, WM.Colors.panel, WM.Colors.accent)
	o:Hide()
	local text = WM.CreateText(o, 34)
	text:SetPoint("TOPLEFT", o, "TOPLEFT", WM.Px(32), -WM.Px(48))
	text:SetPoint("TOPRIGHT", o, "TOPRIGHT", -WM.Px(32), -WM.Px(48))
	text:SetJustifyH("LEFT")
	local yes = WM.CreateTouchButton(o, 440, 120, "Confirm", 34)
	yes:SetPoint("BOTTOMLEFT", o, "BOTTOMLEFT", WM.Px(24), WM.Px(24))
	yes:SetScript("OnClick", function()
		o:Hide()
		if o.onConfirm then o.onConfirm() end
	end)
	local no = WM.CreateTouchButton(o, 440, 120, "Cancel", 34)
	no:SetPoint("BOTTOMRIGHT", o, "BOTTOMRIGHT", -WM.Px(24), WM.Px(24))
	no:SetScript("OnClick", function() o:Hide() end)
	function o.Ask(msg, confirmLabel, fn)
		text:SetText(msg)
		yes.label:SetText(confirmLabel or "Confirm")
		o.onConfirm = fn
		o:Show()
	end
	return o
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
