--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Turtle
-- Turtle WoW extras (the 1.12-engine custom server's own UI additions). All of
-- it is name-guarded, so on any other 1.12 client this module does nothing.
--
--   * MinimapShopFrame — the donation-shop minimap button: banished (field
--     request v0.6.2: "can you remove that icon"). The shop stays reachable
--     on Turtle's website / main menu.
--   * The group finder (Turtle's own LFT addon) — a mouse-sized window that
--     opened somewhere off the phone frame: every top-level LFT*/LFG* window
--     is centered in the phone frame and scaled to fit it whenever it shows.
--     Matched by shape (a large frame parented to UIParent) rather than one
--     exact name, so it keeps working across Turtle's renames; LFT_Minimap
--     (the small minimap button that opens it) is left alone.
--------------------------------------------------------------------------------

local WM = WowMobile

local BOOST = 1.6 -- toward touch size, capped by the frame below

local fitted = {} -- frame -> true once hooked

local function Fit(f)
	local band = WowMobileBand
	if not band or not f:GetWidth() or f:GetWidth() <= 0 then return end
	local scale = math.min(BOOST,
		band:GetWidth() * 0.98 / f:GetWidth(),
		band:GetHeight() * 0.9 / f:GetHeight())
	f:SetScale(scale)
	f:ClearAllPoints()
	f:SetPoint("CENTER", band, "CENTER", 0, 0)
end

local function Hook(f)
	if fitted[f] then return end
	fitted[f] = true
	local orig = f:GetScript("OnShow")
	f:SetScript("OnShow", function()
		if orig then orig() end
		Fit(this)
		-- 1.12's ShowUIPanel positions a panel AFTER showing it (its
		-- UpdateUIPanelPositions pass): assert the centre again a moment
		-- later so the panel manager does not get the last word.
		local frame = this
		WM.After(0.05, function() if frame:IsShown() then Fit(frame) end end)
	end)
	if f:IsShown() then Fit(f) end
end

local function IsWindow(name, f)
	if type(name) ~= "string" or type(f) ~= "table" then return false end
	if not (string.find(name, "^LFT") or string.find(name, "^LFG")) then return false end
	if name == "LFT_Minimap" or type(f[0]) ~= "userdata" then return false end
	if not f.GetParent or not f.IsObjectType or not f:IsObjectType("Frame") then return false end
	if f:GetParent() ~= UIParent then return false end
	local w, h = f:GetWidth(), f:GetHeight()
	return w and h and w >= 200 and h >= 150
end

local function Scan()
	for name, f in pairs(getfenv(0)) do
		if IsWindow(name, f) then Hook(f) end
	end
end

local function Banish()
	if MinimapShopFrame then WM.BanishFrame(MinimapShopFrame) end
end

WM.OnInit(function()
	Banish()
	Scan()
end)

-- Turtle builds its UI pieces at different load stages; catch late ones.
WM.On("PLAYER_ENTERING_WORLD", function()
	Banish()
	Scan()
end)
WM.On("ADDON_LOADED", function()
	Scan()
end)
