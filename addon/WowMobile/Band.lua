--------------------------------------------------------------------------------
-- WowMobile · Band
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
-- visible surface to it — anything outside the crop would be invisible on the
-- phone yet still eat taps, the worst failure mode. When the window is
-- PORTRAIT (height >= width) the band is the full window and behavior is
-- exactly the pre-band layout.
--
-- This module owns the mode decision and publishes:
--   WM.Band.mode          — "band" (landscape client) | "full" (portrait)
--   WM.Band.left/right/width — band edges/width in UI units of UIParent
--   WM.Band.px            — { x, width, height } in physical client pixels
--                           (the numbers the server's crop uses verbatim);
--                           .approx is true when GetPhysicalScreenSize was
--                           unavailable and the numbers are UI units instead
--   WM.BandFrame          — insecure frame exactly covering the band; the
--                           world square and the deck anchor to it, which is
--                           what carries the entire module tree into the band
--   WM.Band.Clamp(frame)  — clamp a screen-clamped floater (tooltip, dropdown
--                           list) into the band instead of the full window
--   WM.Band.Update()      — recompute + re-anchor (mode flips ride the
--                           combat-lockdown queue like all layout work)
--
-- Inside the band the 1080x1920 design space is unchanged: WM.Px converts
-- design px against the BAND width (Core.UpdatePxFactor consults WM.Band), so
-- every module's fraction-of-design-width layout lands in the band without
-- rewriting any layout logic.
--------------------------------------------------------------------------------

local _, WM = ...

local Band = {}
WM.Band = Band

-- roundHalfToEven(num, den): num/den rounded to the nearest integer, exact
-- halves to the EVEN neighbor (banker's rounding). This is a verbatim port of
-- server/internal/window/band.go's roundHalfToEven — the normative snap of the
-- band contract — in the same pure integer arithmetic, so both sides derive
-- byte-identical crop geometry on every input (the vector check below pins the
-- parity). Band inputs keep num and den non-negative, where Lua's floor
-- division and % agree exactly with Go's truncating / and %.
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

-- Contract vectors — window WxH -> band x/width — shared verbatim with the
-- server: band_test.go's TestComputeBandFrameContractAnchors (and its odd-dims
-- test) asserts these exact numbers against the Go implementation, and
-- VerifyContract below asserts them against the Lua port at load, so the two
-- implementations cannot drift apart silently. Changing any value is a
-- cross-component protocol change.
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
	for i = 1, #CONTRACT_VECTORS do
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
-- window rect, rounded to integers so the integer contract math applies (a
-- no-op for GetPhysicalScreenSize, which reports whole pixels). Present on
-- the 1.15 (10.x-engine) client; the UIParent fallback preserves the window's
-- proportions exactly (uniform scale) but yields UI units, not physical px —
-- the third return flags that so /wm status can say the crop match is only
-- approximate.
local function ClientPixels()
	if GetPhysicalScreenSize then
		local w, h = GetPhysicalScreenSize()
		if w and h and w > 0 and h > 0 then
			return math.floor(w + 0.5), math.floor(h + 0.5), false
		end
	end
	return math.floor(UIParent:GetWidth() + 0.5),
		math.floor(UIParent:GetHeight() + 0.5), true
end

-- Recompute the published metrics from the live window dimensions. Pure math,
-- no frame mutation — always safe to run, in combat included.
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
-- intercept anything.
local bandFrame = CreateFrame("Frame", "WowMobileBand", UIParent)
bandFrame:SetFrameStrata("BACKGROUND")
bandFrame:SetFrameLevel(0)
bandFrame:EnableMouse(false)
WM.BandFrame = bandFrame

-- Plain black backdrops over the side regions outside the band (band mode
-- only). Visual only — mouse-transparent on the PC; phone taps cannot reach
-- there anyway because the stream is cropped to the band. Anchored to the
-- band frame's edges so they track every re-anchor for free.
local function CreateRail(name)
	local rail = CreateFrame("Frame", name, UIParent)
	rail:SetFrameStrata("BACKGROUND")
	rail:SetFrameLevel(0)
	rail:EnableMouse(false)
	local black = rail:CreateTexture(nil, "BACKGROUND")
	black:SetAllPoints()
	black:SetColorTexture(0, 0, 0, 1)
	rail:Hide()
	return rail
end

local leftRail = CreateRail("WowMobileBandRailLeft")
leftRail:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
leftRail:SetPoint("BOTTOMRIGHT", bandFrame, "BOTTOMLEFT", 0, 0)
local rightRail = CreateRail("WowMobileBandRailRight")
rightRail:SetPoint("TOPLEFT", bandFrame, "TOPRIGHT", 0, 0)
rightRail:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)

-- (Re-)anchor the band frame to the computed band rect. Protected frames end
-- up anchored to this frame through the square/deck chain, so after load this
-- only runs via the combat-lockdown queue (see Band.Update).
local function Anchor()
	bandFrame:ClearAllPoints()
	bandFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.left, 0)
	bandFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
		-(UIParent:GetWidth() - Band.right), 0)
	local on = Band.mode == "band"
	leftRail:SetShown(on)
	rightRail:SetShown(on)
end

--------------------------------------------------------------------------------
-- Band clamping for screen-clamped floaters (GameTooltip, dropdown lists)
--------------------------------------------------------------------------------

-- Shrink a frame's SetClampedToScreen area to the band via clamp-rect insets.
-- The insets follow the anchor-offset sign convention (+x is right, +y is
-- up), so moving a clamp edge INWARD needs a POSITIVE left/bottom inset and a
-- NEGATIVE right/top one — cf. FrameXML's
-- ChatFrame:SetClampRectInsets(-35, 35, 26, -50), which loosens (allows
-- off-screen overhang on) ALL FOUR sides. Hence +leftM tightens the left
-- clamp edge to the band's left, -rightM tightens the right edge to the
-- band's right. Insets are in the frame's own coordinate space, hence the
-- effective-scale conversion.
function Band.Clamp(frame)
	frame:SetClampedToScreen(true)
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

-- Full refresh: metrics synchronously (so the handlers that run after this
-- one — Viewport's Apply above all — already see the new band), anchors via
-- the lockdown queue (secure buttons hang off the band through the deck, so
-- moving the band frame mid-combat is anchor-restricted).
function Band.Update()
	local before = Band.mode
	Band.Compute()
	WM.UpdatePxFactor()
	WM.OutOfCombat("band", Anchor)
	if builtMode and Band.mode ~= builtMode then
		-- Anchors reflow now, but sizes built with the old px factor are stale
		-- until reload — a chat line is invisible on a phone, so raise the
		-- persistent tap-to-reload banner (Core). Re-shown on every update
		-- while flipped: the re-show re-measures against the live band, so
		-- the banner itself never goes stale. The chat line (scrollback) is
		-- printed only on the actual transition.
		local label = Band.mode == "band"
			and "landscape band" or "portrait full-window"
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

-- Load-time application runs Anchor directly: nothing protected is anchored
-- to the band frame yet (later modules haven't loaded), so this is legal even
-- during a mid-combat /reload — and the frame must be anchored before
-- Viewport.lua hangs the square off it at ITS file scope.
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
WM.On("DISPLAY_SIZE_CHANGED", Band.Update)
WM.On("UI_SCALE_CHANGED", Band.Update)
