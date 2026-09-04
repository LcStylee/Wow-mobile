--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Band — Lua 5.0 port of the Classic Era Band.lua
-- THE BAND CONTRACT (shared with the server — deterministic, no protocol
-- change): when the game window's client area is LANDSCAPE (width > height),
-- the touch experience lives in a centered 9:16 portrait band computed, in
-- PHYSICAL client pixels, as
--     bandHeight = clientHeight
--     bandWidth  = roundHalfToEven(clientHeight * 9, 16)
--     bandX      = roundHalfToEven(clientWidth - bandWidth, 2)
--     bandY      = 0
-- The server crops the stream to this exact rect and the hello reports the
-- band dimensions, so the phone client is unchanged; the addon computes the
-- same rect INDEPENDENTLY from the same window dimensions and confines every
-- visible surface to it — anything outside the crop is invisible on the
-- phone. When the window is PORTRAIT (height >= width) the band is the full
-- window and behavior is exactly the pre-band layout. Band layout is the
-- server default for this 1.12-engine client (resolveLayout: the field 1.12
-- client rejects portrait render resolutions, so the wizard writes a native
-- landscape gxResolution and this module carries the deck into the band).
--
-- This module owns the mode decision and publishes:
--   WM.Band.mode          — "band" (landscape client) | "full" (portrait)
--   WM.Band.left/right/width — band edges/width in UI units of UIParent
--   WM.Band.px            — { x, width, height } in physical client pixels
--                           (the numbers the server's crop uses verbatim);
--                           .approx is true when the gxResolution cvar was
--                           unreadable and the numbers are UI units instead
--   WM.BandFrame          — mouse-disabled frame exactly covering the band;
--                           the world square and the deck anchor to it, which
--                           is what carries the entire module tree into the
--                           band
--   WM.Band.Clamp(frame)  — best-effort clamp of a floater toward the band
--                           (1.12 degrades to plain screen clamping — below)
--   WM.Band.Refresh()     — recompute + re-anchor, no banner logic (Core's
--                           RebaseLayout / drift check)
--   WM.Band.Update()      — Refresh + px factor + mode-flip banner (events)
--
-- Inside the band the 1080x1920 design space is unchanged: WM.Px converts
-- design px against the BAND width (Core's WM.UpdatePxFactor consults
-- WM.Band), so every module's fraction-of-design-width layout lands in the
-- band without rewriting any layout logic.
--
-- 1.12 platform differences from the Classic Era original (all local to this
-- file): Lua 5.0 (math.mod for '%', table.getn for '#', string.find for
-- string.match, no addon vararg), no GetPhysicalScreenSize (the gxResolution
-- cvar carries the physical client size instead), no SetClampRectInsets, no
-- combat lockdown (frame anchoring is legal at any time, so there is no
-- out-of-combat queue), SetTexture(r,g,b,a) instead of SetColorTexture.
--------------------------------------------------------------------------------

local WM = WowMobile

local Band = {}
WM.Band = Band

-- roundHalfToEven(num, den): num/den rounded to the nearest integer, exact
-- halves to the EVEN neighbor (banker's rounding). This is a verbatim port of
-- server/internal/window/band.go's roundHalfToEven — the normative snap of
-- the band contract — in the same pure integer arithmetic, so both sides
-- derive byte-identical crop geometry on every input (the vector check below
-- pins the parity). Band inputs keep num and den non-negative, where Lua's
-- floor and math.mod agree exactly with Go's truncating / and % (q is never
-- negative here, so math.mod(q, 2) is the plain parity bit).
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

-- Contract vectors — window WxH -> band x/width — shared verbatim with the
-- server: band_test.go's TestComputeBandFrameContractAnchors (and its odd-dims
-- test) asserts these exact numbers against the Go implementation, and the
-- Classic Era Band.lua carries the same table, and VerifyContract below
-- asserts them against this Lua 5.0 port at load — so the implementations
-- cannot drift apart silently. Changing any value is a cross-component
-- protocol change.
local CONTRACT_VECTORS = {
	-- { clientW, clientH, bandX, bandW }
	{ 1280, 720, 438, 405 },   -- the e2e scenario (720p)
	{ 1920, 1080, 656, 608 },  -- 1080p: 607.5 -> even neighbor 608
	{ 3840, 2160, 1312, 1215 },-- 4K: the ARCHITECTURE.md example (odd width!)
	{ 2560, 1440, 875, 810 },  -- 1440p: x 875 exact (odd x)
	{ 3413, 1920, 1166, 1080 },-- band == design space
	{ 1281, 719, 438, 404 },   -- odd window dims (band_test.go odd-dims case)
	-- Additional addon-side spot checks (values from the Go implementation).
	{ 1366, 768, 467, 432 },
	{ 1600, 900, 547, 506 },
	{ 1920, 1200, 622, 675 },  -- x 622.5 -> even neighbor 622
	{ 3440, 1440, 1315, 810 },
}

