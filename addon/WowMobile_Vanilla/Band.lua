--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Band — Lua 5.0 port of the Classic Era Band.lua:
-- the PHONE FRAME (docs/PHONE_FRAME.md).
-- The game keeps a normal widescreen window at whatever size the PC uses. The
-- whole phone UI lives in a centered portrait FRAME with the aspect of the
-- phone model picked in-game (PhoneSelect.lua; the table is Phones.lua,
-- generated from phones/phones.json). In PHYSICAL client pixels, RING = 6:
--     availW, availH = clientW - 2*RING, clientH - 2*RING
--     frameH = availH;  frameW = roundHalfToEven(availH * streamW, streamH)
--     if frameW > availW: frameW = availW; frameH = rhe(availW * streamH, streamW)
--     frameX = rhe(clientW - frameW, 2);  frameY = rhe(clientH - frameH, 2)
-- Around the frame (OUTSIDE it, never streamed) this module draws the
-- outline: outer 4 px pure red for the person at the PC, inner 2 px pure cyan
-- — the machine tag the server reads off the window to crop EXACTLY the
-- interior. So even when this client's physical-size basis is only
-- approximate (no GetPhysicalScreenSize on 1.12 — ClientPixels below), the
-- stream matches what is drawn: the server crops the drawn ring, not a
-- recomputed rect.
--
-- Publishes the same fields as the Classic Era module: WM.Band.mode ("frame"),
-- left/right/width/top/height (UI units), px {x,y,width,height,approx}, client,
-- phone, unit; WM.BandFrame; Band.Clamp, Band.Refresh (recompute + re-anchor,
-- no banner — Core's RebaseLayout/drift check), Band.Update (events: + px
-- factor + reload banner), Band.SetPhone(id), Band.SetCustom(w, h),
-- Band.OnChange(fn), Band.NeedsReload(), Band.PhoneName(p), Band.PhoneById(id).
--
-- 1.12 platform differences (all local to this file): Lua 5.0 (math.mod,
-- table.getn, string.find/len), no GetPhysicalScreenSize, no
-- SetClampRectInsets, no combat lockdown (anchoring is always legal), no
-- CVar registration, SetTexture(r,g,b,a) instead of SetColorTexture,
-- SetWidth/SetHeight instead of SetSize.
--------------------------------------------------------------------------------

local WM = WowMobile

local Band = {}
WM.Band = Band
Band.mode = "frame"

local Data = WM.PhoneData
local RING = Data.ringPx
local RING_OUTER = Data.ringOuterPx
local RING_INNER = Data.ringInnerPx

-- roundHalfToEven(num, den): num/den rounded to the nearest integer, exact
-- halves to the EVEN neighbor — the shared snap of the contract
-- (tools/genphones.js rhe, window.roundHalfToEven). Inputs are non-negative,
-- where floor and math.mod agree with Go's truncating / and %.
local function RoundHalfToEven(num, den)
	local q = math.floor(num / den)
	local r = num - q * den
	if 2 * r > den then
		return q + 1
	elseif 2 * r < den then
		return q
	end
	return q + math.mod(q, 2) -- exact half: round to even
end

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

local byId = {}
for i = 1, table.getn(Data.list) do
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
	if p.brand == "" or string.sub(p.model, 1, string.len(p.brand)) == p.brand then
		return p.model
	end
	return p.brand .. " " .. p.model
end

local function MakeCustom(w, h)
	w, h = tonumber(w), tonumber(h)
	if not w or not h then return nil end
	w, h = math.floor(w + 0.5), math.floor(h + 0.5)
	if w < 100 or h < 100 or w > 8000 or h > 8000 or h <= w then return nil end
	return { id = "custom", brand = "", model = "Custom", streamW = w, streamH = h, popularity = 0 }
end

Band.phone = byId[Data.defaultId]

-- Persistence: SavedVariables only (1.12 has no CVar registration). Loaded
-- lazily on the first Refresh after VARIABLES_LOADED — Core's RebaseLayout
-- at PLAYER_LOGIN — so the saved phone's px factor is in place before any
-- module init sizes a widget.
local function Encode(p)
	if p.id == "custom" then
		return string.format("custom:%dx%d", p.streamW, p.streamH)
	end
	return p.id
end

local function Decode(s)
	if type(s) ~= "string" or s == "" then return nil end
	local _, _, w, h = string.find(s, "^custom:(%d+)x(%d+)$")
	if w then return MakeCustom(w, h) end
	return byId[s]
end

