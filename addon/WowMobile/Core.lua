--------------------------------------------------------------------------------
-- WowMobile · Core
-- Addon namespace, event bus, init sequencing, combat-lockdown queue and the
-- shared styling/widget helpers every other module builds on.
--
-- Contract with the other modules (see WowMobile.toc for load order):
--   * every file receives the shared table via the addon vararg,
--   * UI construction happens inside WM.OnInit callbacks, which Core runs in
--     .toc order at PLAYER_LOGIN (saved variables are guaranteed loaded),
--   * every mutation of a protected frame goes through WM.OutOfCombat.
--------------------------------------------------------------------------------

local ADDON_NAME, WM = ...

WM.name = ADDON_NAME
WM.Layout = {} -- named anchor frames of the control-deck stack, filled by Deck/bar modules

-- Solid 8x8 white texture shipped with the client; tinted via SetColorTexture /
-- SetStatusBarColor everywhere we need flat fills.
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

--------------------------------------------------------------------------------
-- Design-space conversion
-- All layout constants in this addon are written in *physical pixels* of the
-- 1080-wide streamed window. UIParent:GetWidth() is that same 1080 px expressed
-- in UI units (uiScale-dependent), so one factor converts design px -> UI units
-- and keeps physical touch-target sizes constant regardless of the uiScale
-- cvar. Recomputed on scale/resolution changes; frames built with the old
-- factor keep their size until /reload (Config prints a hint when scale moves).
--------------------------------------------------------------------------------

local pxFactor = UIParent:GetWidth() / 1080

function WM.Px(px)
	return px * pxFactor
end

function WM.UpdatePxFactor()
	pxFactor = UIParent:GetWidth() / 1080
end

--------------------------------------------------------------------------------
-- Event bus
--------------------------------------------------------------------------------

local handlers = {} -- event -> array of fn(event, ...)
local dispatcher = CreateFrame("Frame", "WowMobileEventDispatcher", UIParent)

dispatcher:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		list[i](event, ...)
	end
end)

