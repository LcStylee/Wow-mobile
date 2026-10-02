--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Config
-- SavedVariables handling (WowMobileDB), the /wm slash command and the
-- programmatic setters the Settings panel drives.
--------------------------------------------------------------------------------

local WM = WowMobile

local Config = {}
WM.Config = Config

Config.defaults = {
	viewport = {
		-- World-square height in design px of the 1080-wide window (1080 =
		-- square). Converted to a width fraction internally (Viewport.Apply)
		-- so it scales to any real capture resolution.
		height = 1080,
	},
	-- uiScale cvar override; nil = leave the user's cvar untouched.
	uiScale = nil,
}

-- Design width the viewport.height key is expressed against.
local DESIGN_WIDTH = 1080

-- The control deck's fixed stack — bottom margin(8) + bottom row(92) + second
-- bar(84) + main bar(286) + XP block(70) + unit row(180) + 4 inter-row
-- gaps(24) — is 744 design px (values mirror WM.DeckMetrics / Deck.lua);
-- DECK_FIXED_PX adds a 46 px minimum chat band on top. Ratios above the
-- dynamic maximum would push that stack off-screen; 0.60 keeps at least a
-- usable world strip.
local RATIO_MIN = 0.60
local DECK_FIXED_PX = 790 -- 744 fixed stack + 46 chat band
Config.DECK_FIXED_PX = DECK_FIXED_PX -- Viewport clamps the square against it

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

function Config.HeightBounds()
	-- The max uses floor WITHOUT rounding: round-to-nearest could advertise
	-- up to 0.5 design px ABOVE the true geometric maximum, so setting the
	-- height to the advertised bound (one tap-hold in Settings) would trip
	-- Viewport's clamp on a legitimate window. Viewport additionally shaves
	-- sub-pixel overshoot silently — belt and braces.
	return math.floor(RATIO_MIN * DESIGN_WIDTH + 0.5),
		math.floor(RatioMax() * DESIGN_WIDTH)
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