local function VerifyContract()
	for i = 1, table.getn(CONTRACT_VECTORS) do
		local v = CONTRACT_VECTORS[i]
		local w = RoundHalfToEven(v[2] * 9, 16)
		local x = RoundHalfToEven(v[1] - w, 2)
		if x ~= v[3] or w ~= v[4] then
			WM.ReportError(string.format(
				"Band.lua: band contract vector %dx%d expects x=%d w=%d, got x=%d w=%d — layout would not match the server's crop",
				v[1], v[2], v[3], v[4], x, w))
			return
		end
	end
end

-- Physical client-area pixels — the same numbers the server reads from the
-- window rect. 1.12 has no GetPhysicalScreenSize; the gxResolution cvar IS
-- the client area of a windowed 1.12 session (the wizard writes it, and the
-- in-game video options keep it current), parsed here as "WxH". The UIParent
-- fallback preserves the window's proportions exactly (uniform scale) but
-- yields UI units, not physical px — the third return flags that so
-- /wm status can say the crop match is only approximate.
local function ClientPixels()
	if GetCVar then
		local ok, res = pcall(GetCVar, "gxResolution")
		if ok and type(res) == "string" then
			local _, _, w, h = string.find(res, "^(%d+)x(%d+)$")
			w, h = tonumber(w), tonumber(h)
			if w and h and w > 0 and h > 0 then
				return w, h, false
			end
		end
	end
	return math.floor(UIParent:GetWidth() + 0.5),
		math.floor(UIParent:GetHeight() + 0.5), true
end

-- Recompute the published metrics from the live window dimensions. Pure math,
-- no frame mutation — always safe to run.
function Band.Compute()
	local pw, ph, approx = ClientPixels()
	local uiW = UIParent:GetWidth()
	if pw > ph then
		-- Landscape client area: centered 9:16 band (the contract above).
		local bandW = RoundHalfToEven(ph * 9, 16)
		local bandX = RoundHalfToEven(pw - bandW, 2)
		local unit = uiW / pw -- UI units per physical px (uniform scale)
		Band.mode = "band"
		Band.px = { x = bandX, width = bandW, height = ph, approx = approx }
		Band.left = bandX * unit
		Band.width = bandW * unit
		Band.right = Band.left + Band.width
	else
		-- Portrait client area: full-window mode, exactly the pre-band layout.
		Band.mode = "full"
		Band.px = { x = 0, width = pw, height = ph, approx = approx }
		Band.left = 0
		Band.width = uiW
		Band.right = uiW
	end
end

--------------------------------------------------------------------------------
-- Band frame + side rails
--------------------------------------------------------------------------------

-- Anchor host for the whole UI: Viewport hangs the world square off its top
-- edge and Deck fills it below the square, so re-anchoring THIS frame is the
-- single move that relocates every surface. Mouse-disabled: it must never
-- intercept anything (phone taps are injected into the band, but the PC's
-- own mouse works too).
local bandFrame = CreateFrame("Frame", "WowMobileBand", UIParent)
bandFrame:SetFrameStrata("BACKGROUND")
bandFrame:SetFrameLevel(0)
bandFrame:EnableMouse(false)
WM.BandFrame = bandFrame

-- Plain black backdrops over the side regions outside the band (band mode
-- only). Visual only — mouse-transparent on the PC; phone taps cannot reach
-- there anyway because input injection maps into the band. Anchored to the
-- band frame's edges so they track every re-anchor for free.
local function CreateRail(name)
	local rail = CreateFrame("Frame", name, UIParent)
	rail:SetFrameStrata("BACKGROUND")
	rail:SetFrameLevel(0)
	rail:EnableMouse(false)
	local black = rail:CreateTexture(nil, "BACKGROUND")
	black:SetAllPoints(rail)
	black:SetTexture(0, 0, 0, 1) -- 1.12: SetTexture(r,g,b,a) is the flat fill
	rail:Hide()
	return rail
end

local leftRail = CreateRail("WowMobileBandRailLeft")
leftRail:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
leftRail:SetPoint("BOTTOMRIGHT", bandFrame, "BOTTOMLEFT", 0, 0)
local rightRail = CreateRail("WowMobileBandRailRight")
rightRail:SetPoint("TOPLEFT", bandFrame, "TOPRIGHT", 0, 0)
rightRail:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)