local function AddHandler(event, fn)
	local list = handlers[event]
	if not list then
		list = {}
		handlers[event] = list
	end
	list[#list + 1] = fn
end

function WM.On(event, fn)
	if not handlers[event] then
		dispatcher:RegisterEvent(event)
	end
	AddHandler(event, fn)
end

-- For events that only exist on some client builds (RegisterEvent errors on
-- unknown events); silently skips when the running client lacks the event.
function WM.TryOn(event, fn)
	if not handlers[event] then
		local ok = pcall(dispatcher.RegisterEvent, dispatcher, event)
		if not ok then return end
	end
	AddHandler(event, fn)
end

--------------------------------------------------------------------------------
-- Init sequencing
--------------------------------------------------------------------------------

local inits = {}

function WM.OnInit(fn)
	inits[#inits + 1] = fn
end

WM.On("PLAYER_LOGIN", function()
	for i = 1, #inits do
		inits[i]()
	end
	inits = {} -- PLAYER_LOGIN fires once per session; free the closures
end)

--------------------------------------------------------------------------------
-- Combat-lockdown queue
-- Protected-frame layout/attribute work must not run in combat. WM.OutOfCombat
-- runs the closure immediately when safe, otherwise defers it until
-- PLAYER_REGEN_ENABLED. An optional string key coalesces repeat requests
-- (e.g. many UNIT_AURA in one fight -> one re-sync after it).
--------------------------------------------------------------------------------

local queue = {} -- array of { key, fn }
local keyed = {} -- key -> index into queue

function WM.OutOfCombat(key, fn)
	if fn == nil then
		fn, key = key, nil
	end
	if not InCombatLockdown() then
		fn()
		return
	end
	if key and keyed[key] then
		queue[keyed[key]].fn = fn -- keep only the latest request for this key
		return
	end
	queue[#queue + 1] = { key = key, fn = fn }
	if key then
		keyed[key] = #queue
	end
end

WM.On("PLAYER_REGEN_ENABLED", function()
	-- Swap the tables first: a flushed closure may re-queue itself if combat
	-- restarts mid-flush, and that must land in the fresh queue.
	local pending = queue
	queue, keyed = {}, {}
	for i = 1, #pending do
		pending[i].fn()
	end
end)

--------------------------------------------------------------------------------
-- Secure click registration
-- Since 1.14.4 / 3.4.1 / 10.0 (Classic Era 1.15 shares the 10.x engine),
-- SecureActionButton_OnClick / SecureUnitButton_OnClick only perform their
-- action on the click edge selected by the ActionButtonUseKeyDown CVar
-- (default 1 = act on mouse-down); the opposite edge consults the separate
-- "typerelease" attribute and otherwise does nothing. A button registered for
-- "AnyUp" alone is therefore dead under the default CVar. Every secure button
-- in this addon registers for exactly the edge the CVar selects (the approach
-- Bartender4/LibActionButton adopted for 1.14.4+ — it also avoids the
-- double-fire that mirroring "typerelease" with both edges registered would
-- cause) and re-registers when the CVar changes. The client's injected tap is
-- a full pointer-down + pointer-up, so it always contains the selected edge
-- and fires the action exactly once either way.
--------------------------------------------------------------------------------

local secureClickButtons = {}

local function SecureClickEdge()
	return GetCVarBool("ActionButtonUseKeyDown") and "AnyDown" or "AnyUp"
end

-- Call once per secure button, from out-of-combat code (every caller already
-- runs inside a WM.OutOfCombat closure).
function WM.RegisterSecureClicks(button)
	button:RegisterForClicks(SecureClickEdge())
	secureClickButtons[#secureClickButtons + 1] = button
end

WM.On("CVAR_UPDATE", function(_, name)
	-- The first CVAR_UPDATE arg is the plain cvar name on current builds and
	-- the registered event alias on older ones; accept both spellings.
	if name ~= "ActionButtonUseKeyDown" and name ~= "ACTION_BUTTON_USE_KEY_DOWN" then
		return
	end
	-- Click re-registration on protected buttons is lockdown-blocked → queue.
	WM.OutOfCombat("secure-click-edge", function()
		local edge = SecureClickEdge()
		for i = 1, #secureClickButtons do
			secureClickButtons[i]:RegisterForClicks(edge)
		end
	end)
end)

--------------------------------------------------------------------------------
-- Hidden parent for neutered Blizzard frames
--------------------------------------------------------------------------------

local hider = CreateFrame("Frame", "WowMobileHiddenParent", UIParent)
hider:Hide()
WM.Hider = hider

-- Reparenting under a hidden frame keeps the target hidden without calling
-- Show/Hide on it again later (no taint-prone hooks needed). Events are
-- unregistered so the frame stops doing per-event work while banished.
function WM.BanishFrame(frame, keepEvents)
	if not frame then return end
	if not keepEvents and frame.UnregisterAllEvents then
		frame:UnregisterAllEvents()
	end
	WM.OutOfCombat(function()
		frame:Hide()
		frame:SetParent(hider)
	end)
end

--------------------------------------------------------------------------------
-- Styling / widget helpers
--------------------------------------------------------------------------------

function WM.SetFont(fs, sizePx, flags)
	fs:SetFont(STANDARD_TEXT_FONT, WM.Px(sizePx), flags or "")
end

function WM.CreateText(parent, sizePx, flags)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	WM.SetFont(fs, sizePx, flags)
	fs:SetTextColor(0.92, 0.92, 0.92)
	return fs
end

-- Flat 2px border + fill, the base look of every deck surface.
function WM.SkinFrame(frame, bg, border)
	bg = bg or WM.Colors.bg
	border = border or WM.Colors.border
	local edge = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
	edge:SetAllPoints()
	edge:SetColorTexture(border[1], border[2], border[3], border[4] or 1)
	local fill = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	fill:SetPoint("TOPLEFT", WM.Px(2), -WM.Px(2))
	fill:SetPoint("BOTTOMRIGHT", -WM.Px(2), WM.Px(2))
	fill:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
	frame.borderTex, frame.fillTex = edge, fill
	return frame
end

-- Big flat touch button with a centered, word-wrapping label.
function WM.CreateTouchButton(parent, wPx, hPx, label, fontPx)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(WM.Px(wPx), WM.Px(hPx))
	WM.SkinFrame(b, WM.Colors.button)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.10)
	b.label = WM.CreateText(b, fontPx or 30)
	b.label:SetPoint("CENTER")
	b.label:SetWidth(WM.Px(wPx - 16))
	b.label:SetJustifyH("CENTER")
	b.label:SetWordWrap(true)
	if label then b.label:SetText(label) end
	return b
end

function WM.SetButtonEnabled(b, on)
	b:SetEnabled(on and true or false)
	if on then
		b.label:SetTextColor(0.92, 0.92, 0.92)
	else
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
-- Tooltip helpers
-- A thumb covers whatever it touches, so tooltips always anchor ABOVE the
-- touched element (they also arrive via the injected pointer-move that
-- precedes every tap, which fires OnEnter like a real mouse).
--------------------------------------------------------------------------------

function WM.AnchorTooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_NONE")
	GameTooltip:ClearAllPoints()
	GameTooltip:SetPoint("BOTTOM", owner, "TOP", 0, WM.Px(18))
	GameTooltip:SetClampedToScreen(true)
end

function WM.AttachTooltip(frame, setter)
	frame:SetScript("OnEnter", function(self)
		WM.AnchorTooltip(self)
		setter(GameTooltip, self)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- World-object / default tooltips: park them just above the deck, inside the
-- world square, where no finger ever rests.
hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tt)
	tt:ClearAllPoints()
	local anchor = WM.WorldSquare or UIParent
	tt:SetPoint("BOTTOM", anchor, "BOTTOM", 0, WM.Px(12))
end)

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
	local s = math.floor(copper / 100) % 100
	local c = copper % 100
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

-- Class color for players, reaction color for NPCs.
function WM.UnitColor(unit)
	if UnitIsPlayer(unit) then
		local _, class = UnitClass(unit)
		local c = class and RAID_CLASS_COLORS[class]
		if c then return c.r, c.g, c.b end
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
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffWowMobile|r " .. tostring(msg))
end
