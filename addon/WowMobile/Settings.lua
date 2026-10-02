--------------------------------------------------------------------------------
-- WowMobile · Settings
-- Touch settings panel (the phone menu's "Config" button / `/wm settings`): stepper
-- rows for the world-viewport height and UI scale, plus Reset and Reload.
-- All mutations go through WM.Config so the slash command and this panel
-- share one code path.
--------------------------------------------------------------------------------

local _, WM = ...

local SCALE_STEP = 0.05

local refreshers = {} -- closures that repaint each row's value text

local function RefreshAll()
	for i = 1, #refreshers do
		refreshers[i]()
	end
end

-- A stepper row: label left, [-] value [+] right.
local function AddStepper(parent, index, label, getText, onDelta)
	local row = CreateFrame("Frame", nil, parent)
	row:SetPoint("TOPLEFT", 0, -WM.Px((index - 1) * 130))
	row:SetPoint("TOPRIGHT", 0, -WM.Px((index - 1) * 130))
	row:SetHeight(WM.Px(120))
	WM.SkinFrame(row, { 0.07, 0.07, 0.09, 1 })

	local title = WM.CreateText(row, 32)
	title:SetPoint("LEFT", WM.Px(20), 0)
	title:SetText(label)

	local plus = WM.CreateTouchButton(row, 110, 104, "+", 44)
	plus:SetPoint("RIGHT", -WM.Px(8), 0)
	local value = WM.CreateText(row, 32)
	value:SetPoint("RIGHT", plus, "LEFT", -WM.Px(16), 0)
	local minus = WM.CreateTouchButton(row, 110, 104, "-", 44)
	minus:SetPoint("RIGHT", value, "LEFT", -WM.Px(16), 0)

	plus:SetScript("OnClick", function()
		onDelta(1)
		RefreshAll()
	end)
	minus:SetScript("OnClick", function()
		onDelta(-1)
		RefreshAll()
	end)
	refreshers[#refreshers + 1] = function()
		value:SetText(getText())
	end
end

WM.OnInit(function()
	local panel = WM.Deck.CreatePanel("settings", "Settings")

	AddStepper(panel.content, 1, "UI scale (Blizzard text)",
		function()
			-- Show the live cvar when no override is stored yet.
			return string.format("%.2f", WM.db.uiScale or tonumber(GetCVar("uiScale")) or 1)
		end,
		function(dir)
			local current = WM.db.uiScale or tonumber(GetCVar("uiScale")) or 1
			WM.Config.SetScale(current + dir * SCALE_STEP)
		end)

	-- Each UI scale step reloads the UI (Config.SetScale); this undoes any
	-- override in one tap.
	local resetScale = WM.CreateTouchButton(panel.content, 480, 110, "Reset UI scale", 32)
	resetScale:SetPoint("TOPLEFT", 0, -WM.Px(160))
	resetScale:SetScript("OnClick", function() WM.Config.ResetScale() end)

	local reset = WM.CreateTouchButton(panel.content, 480, 110, "Reset to defaults", 32)
	reset:SetPoint("TOPLEFT", 0, -WM.Px(300))
	reset:SetScript("OnClick", function()
		WM.Config.Reset()
		RefreshAll()
	end)

	local reload = WM.CreateTouchButton(panel.content, 480, 110, "Reload UI", 32)
	reload:SetPoint("TOPRIGHT", 0, -WM.Px(300))
	reload:SetScript("OnClick", ReloadUI)

	local note = WM.CreateText(panel.content, 24)
	note:SetPoint("TOPLEFT", 0, -WM.Px(440))
	note:SetWidth(WM.Px(940))
	note:SetJustifyH("LEFT")
	note:SetWordWrap(true)
	note:SetTextColor(0.7, 0.7, 0.75)
	note:SetText("Touch targets keep their physical size at any UI scale. " ..
		"Changing the UI scale reloads the UI so the layout is rebuilt. " ..
		"The world area is automatic: everything between the top bars and " ..
		"the action bars. Slash commands: /wm phone, /wm scale <v>, /wm reset.")

	panel.OnOpen = RefreshAll
end)
