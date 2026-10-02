--------------------------------------------------------------------------------
-- WowMobile · Config
-- SavedVariables handling (WowMobileDB), the /wm slash command and the
-- programmatic setters the Settings panel drives.
--------------------------------------------------------------------------------

local ADDON_NAME, WM = ...

local Config = {}
WM.Config = Config

Config.defaults = {
	viewport = {
		-- World-square height in design px of the 1080-wide window (1080 =
		-- square). This exact key — `viewport.height`, default 1080 — is the
		-- knob docs/ARCHITECTURE.md §1 documents for external tooling; it is
		-- converted to a width fraction internally (see Viewport.Apply) so it
		-- scales to any real capture resolution.
		height = 1080,
	},
	-- uiScale cvar override; nil = leave the user's cvar untouched.
	uiScale = nil,
}

-- Design width the viewport.height key is expressed against (ARCHITECTURE §1).
local DESIGN_WIDTH = 1080

-- The control deck's fixed stack — bottom margin(8) + bottom row(92) + second
-- bar(84) + main bar(286) + XP block(70) + unit row(180) + 4 inter-row
-- gaps(24) — is 744 design px (values mirror WM.DeckMetrics / Deck.lua);
-- DECK_FIXED_PX adds a 46 px minimum chat band on top: the strip anchors
-- 6 px below the deck top and 6 px above the unit row (Chat.lua), so the
-- band is 12 px of gaps around a 34 px visible strip — one 24 px text line
-- plus its padding. Ratios above the dynamic maximum would push that stack
-- off-screen. 0.60 keeps at least a usable world strip.
local RATIO_MIN = 0.60
local DECK_FIXED_PX = 790 -- 744 fixed stack + 46 chat band (34 px visible strip + 12 px gaps)

local function RatioMax()
	-- FRAME aspect in design px: height over width of the phone frame the
	-- layout lives in (Band.lua). Uniform scale, so UI units suffice.
	local bandWidth = (WM.Band and WM.Band.width) or WM.UIWidth()
	local bandHeight = (WM.Band and WM.Band.height) or WM.UIHeight()
	local aspect = bandHeight / bandWidth
	local maxRatio = aspect - DECK_FIXED_PX / DESIGN_WIDTH
	if maxRatio > 1.20 then maxRatio = 1.20 end
	if maxRatio < RATIO_MIN then maxRatio = RATIO_MIN end
	return maxRatio
end

-- viewport.height bounds in design px (the ratio limits above, re-expressed).
function Config.HeightBounds()
	return math.floor(RATIO_MIN * DESIGN_WIDTH + 0.5),
		math.floor(RatioMax() * DESIGN_WIDTH + 0.5)
end

local function Clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

WM.On("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	if type(WowMobileDB) ~= "table" then
		WowMobileDB = {}
	end
	-- Pre-release saved variables stored viewport.ratio (a width fraction);
	-- migrate once to the documented viewport.height key and drop the old one.
	local vp = WowMobileDB.viewport
	if type(vp) == "table" then
		if vp.height == nil and type(vp.ratio) == "number" then
			vp.height = vp.ratio * DESIGN_WIDTH
		end
		vp.ratio = nil
	end
	CopyDefaults(Config.defaults, WowMobileDB)
	WM.db = WowMobileDB
end)

--------------------------------------------------------------------------------
-- Setters
--------------------------------------------------------------------------------

function Config.SetHeight()
	-- v0.6.0 phone layout: the world area is everything between the top HUD
	-- and the bottom stack, and the phone client derives the same split
	-- from the stream size — nothing to configure or mirror any more.
	WM.Print(string.format(
		"the world area is automatic now: %d design px between the top HUD and the bars",
		WM.Viewport and WM.Viewport.HeightPx() or 0))
end

function Config.SetScale(v)
	v = tonumber(v)
	if not v then
		-- Same visible-feedback rule as SetHeight above.
		WM.Print("usage: /wm scale <0.64..1.0> — uiScale cvar override")
		return
	end
	-- The uiScale cvar only accepts 0.64..1.0; touch-target sizes stay
	-- physically constant either way (see WM.Px), so scale mainly affects
	-- Blizzard-rendered text.
	v = Clamp(v, 0.64, 1.0)
	WM.db.uiScale = v
	WM.OutOfCombat("uiscale", function()
		SetCVar("useUiScale", 1)
		SetCVar("uiScale", v)
	end)
	WM.Print(string.format("UI scale set to %.2f — /wm reload to fully re-lay-out the deck", v))
end

function Config.Reset()
	WowMobileDB = {}
	CopyDefaults(Config.defaults, WowMobileDB)
	WM.db = WowMobileDB
	if WM.Viewport then
		WM.Viewport.Apply()
	end
	WM.Print("options reset to defaults — /wm reload recommended")
end

-- Apply the persisted uiScale override once the world is up.
WM.OnInit(function()
	if WM.db.uiScale then
		local v = WM.db.uiScale
		WM.OutOfCombat("uiscale", function()
			SetCVar("useUiScale", 1)
			SetCVar("uiScale", v)
		end)
	end
end)

