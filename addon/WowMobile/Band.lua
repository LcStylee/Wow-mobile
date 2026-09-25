--------------------------------------------------------------------------------
-- WowMobile · Band — the PHONE FRAME (docs/PHONE_FRAME.md)
-- The game keeps a normal widescreen window at whatever size the PC uses (4K
-- fullscreen, 1080p, an odd windowed size). The whole phone UI lives in a
-- centered portrait FRAME with the aspect of the phone model picked in-game
-- (PhoneSelect.lua; the table is Phones.lua, generated from
-- phones/phones.json). In PHYSICAL client pixels, with RING = 6:
--     availW, availH = clientW - 2*RING, clientH - 2*RING
--     frameH = availH;  frameW = roundHalfToEven(availH * streamW, streamH)
--     if frameW > availW: frameW = availW; frameH = rhe(availW * streamH, streamW)
--     frameX = rhe(clientW - frameW, 2);  frameY = rhe(clientH - frameH, 2)
-- Around the frame (OUTSIDE it, so never part of the stream) this module
-- draws the outline: outer 4 px pure red, inner 2 px pure cyan. The red is
-- for the person at the PC — "your phone screen is in here" — and the cyan is
-- the machine tag the server reads off the window to crop EXACTLY the
-- interior, so the stream always matches what the addon drew, whatever the
-- resolution, UI scale or phone.
--
-- This module publishes:
--   WM.Band.mode          — "frame" (always; kept for older consumers)
--   WM.Band.left/right/width/top/height — frame rect in UI units of UIParent
--                           (top = distance from the window top)
--   WM.Band.px            — { x, y, width, height } in physical client px;
--                           .approx when GetPhysicalScreenSize was missing
--   WM.Band.client        — { w, h, basis } the physical client size used
--   WM.Band.phone         — the active phone entry { id, brand, model,
--                           streamW, streamH, ... } (custom: id "custom")
--   WM.BandFrame          — insecure frame exactly covering the frame rect;
--                           the world square and the deck anchor to it
--   WM.Band.Clamp(frame)  — clamp a screen-clamped floater into the frame
--   WM.Band.Update()      — recompute + re-anchor (combat-queued)
--   WM.Band.SetPhone(id)  — pick a phone by id (persisted); SetCustom(w, h)
--   WM.Band.OnChange(fn)  — fn() after every recompute (the selector panel)
--
-- Inside the frame the 1080-wide design space is unchanged: WM.Px converts
-- design px against the FRAME width (Core.UpdatePxFactor), so every module's
-- fraction-of-design-width layout lands in the frame without rewriting any
-- layout logic; a taller phone simply gets a taller deck.
--------------------------------------------------------------------------------

local _, WM = ...

local Band = {}
WM.Band = Band
Band.mode = "frame"

local Data = WM.PhoneData
local RING = Data.ringPx
local RING_OUTER = Data.ringOuterPx
local RING_INNER = Data.ringInnerPx