-- (Re-)anchor the band frame to the computed band rect. 1.12 has no combat
-- lockdown/protected frames, so this is legal at any time — no out-of-combat
-- queue (the Classic Era original needs one).
local function Anchor()
	bandFrame:ClearAllPoints()
	bandFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.left, 0)
	bandFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
		-(UIParent:GetWidth() - Band.right), 0)
	local on = Band.mode == "band"
	WM.SetShown(leftRail, on)
	WM.SetShown(rightRail, on)
end

--------------------------------------------------------------------------------
-- Band clamping for screen-clamped floaters
--------------------------------------------------------------------------------

-- Best effort on 1.12: SetClampRectInsets does not exist here (it is a 2.x
-- API), so a floater can only be clamped to the WINDOW, not shrunk to the
-- band — exactly the pre-band behavior, never worse. The method probes keep
-- this correct on any client build; callers that must stay inside the band
-- (the boosted unit dropdown) clamp their anchor point against
-- WM.Band.left/right manually instead (UnitFrames.lua).
function Band.Clamp(frame)
	if frame.SetClampedToScreen then
		frame:SetClampedToScreen(true)
	end
	if not frame.SetClampRectInsets then
		return
	end
	-- Future-proofing for builds that do expose the 2.x API. The insets
	-- follow the anchor-offset sign convention (+x right, +y up), so an
	-- INWARD clamp edge needs a POSITIVE left inset and a NEGATIVE right one
	-- (cf. FrameXML's ChatFrame:SetClampRectInsets(-35, 35, 26, -50), which
	-- loosens all four sides). Insets are in the frame's own coordinate
	-- space, hence the scale conversion.
	local leftM = Band.left
	local rightM = UIParent:GetWidth() - Band.right
	if leftM > 0 or rightM > 0 then
		local s = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
		frame:SetClampRectInsets(leftM * s, -rightM * s, 0, 0)
	else
		frame:SetClampRectInsets(0, 0, 0, 0)
	end
end

--------------------------------------------------------------------------------
-- Update flow
--------------------------------------------------------------------------------

-- The mode every widget's WM.Px size was built for this session (set once at
-- load below). A live flip away from it leaves fixed-size widgets stale —
-- overlapping tap targets inside the band — until /reload.
local builtMode

-- Banner-free refresh: metrics + anchors from the live window. Safe at any
-- time on 1.12. Core's RebaseLayout runs it right before module inits size
-- their frames, and the drift check (WM.CheckLayoutFresh) runs it before
-- re-applying the viewport, so the square math always sees fresh band edges.
function Band.Refresh()
	Band.Compute()
	Anchor()
end

-- Full refresh for the event paths: metrics/anchors, the px factor (newly
-- created widgets size against the fresh band), and the mode-flip banner.
function Band.Update()
	local before = Band.mode
	Band.Refresh()
	WM.UpdatePxFactor()
	if builtMode and Band.mode ~= builtMode then
		-- Anchors reflowed above, but sizes built with the old px factor are
		-- stale until reload — a chat line is invisible on a phone, so raise
		-- the persistent tap-to-reload banner (Core). Re-shown on every update
		-- while flipped: the re-show re-measures against the live band, so
		-- the banner itself never goes stale. The chat line (scrollback) is
		-- printed only on the actual transition.
		local label
		if Band.mode == "band" then
			label = "landscape band"
		else
			label = "portrait full-window"
		end
		WM.ShowSetupBanner(string.format(
			"Window switched to %s mode — the touch layout must be rebuilt.",
			label), "band-mode")
		if before ~= Band.mode then
			WM.Print(string.format(
				"window switched to %s mode — tap the banner (or /wm reload) to re-lay-out the deck",
				label))
		end
	else
		-- Back on the mode the layout was built for: sizes are correct again,
		-- so clear our own banner (never another raiser's).
		WM.HideSetupBanner("band-mode")
	end
end

-- Load-time application: the frame must be anchored before Viewport.lua hangs
-- the square off it at ITS file scope, and the px factor must be band-aware
-- before any module calls WM.Px.
Band.Compute()
builtMode = Band.mode -- the mode this session's WM.Px sizes are built for
Anchor()
WM.UpdatePxFactor()
-- Assert the shared contract vectors against the Lua port (reports a module
-- error + red banner on mismatch — deterministic, so this only fires if an
-- edit drifts the formula away from band.go's).
VerifyContract()

-- Registered before Viewport's handlers for the same events (.toc order), so
-- the band metrics are fresh by the time Viewport re-applies the square.
-- TryOn: a bare 1.12 build lacks these events — then the drift check's
-- timer/loading-screen path (Core) is what re-runs Band.Refresh.
WM.TryOn("DISPLAY_SIZE_CHANGED", Band.Update)
WM.TryOn("UI_SCALE_CHANGED", Band.Update)