-- On 1.12, saved variables are guaranteed loaded at VARIABLES_LOADED, which
-- fires before PLAYER_LOGIN (where WM.OnInit closures run).
WM.On("VARIABLES_LOADED", function()
	if type(WowMobileDB) ~= "table" then
		WowMobileDB = {}
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
		WM.Print("usage: /wm scale <0.64..1.0> — uiScale cvar override (reloads the UI)")
		return
	end
	-- The uiScale cvar only accepts 0.64..1.0; touch-target sizes stay
	-- physically constant either way (see WM.Px), so scale mainly affects
	-- Blizzard-rendered text. A new scale resizes UIParent, which moves the
	-- phone frame and every widget sized from it — the field report v0.6.0
	-- showed a half-shifted layout until a reload — so the change always
	-- reloads straight away and the layout is rebuilt for the new scale.
	v = Clamp(v, 0.64, 1.0)
	WM.db.uiScale = v
	SetCVar("useUiScale", "1")
	SetCVar("uiScale", tostring(v))
	WM.Print(string.format("UI scale set to %.2f — reloading the UI", v))
	ReloadUI()
end

-- Back to Blizzard's own scaling (no override), then reload.
function Config.ResetScale()
	WM.db.uiScale = nil
	SetCVar("useUiScale", "0")
	WM.Print("UI scale reset to the game default — reloading the UI")
	ReloadUI()
end

function Config.Reset()
	-- Keep the phone choice: it is a setup fact, not a preference to reset.
	local phone = WM.db and WM.db.phone
	WowMobileDB = {}
	CopyDefaults(Config.defaults, WowMobileDB)
	WowMobileDB.phone = phone
	WM.db = WowMobileDB
	-- Defaults include Blizzard's own UI scale; reload re-lays-out the deck.
	SetCVar("useUiScale", "0")
	WM.Print("options reset to defaults — reloading the UI")
	ReloadUI()
end

-- Apply the persisted uiScale override once the world is up. This OnInit is
-- registered before every layout module's (toc order), so when the cvar
-- applies synchronously UIParent has already resized by the time they size
-- their frames — RebaseLayout re-measures so they lay out against the REAL
-- post-scale geometry (never the assumed one). A client that defers the
-- cvar to the next reload instead trips Core's post-login
-- WM.CheckLayoutFresh drift checks, which raise the reload banner.
WM.OnInit(function()
	if WM.db and WM.db.uiScale then
		SetCVar("useUiScale", 1)
		SetCVar("uiScale", WM.db.uiScale)
		WM.RebaseLayout()
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
	WM.Print("  /wm minimap  — minimap state; /wm minimap blizzard|phone to test its placement")
	WM.Print("  /wm errors  — list recorded module errors")
	WM.Print("  /wm reset  — restore defaults")
	WM.Print("  /wm reload  — reload the UI")
end

-- /wm errors: every recorded module error (first per module; Core crash
-- guard). Lua 5.0: table.getn, no '#'.
local function PrintErrors()
	local order, map = WM.GetErrors()
	local n = table.getn(order)
	if n == 0 then
		WM.Print("no module errors recorded — all modules healthy")
		return
	end
	WM.Print(string.format("%d module(s) hit errors (/wm reload to retry):", n))
	for i = 1, n do
		WM.Print("  " .. order[i] .. ": " .. map[order[i]])
	end
end

-- /wm status: one-glance health — band mode, viewport geometry, deck
-- presence, errors.
local function PrintStatus()
	-- Version first: the wizard updates the files on disk, but a RUNNING game
	-- keeps the old code until /reload — this line is the proof of which
	-- addon code is actually live (mirror of the phone client's version line).
	WM.Print("version: v" .. WM.Version() .. " (a lower version than the installer means the game needs /reload)")
	local band = WM.Band
	if not band or not band.px then
		WM.Print("mode: UNKNOWN (Band failed) — full-window fallback")
	else
		-- Band.px normally holds physical px (the server's crop numbers
		-- verbatim, read from the gxResolution cvar on 1.12), but when the
		-- cvar was unreadable the ClientPixels fallback measured UI units
		-- instead (Band.px.approx) — label honestly, since the crop-match
		-- claim is only approximate then.
		local units
		if band.px.approx then
			units = "UI units (physical size unavailable — crop match approximate)"
		else
			units = "physical px; the server crops the outline's interior"
		end
		local pending = ""
		if band.NeedsReload() then pending = " — /reload pending" end
		WM.Print(string.format(
			"mode: phone frame — %s, %dx%d at (%d,%d) of a %dx%d window (%s)%s",
			band.PhoneName(band.phone), band.px.width, band.px.height, band.px.x, band.px.y,
			band.client.w, band.client.h, units, pending))
	end
	-- Basis dump — every number the band derivation used (Band.ClientPixels'
	-- chosen-basis logic) plus the world rect that actually applied, so a
	-- field report pinpoints any residual addon/server crop mismatch in one
	-- paste: compare "frame rect"/frame px against the server log's
	-- crop numbers.
	if band and band.client then
		local uiW, uiH = WM.UIWidth(), WM.UIHeight()
		WM.Print(string.format(
			"basis: gxResolution=\"%s\" | live window %.1fx%.1f UI units (aspect %.4f; UIParent reports %.1fx%.1f) | chosen: %s -> client %dx%d px",
			band.gxRaw or "unreadable", uiW, uiH, uiW / uiH, UIParent:GetWidth(), UIParent:GetHeight(),
			band.client.basis, band.client.w, band.client.h))
		WM.Print(string.format(
			"frame rect: x=%d y=%d w=%d h=%d px (left=%.1f top=%.1f width=%.1f UI units)",
			band.px.x, band.px.y, band.px.width, band.px.height,
			band.left or 0, band.top or 0, band.width or 0))
	end
	WM.Print("world: renders full window, edge to edge (the phone sees it through the top of the frame)")
	WM.Print(string.format("world area: %d design px between the top HUD and the bars (automatic)",
		WM.Viewport and WM.Viewport.HeightPx() or 0))
	WM.Print("world square: " .. (WM.WorldSquare and "ok" or "MISSING (Viewport failed)"))
	WM.Print("deck: " .. (WM.Deck and "ok" or "MISSING (Deck failed)"))
	local order = WM.GetErrors()
	local n = table.getn(order)
	if n == 0 then
		WM.Print("modules: healthy (no errors recorded)")
	else
		WM.Print(string.format("modules: %d with errors — /wm errors for details", n))
	end
end

SLASH_WOWMOBILE1 = "/wm"
SlashCmdList["WOWMOBILE"] = function(msg)
	msg = msg or ""
	-- Lua 5.0: no string.match — string.find with captures instead.
	local _, _, cmd, cmdArg = string.find(msg, "^%s*(%S*)%s*(%S*)")
	local _, _, rest = string.find(msg, "^%s*%S*%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "phone" then
		if WM.PhoneSelect then WM.PhoneSelect.Command(rest or "") end
	elseif cmd == "viewport" then
		Config.SetHeight(cmdArg)
	elseif cmd == "scale" then
		Config.SetScale(cmdArg)
	elseif cmd == "errors" then
		PrintErrors()
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "reset" then
		Config.Reset()
	elseif cmd == "reload" then
		ReloadUI()
	elseif cmd == "minimap" then
		if WM.MinimapCommand then WM.MinimapCommand(string.lower(cmdArg or "")) end
	elseif cmd == "settings" then
		if WM.Deck and WM.Deck.Open then
			WM.Deck.Open("settings")
		end
	else
		PrintHelp()
	end
end