-- roundHalfToEven(num, den): num/den rounded to the nearest integer, exact
-- halves to the EVEN neighbor (banker's rounding) — the shared snap of the
-- contract (tools/genphones.js rhe, window.roundHalfToEven), pure integer
-- arithmetic so every component derives byte-identical geometry. Inputs are
-- non-negative, where Lua's floor division and % agree with Go's.
local function RoundHalfToEven(num, den)
	local q = math.floor(num / den)
	local r = num - q * den
	if 2 * r > den then
		return q + 1
	elseif 2 * r < den then
		return q
	end
	return q + q % 2 -- exact half: round to even
end

-- Frame placement (the contract above). Returns nil for a degenerate window.
local function FrameRect(clientW, clientH, sw, sh)
	local availW, availH = clientW - 2 * RING, clientH - 2 * RING
	if availW < 16 or availH < 16 then return nil end
	local h = availH
	local w = RoundHalfToEven(availH * sw, sh)
	if w > availW then
		w = availW
		h = RoundHalfToEven(availW * sh, sw)
	end
	return RoundHalfToEven(clientW - w, 2), RoundHalfToEven(clientH - h, 2), w, h
end
Band.FrameRect = FrameRect

-- Phone lookup ---------------------------------------------------------------

local byId = {}
for i = 1, #Data.list do
	byId[Data.list[i].id] = Data.list[i]
end

function Band.PhoneById(id)
	return byId[id]
end

function Band.PhoneName(p)
	if not p then return "?" end
	if p.id == "custom" then
		return string.format("Custom %dx%d", p.streamW, p.streamH)
	end
	if p.brand == "" or string.sub(p.model, 1, #p.brand) == p.brand then
		return p.model
	end
	return p.brand .. " " .. p.model
end

-- Custom sizes are validated to a sane portrait aspect (the stream must stay
-- portrait: the deck layout needs height > width).
local function MakeCustom(w, h)
	w, h = tonumber(w), tonumber(h)
	if not w or not h then return nil end
	w, h = math.floor(w + 0.5), math.floor(h + 0.5)
	if w < 100 or h < 100 or w > 8000 or h > 8000 or h <= w then return nil end
	return { id = "custom", brand = "", model = "Custom", streamW = w, streamH = h, popularity = 0 }
end

Band.phone = byId[Data.defaultId]

-- Persistence. SavedVariables are the store; the WoW: Forever beta has been
-- seen dropping addon SavedVariables between sessions, so the choice is also
-- mirrored into an addon-registered CVar where the client supports them
-- (C_CVar.RegisterCVar, modern API — Forever/Classic 1.15). Both reads are
-- best-effort; the default phone is the floor.
local CVAR = "wowMobilePhone"
local cvarReady = false
if C_CVar and C_CVar.RegisterCVar then
	cvarReady = pcall(C_CVar.RegisterCVar, CVAR, "")
end

local function Encode(p)
	if p.id == "custom" then
		return string.format("custom:%dx%d", p.streamW, p.streamH)
	end
	return p.id
end

local function Decode(s)
	if type(s) ~= "string" or s == "" then return nil end
	local w, h = string.match(s, "^custom:(%d+)x(%d+)$")
	if w then return MakeCustom(w, h) end
	return byId[s]
end

local function LoadSaved()
	local p = Decode(WM.db and WM.db.phone)
	if not p and cvarReady and C_CVar.GetCVar then
		local ok, v = pcall(C_CVar.GetCVar, CVAR)
		if ok then p = Decode(v) end
	end
	return p
end

local function Save(p)
	local s = Encode(p)
	if WM.db then WM.db.phone = s end
	if cvarReady and C_CVar.SetCVar then
		pcall(C_CVar.SetCVar, CVAR, s)
	end
end

-- Contract vectors (generated into Phones.lua from phones/contract_vectors.json,
-- asserted by the server, the generator and the client too).
local function VerifyContract()
	local v = Data.vectors
	for i = 1, #v do
		local p = byId[v[i][1]]
		local x, y, w, h = FrameRect(v[i][2], v[i][3], p.streamW, p.streamH)
		if x ~= v[i][4] or y ~= v[i][5] or w ~= v[i][6] or h ~= v[i][7] then
			WM.ReportError(string.format(
				"Band.lua: phone-frame vector %s %dx%d expects %d,%d %dx%d, got %s,%s %sx%s",
				v[i][1], v[i][2], v[i][3], v[i][4], v[i][5], v[i][6], v[i][7],
				tostring(x), tostring(y), tostring(w), tostring(h)))
			return
		end
	end
end

-- Physical client-area pixels — the numbers the server reads from the window.
-- GetPhysicalScreenSize is live on the 1.15 and Forever clients; the UIParent
-- fallback keeps the window's proportions (uniform scale) but yields UI units,
-- flagged approx (the server reads the outline anyway, so the stream still
-- matches what is drawn).
local function ClientPixels()
	if GetPhysicalScreenSize then
		local w, h = GetPhysicalScreenSize()
		if w and h and w > 0 and h > 0 then
			return math.floor(w + 0.5), math.floor(h + 0.5), false, "GetPhysicalScreenSize"
		end
	end
	return math.floor(UIParent:GetWidth() + 0.5),
		math.floor(UIParent:GetHeight() + 0.5), true, "ui"
end

-- Recompute the published metrics. Pure math, no frame mutation.
function Band.Compute()
	local pw, ph, approx, basis = ClientPixels()
	local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
	Band.client = { w = pw, h = ph, basis = basis }
	local p = Band.phone
	local x, y, w, h = FrameRect(pw, ph, p.streamW, p.streamH)
	if not x then
		-- Degenerate window (minimized race): the whole window, no ring.
		x, y, w, h = 0, 0, pw, ph
	end
	local unit = uiW / pw -- UI units per physical px (uniform scale)
	Band.unit = unit
	Band.px = { x = x, y = y, width = w, height = h, approx = approx }
	Band.left = x * unit
	Band.width = w * unit
	Band.right = Band.left + Band.width
	Band.top = y * unit
	Band.height = h * unit
	if Band.top + Band.height > uiH then Band.height = uiH - Band.top end
end

--------------------------------------------------------------------------------
-- Frame, rails, outline
--------------------------------------------------------------------------------

-- Anchor host for the whole UI (world square on top, deck below).
-- Mouse-disabled: it must never intercept anything.
local bandFrame = CreateFrame("Frame", "WowMobileBand", UIParent)
bandFrame:SetFrameStrata("BACKGROUND")
bandFrame:SetFrameLevel(0)
bandFrame:EnableMouse(false)
WM.BandFrame = bandFrame

-- Black backdrops around the frame (PC-only area). Visual only.
local function CreateRail(name)
	local rail = CreateFrame("Frame", name, UIParent)
	rail:SetFrameStrata("BACKGROUND")
	rail:SetFrameLevel(0)
	rail:EnableMouse(false)
	local black = rail:CreateTexture(nil, "BACKGROUND")
	black:SetAllPoints()
	black:SetColorTexture(0, 0, 0, 1)
	return rail
end

local leftRail = CreateRail("WowMobileBandRailLeft")
leftRail:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
leftRail:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
leftRail:SetPoint("RIGHT", bandFrame, "LEFT", 0, 0)
local rightRail = CreateRail("WowMobileBandRailRight")
rightRail:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
rightRail:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
rightRail:SetPoint("LEFT", bandFrame, "RIGHT", 0, 0)
local topRail = CreateRail("WowMobileBandRailTop")
topRail:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
topRail:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
topRail:SetPoint("BOTTOM", bandFrame, "TOP", 0, 0)
local bottomRail = CreateRail("WowMobileBandRailBottom")
bottomRail:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
bottomRail:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
bottomRail:SetPoint("TOP", bandFrame, "BOTTOM", 0, 0)
Band.rightRail, Band.leftRail = rightRail, leftRail

-- The outline: one frame above the rails holding 8 strips (4 red, 4 cyan).
-- Positions are whole physical pixels times the UI unit, so every edge lands
-- on a pixel boundary; pixel snapping is disabled where the client has it,
-- so the engine never nudges a strip by a pixel and blends the colours.
local outline = CreateFrame("Frame", "WowMobilePhoneOutline", UIParent)
outline:SetFrameStrata("BACKGROUND")
outline:SetFrameLevel(5)
outline:EnableMouse(false)
outline:SetAllPoints(UIParent)

local function Strip(r, g, b)
	local t = outline:CreateTexture(nil, "OVERLAY")
	t:SetColorTexture(r, g, b, 1)
	if t.SetSnapToPixelGrid then
		t:SetSnapToPixelGrid(false)
		t:SetTexelSnappingBias(0)
	end
	return t
end

local red = { Strip(1, 0, 0), Strip(1, 0, 0), Strip(1, 0, 0), Strip(1, 0, 0) }
local cyan = { Strip(0, 1, 1), Strip(0, 1, 1), Strip(0, 1, 1), Strip(0, 1, 1) }

-- Place a ring of thickness t (px) whose inner edge is `inset` px outside the
-- frame rect (x, y, w, h in px): top, bottom, left, right strips.
local function PlaceRing(strips, x, y, w, h, inset, t)
	local u = Band.unit
	local ox, oy = x - inset - t, y - inset - t -- outer top-left
	local ow, oh = w + 2 * (inset + t), h + 2 * (inset + t)
	local function put(s, px, py, pw, ph)
		s:ClearAllPoints()
		s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", px * u, -py * u)
		s:SetSize(pw * u, ph * u)
	end
	put(strips[1], ox, oy, ow, t)              -- top
	put(strips[2], ox, oy + oh - t, ow, t)     -- bottom
	put(strips[3], ox, oy + t, t, oh - 2 * t)  -- left
	put(strips[4], ox + ow - t, oy + t, t, oh - 2 * t) -- right
end

local function DrawOutline()
	local p = Band.px
	PlaceRing(cyan, p.x, p.y, p.width, p.height, 0, RING_INNER)
	PlaceRing(red, p.x, p.y, p.width, p.height, RING_INNER, RING_OUTER)
	outline:Show()
end

-- (Re-)anchor the frame to the computed rect. Protected frames hang off it
-- through the square/deck chain, so after load this runs via the lockdown
-- queue (Band.Update). The outline is insecure and redraws immediately.
local function Anchor()
	bandFrame:ClearAllPoints()
	bandFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.left, -Band.top)
	bandFrame:SetSize(Band.width, Band.height)
end

--------------------------------------------------------------------------------
-- Clamping for screen-clamped floaters (GameTooltip, dropdown lists)
--------------------------------------------------------------------------------

-- Shrink a frame's SetClampedToScreen area to the frame via clamp-rect
-- insets (+x right, +y up: a positive left/bottom and negative right/top
-- inset move the clamp edge inward), in the frame's own coordinate space.
function Band.Clamp(frame)
	frame:SetClampedToScreen(true)
	local s = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
	local leftM = Band.left
	local rightM = UIParent:GetWidth() - Band.right
	local topM = Band.top
	local bottomM = UIParent:GetHeight() - Band.top - Band.height
	frame:SetClampRectInsets(leftM * s, -rightM * s, -topM * s, bottomM * s)
end

--------------------------------------------------------------------------------
-- Update flow
--------------------------------------------------------------------------------

local listeners = {}
function Band.OnChange(fn)
	listeners[#listeners + 1] = fn
end

-- The frame width (UI units) every widget's WM.Px size was built for this
-- session, set when the layout is built (PLAYER_LOGIN). A different phone
-- aspect changes it and leaves fixed-size widgets stale until /reload. A
-- window resize barely moves it (the UI-unit height is fixed; only the
-- 6-physical-px ring margin shifts), hence the 1% tolerance.
local builtWidth

function Band.NeedsReload()
	return builtWidth ~= nil and math.abs(Band.width - builtWidth) > builtWidth * 0.01
end

function Band.Update()
	Band.Compute()
	WM.UpdatePxFactor()
	DrawOutline()
	WM.OutOfCombat("band", Anchor)
	if Band.NeedsReload() then
		WM.ShowSetupBanner(string.format(
			"Phone frame changed to %s — tap to rebuild the touch layout.",
			Band.PhoneName(Band.phone)), "band-mode")
	else
		WM.HideSetupBanner("band-mode")
	end
	for i = 1, #listeners do
		local ok, err = pcall(listeners[i])
		if not ok then WM.ReportError(err) end
	end
end

local function Apply(p, silent)
	Band.phone = p
	Save(p)
	Band.Update()
	if not silent then
		WM.Print(string.format("phone: %s — frame %dx%d px of %dx%d",
			Band.PhoneName(p), Band.px.width, Band.px.height, Band.client.w, Band.client.h))
	end
end

-- Select a phone by id; returns false for an unknown id.
function Band.SetPhone(id, silent)
	local p = byId[id]
	if not p then return false end
	Apply(p, silent)
	return true
end

-- Select a custom portrait stream size (e.g. a phone not in the table).
function Band.SetCustom(w, h)
	local p = MakeCustom(w, h)
	if not p then return false end
	Apply(p)
	return true
end

-- Load-time application with the default phone: nothing protected hangs off
-- the frame yet, so anchoring directly is legal even during a mid-combat
-- /reload — and the frame must be anchored before Viewport.lua hangs the
-- square off it at ITS file scope.
Band.Compute()
Anchor()
DrawOutline()
WM.UpdatePxFactor()
VerifyContract()

-- SavedVariables are loaded by PLAYER_LOGIN; this OnInit runs before every
-- later module's (TOC order), so the saved phone's px factor is in place
-- before any widget is sized. Anchoring directly is still legal: the layout
-- modules have not built their secure frames yet.
WM.OnInit(function()
	local p = LoadSaved()
	if p then Band.phone = p end
	Band.Compute()
	Anchor()
	DrawOutline()
	WM.UpdatePxFactor()
	builtWidth = Band.width
	for i = 1, #listeners do
		pcall(listeners[i])
	end
end)

-- Registered before Viewport's handlers for the same events (.toc order), so
-- the metrics are fresh by the time Viewport re-applies the square.
WM.On("DISPLAY_SIZE_CHANGED", Band.Update)
WM.On("UI_SCALE_CHANGED", Band.Update)
