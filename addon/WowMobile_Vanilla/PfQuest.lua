--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · PfQuest
-- pfQuest (shagu) and its database extensions (pfQuest-turtle, the OctoWoW
-- variant, ...) on the phone. Nothing is bundled: when the player has pfQuest
-- installed, this module gives it mobile defaults ONCE, then leaves its
-- settings alone (anything changed later in pfQuest's own config sticks):
--
--   arrow          "0"  the floating route arrow (/db arrow) — a mouse-
--                       sized, draggable frame over the middle of the world
--   showtracker    "0"  pfQuest's tracker window — QuestTracker.lua already
--                       shows the tracked quest on the phone
--   minimapbutton  "0"  the minimap button (pfQuest's browser opens with
--                       /db anyway)
--   welcome        "1"  skip the first-run setup wizard (mouse-only)
--
-- What stays on is what pfQuest is for: quest givers and objective spawns
-- on the minimap and the world map — both are the client's own frames in
-- this layout (Minimap.lua keeps the native minimap, WorldMap.lua scales the
-- native world map), so pfQuest's nodes draw there unchanged.
--------------------------------------------------------------------------------

local WM = WowMobile

-- Bump to re-apply the defaults once on existing installs.
local DEFAULTS_VERSION = 1

local DEFAULTS = {
	arrow = "0",
	showtracker = "0",
	minimapbutton = "0",
	welcome = "1",
}

local function Apply()
	if type(pfQuest_config) ~= "table" or not WM.db then return end
	if (WM.db.pfQuestDefaults or 0) >= DEFAULTS_VERSION then return end
	for k, v in pairs(DEFAULTS) do
		pfQuest_config[k] = v
	end
	WM.db.pfQuestDefaults = DEFAULTS_VERSION
	-- Live frames pfQuest already showed this session.
	if pfQuestRouteArrow then pfQuestRouteArrow:Hide() end
	if pfQuestMapTracker then pfQuestMapTracker:Hide() end
	if pfBrowserIcon then pfBrowserIcon:Hide() end
	if pfQuestInit then pfQuestInit:Hide() end
	WM.Print("pfQuest found: set up for the phone (arrow, tracker window and minimap button off; map markers on). Change any of it with /db config.")
end

-- pfQuest fills pfQuest_config with its defaults on its own load, so apply
-- after that: on its ADDON_LOADED, or at login when it loaded earlier.
WM.On("ADDON_LOADED", function(_, name)
	if name == "pfQuest" or name == "pfQuest-tbc" or name == "pfQuest-wotlk" then Apply() end
end)
WM.OnInit(Apply)
WM.On("PLAYER_ENTERING_WORLD", function()
	Apply()
	-- The arrow re-shows itself whenever a route appears; keep it hidden
	-- while the player has it switched off (pfQuest checks the same key).
	if pfQuestRouteArrow and type(pfQuest_config) == "table" and pfQuest_config["arrow"] == "0" then
		pfQuestRouteArrow:Hide()
	end
end)