local savedLoaded = false
local function LoadSavedOnce()
	if savedLoaded or type(WowMobileDB) ~= "table" then return end
	savedLoaded = true
	local p = Decode(WowMobileDB.phone)
	if p then Band.phone = p end
end

local function Save(p)
	if type(WowMobileDB) == "table" then
		WowMobileDB.phone = Encode(p)
	end
end

local function VerifyContract()
	local v = Data.vectors
	for i = 1, table.getn(v) do
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

-- Physical client-area pixels — the same numbers the server reads from the
-- window rect. THE CHOSEN BASIS (documented for the field): 1.12 has no
-- GetPhysicalScreenSize, so two imperfect sources exist:
--   * the gxResolution cvar — exact integers, but it is the CONFIGURED video
--     mode, not the live client area. A maximized window is the desktop
--     minus the taskbar (3840x2069 on the field 4K box, against the cvar's
--     3840x2160) — a different ASPECT — and the server crops from the LIVE
--     client rect, so a band computed from the cvar sat tens of px left of
--     the server's crop (field evidence v0.4.0: unit frame cut to "bile").
--   * UIParent's dimensions — LIVE and aspect-exact (UIParent always spans
--     the client area, uniformly scaled), but in UI units, never physical px
--     (height x effective scale is the fixed 768-unit UI space, and the
--     scale chain itself misreports on some vanilla-plus builds — the same
--     lie Viewport.lua works around). WorldFrame's pre-resize rect is the
--     render-area ground truth but is likewise in frame units: it confirms
--     the same live ASPECT, never absolute px.
-- So: the LIVE aspect decides, the cvar supplies the absolute integers.
--   basis "gxResolution" — the cvar's aspect matches the live window's
--     (within 0.4%): use the cvar verbatim; frame math is byte-identical to
--     the server's computation for the same rect.
--   basis "gx-derived"  — the aspects diverge (maximized minus taskbar, DPI
--     virtualization, a client that restored its own rect): keep the cvar's
--     WIDTH, re-derive the height from the live aspect. The resulting frame
--     FRACTIONS of the window then match the server's crop of the live rect
--     to sub-pixel — which is what aligns the layout with the stream — even
--     when the absolute px are off because the width changed too.
--   basis "ui"          — no readable cvar: UI units verbatim (aspect still
--     exact, so the layout is right; only the printed px are approximate).
-- Returns pw, ph, basis; Band.px.approx stays true only for "ui".
local function ClientPixels()
	local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
	local gw, gh
	-- Cleared before the read so /wm status always reflects the read that
	-- produced the CHOSEN basis — never a stale value from an earlier call.
	Band.gxRaw = nil
	if GetCVar then
		local ok, res = pcall(GetCVar, "gxResolution")
		if ok and type(res) == "string" then
			Band.gxRaw = res -- verbatim cvar text for /wm status
			local _, _, w, h = string.find(res, "^(%d+)x(%d+)$")
			gw, gh = tonumber(w), tonumber(h)
		end
	end
	if gw and gh and gw > 0 and gh > 0 and uiW > 0 and uiH > 0 then
		local rel = (gw / gh) / (uiW / uiH)
		if rel > 0.996 and rel < 1.004 then
			return gw, gh, "gxResolution"
		end
		return gw, math.floor(gw * uiH / uiW + 0.5), "gx-derived"
	end
	return math.floor(uiW + 0.5), math.floor(uiH + 0.5), "ui"
end

-- Recompute the published metrics. Pure math, no frame mutation.
function Band.Compute()
	local pw, ph, basis = ClientPixels()
	local approx = basis == "ui"
	local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
	Band.client = { w = pw, h = ph, basis = basis }
	local p = Band.phone
	local x, y, w, h = FrameRect(pw, ph, p.streamW, p.streamH)
	if not x then
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

local function CreateRail(name)
	local rail = CreateFrame("Frame", name, UIParent)
	rail:SetFrameStrata("BACKGROUND")
	rail:SetFrameLevel(0)
	rail:EnableMouse(false)
	local black = rail:CreateTexture(nil, "BACKGROUND")
	black:SetAllPoints(rail)
	black:SetTexture(0, 0, 0, 1) -- 1.12: SetTexture(r,g,b,a) is the flat fill
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

-- The outline: 8 strips (4 red, 4 cyan) at whole physical pixels.
local outline = CreateFrame("Frame", "WowMobilePhoneOutline", UIParent)
outline:SetFrameStrata("BACKGROUND")
outline:SetFrameLevel(5)
outline:EnableMouse(false)
outline:SetAllPoints(UIParent)

local function Strip(r, g, b)
	local t = outline:CreateTexture(nil, "OVERLAY")
	t:SetTexture(r, g, b, 1)
	return t