--------------------------------------------------------------------------------
-- /wm slash command
--------------------------------------------------------------------------------

local function PrintHelp()
	WM.Print("commands:")
	WM.Print("  /wm scale <0.64..1.0>  — uiScale cvar override")
	WM.Print("  /wm phone [name|id|WxH]  — pick the phone the frame is shaped for (no argument: toggle the selector)")
	WM.Print("  /wm settings  — open the touch settings panel")
	WM.Print("  /wm status  — viewport/deck/module health")
	WM.Print("  /wm errors  — list recorded module errors")
	WM.Print("  /wm reset  — restore defaults")
	WM.Print("  /wm reload  — reload the UI")
end

-- /wm errors: every recorded module error (first per module; Core crash guard).
local function PrintErrors()
	local order, map = WM.GetErrors()
	if #order == 0 then
		WM.Print("no module errors recorded — all modules healthy")
		return
	end
	WM.Print(string.format("%d module(s) hit errors (/wm reload to retry):", #order))
	for i = 1, #order do
		WM.Print("  " .. order[i] .. ": " .. map[order[i]])
	end
end

-- /wm status: one-glance health — phone frame, viewport geometry, deck
-- presence, errors.
local function PrintStatus()
	-- Version first: the wizard updates the files on disk, but a RUNNING game
	-- keeps the old code until /reload — this line is the proof of which
	-- addon code is actually live (mirror of the phone client's version line).
	WM.Print("version: " .. WM.DisplayVersion() .. " (a lower version than the installer means the game needs /reload)")
	local band = WM.Band
	if not band then
		WM.Print("mode: UNKNOWN (Band failed) — full-window fallback")
	else
		-- Band.px normally holds physical px (the server's crop numbers
		-- verbatim), but on a client without GetPhysicalScreenSize the
		-- ClientPixels fallback measured UI units instead (Band.px.approx) —
		-- label honestly, since the crop-match claim is only approximate then.
		local units = band.px.approx
			and "UI units (physical size unavailable — crop match approximate)"
			or "physical px; the server crops the outline's interior"
		WM.Print(string.format(
			"mode: phone frame — %s, %dx%d at (%d,%d) of a %dx%d window (%s)%s",
			band.PhoneName(band.phone), band.px.width, band.px.height, band.px.x, band.px.y,
			band.client.w, band.client.h, units,
			band.NeedsReload() and " — /reload pending" or ""))
		-- Basis dump — every number the frame derivation used plus the world
		-- rect that actually applied, so a field report pinpoints any residual
		-- addon/server crop mismatch in one paste: compare the "frame rect" /
		-- "world rect" px against the server log's crop numbers.
		if band.client then
			local uiW, uiH = WM.UIWidth(), WM.UIHeight()
			WM.Print(string.format(
				"basis: %s -> client %dx%d px | live window %.1fx%.1f UI units (aspect %.4f; UIParent reports %.1fx%.1f)",
				band.client.basis, band.client.w, band.client.h,
				uiW, uiH, uiW / uiH, UIParent:GetWidth(), UIParent:GetHeight()))
			WM.Print(string.format(
				"frame rect: x=%d y=%d w=%d h=%d px (left=%.1f top=%.1f width=%.1f UI units)",
				band.px.x, band.px.y, band.px.width, band.px.height,
				band.left or 0, band.top or 0, band.width or 0))
			WM.Print("world: renders full window, edge to edge (the phone sees it through the top of the frame)")
		end
	end
	WM.Print(string.format("world area: %d design px between the top HUD and the bars (automatic)",
		WM.Viewport and WM.Viewport.HeightPx() or 0))
	WM.Print("world square: " .. (WM.WorldSquare and "ok" or "MISSING (Viewport failed)"))
	WM.Print("deck: " .. (WM.Deck and "ok" or "MISSING (Deck failed)"))
	local order = WM.GetErrors()
	if #order == 0 then
		WM.Print("modules: healthy (no errors recorded)")
	else
		WM.Print(string.format("modules: %d with errors — /wm errors for details", #order))
	end
end

SLASH_WOWMOBILE1 = "/wm"
SlashCmdList["WOWMOBILE"] = function(msg)
	local cmd, arg = msg:match("^%s*(%S*)%s*(%S*)")
	local rest = msg:match("^%s*%S*%s*(.-)%s*$") or ""
	cmd = cmd:lower()
	if cmd == "phone" then
		if WM.PhoneSelect then WM.PhoneSelect.Command(rest) end
	elseif cmd == "viewport" then
		Config.SetHeight(arg)
	elseif cmd == "scale" then
		Config.SetScale(arg)
	elseif cmd == "errors" then
		PrintErrors()
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "reset" then
		Config.Reset()
	elseif cmd == "reload" then
		ReloadUI()
	elseif cmd == "settings" then
		if WM.Deck and WM.Deck.Open then
			WM.Deck.Open("settings")
		end
	else
		PrintHelp()
	end
end