end

local red = { Strip(1, 0, 0), Strip(1, 0, 0), Strip(1, 0, 0), Strip(1, 0, 0) }
local cyan = { Strip(0, 1, 1), Strip(0, 1, 1), Strip(0, 1, 1), Strip(0, 1, 1) }

local function Put(s, px, py, pw, ph)
	local u = Band.unit
	s:ClearAllPoints()
	s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", px * u, -py * u)
	s:SetWidth(pw * u)
	s:SetHeight(ph * u)
end

-- A ring of thickness t (px) whose inner edge is `inset` px outside the frame.
local function PlaceRing(strips, x, y, w, h, inset, t)
	local ox, oy = x - inset - t, y - inset - t
	local ow, oh = w + 2 * (inset + t), h + 2 * (inset + t)
	Put(strips[1], ox, oy, ow, t)
	Put(strips[2], ox, oy + oh - t, ow, t)
	Put(strips[3], ox, oy + t, t, oh - 2 * t)
	Put(strips[4], ox + ow - t, oy + t, t, oh - 2 * t)
end

local function DrawOutline()
	local p = Band.px
	PlaceRing(cyan, p.x, p.y, p.width, p.height, 0, RING_INNER)
	PlaceRing(red, p.x, p.y, p.width, p.height, RING_INNER, RING_OUTER)
end

-- (Re-)anchor the frame. No combat lockdown on 1.12: legal at any time.
local function Anchor()
	bandFrame:ClearAllPoints()
	bandFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.left, -Band.top)
	bandFrame:SetWidth(Band.width)
	bandFrame:SetHeight(Band.height)
	DrawOutline()
end

--------------------------------------------------------------------------------
-- Clamping for screen-clamped floaters
--------------------------------------------------------------------------------

-- Best effort on 1.12: SetClampRectInsets does not exist here (a 2.x API), so
-- a floater can only be clamped to the WINDOW; callers that must stay inside
-- the frame (the boosted unit dropdown) clamp against WM.Band.left/right
-- manually (UnitFrames.lua). The probe keeps builds exposing the API right.
function Band.Clamp(frame)
	if frame.SetClampedToScreen then
		frame:SetClampedToScreen(true)
	end
	if not frame.SetClampRectInsets then
		return
	end
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
	table.insert(listeners, fn)
end

-- The frame width (UI units) this session's WM.Px sizes were built for, set
-- at PLAYER_LOGIN (first OnInit). A phone with another aspect leaves them
-- stale until /reload; a window resize barely moves it (1% tolerance).
local builtWidth

function Band.NeedsReload()
	return builtWidth ~= nil and math.abs(Band.width - builtWidth) > builtWidth * 0.01
end

-- Banner-free refresh: metrics + anchors from the live window. Core's
-- RebaseLayout runs it right before module inits size their frames (the
-- saved phone is picked up here, SavedVariables being loaded by then).
function Band.Refresh()
	LoadSavedOnce()
	Band.Compute()
	Anchor()
end

-- Full refresh for the event paths: + px factor, reload banner, listeners.
function Band.Update()
	Band.Refresh()
	WM.UpdatePxFactor()
	if Band.NeedsReload() then
		WM.ShowSetupBanner(string.format(
			"Phone frame changed to %s — tap to rebuild the touch layout.",
			Band.PhoneName(Band.phone)), "band-mode")
	else
		WM.HideSetupBanner("band-mode")
	end
	for i = 1, table.getn(listeners) do
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

function Band.SetPhone(id, silent)
	local p = byId[id]
	if not p then return false end
	Apply(p, silent)
	return true
end

function Band.SetCustom(w, h)
	local p = MakeCustom(w, h)
	if not p then return false end
	Apply(p)
	return true
end

-- Load-time application with the default phone: the frame must be anchored
-- before Viewport.lua hangs the square off it at ITS file scope.
Band.Compute()
Anchor()
WM.UpdatePxFactor()
VerifyContract()

-- First OnInit (TOC order): RebaseLayout has just refreshed the metrics with
-- the saved phone, so this width is what every module is about to size for.
WM.OnInit(function()
	builtWidth = Band.width
end)

-- Registered before Viewport's handlers for the same events (.toc order).
-- TryOn: a bare 1.12 build lacks these events — then the drift check's
-- timer/loading-screen path (Core) is what re-runs Band.Refresh.
WM.TryOn("DISPLAY_SIZE_CHANGED", Band.Update)
WM.TryOn("UI_SCALE_CHANGED", Band.Update)
