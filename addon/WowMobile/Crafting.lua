--------------------------------------------------------------------------------
-- WowMobile · Crafting
-- One touch panel serving BOTH classic profession APIs (their LoD Blizzard
-- UIs are kept from loading — Blizzard.lua drops TRADE_SKILL_SHOW/CRAFT_SHOW
-- from UIParent and this module consumes the events, which fire regardless of
-- any Blizzard addon's load timing):
--   * tradeskill API — TRADE_SKILL_SHOW/UPDATE/CLOSE, GetNumTradeSkills,
--     GetTradeSkillInfo (name, type, numAvailable, isExpanded),
--     GetTradeSkillReagentInfo, DoTradeSkill(index, repeat) — most
--     professions (alchemy, smithing, tailoring, cooking, ...),
--   * craft API — CRAFT_SHOW/UPDATE/CRAFT_CLOSE, GetNumCrafts, GetCraftInfo,
--     GetCraftReagentInfo, DoCraft(index) — enchanting (and pet training)
--     keep this separate vanilla API on era; both API sets verified against
--     Blizzard_TradeSkillUI/Vanilla + Blizzard_CraftUI/Vanilla in the 1.15
--     client UI source (gethe/wow-ui-source classic_era branch).
--
-- Views: recipe list (availability counts, difficulty-colored) → recipe
-- detail (reagents with have/need, quantity stepper + Create / Create All).
-- Both sessions can be live at once (an enchanter with cooking open); a
-- picker row then flips between them — the "several open-capable
-- professions" case. Platform limitation, commented where it bites: the
-- craft API's DoCraft takes NO repeat count (one cast per call, matching the
-- default CraftFrame which has no "create all" for enchanting), so quantity
-- controls only render in tradeskill mode.
--------------------------------------------------------------------------------

local _, WM = ...

local sheet, scroller, st, qtyStepper

local mode          -- "trade" | "craft" — which API the panel is showing
local tradeOpen, craftOpen = false, false
local view = "list" -- "list" | "detail"
local selected      -- { index, name } — revalidated by name on every update

local COLOR = {
	optimal = { 1.00, 0.50, 0.25 },
	medium  = { 1.00, 1.00, 0.25 },
	easy    = { 0.25, 0.75, 0.25 },
	trivial = { 0.60, 0.60, 0.60 },
	none    = { 0.92, 0.92, 0.92 },
}

local function Hex(c)
	return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

--------------------------------------------------------------------------------
-- API indirection over the two recipe systems
--------------------------------------------------------------------------------

local function NumRecipes()
	if mode == "craft" then return GetNumCrafts() or 0 end
	return GetNumTradeSkills() or 0
end

-- name, kind ("header"/difficulty), numAvailable, extra (craft subSpellName)
local function RecipeInfo(i)
	if mode == "craft" then
		local name, subSpellName, kind, numAvailable = GetCraftInfo(i)
		return name, kind, numAvailable, subSpellName
	end
	local name, kind, numAvailable = GetTradeSkillInfo(i)
	return name, kind, numAvailable
end

local function RecipeIcon(i)
	if mode == "craft" then return GetCraftIcon(i) end
	return GetTradeSkillIcon(i)
end

local function NumReagents(i)
	if mode == "craft" then return GetCraftNumReagents(i) or 0 end
	return GetTradeSkillNumReagents(i) or 0
end

local function ReagentInfo(i, j)
	if mode == "craft" then return GetCraftReagentInfo(i, j) end
	return GetTradeSkillReagentInfo(i, j)
end

local function SkillLine()
	if mode == "craft" then
		-- name, rank, maxRank; nil name for craft lines without a skill bar
		-- (pet training) — fall back to the craft frame's own name.
		local name, rank, maxRank = GetCraftDisplaySkillLine()
		if name then return name, rank, maxRank end
		return (GetCraftName and GetCraftName()) or "Crafting"
	end
	return GetTradeSkillLine()
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local Render -- forward: buttons re-enter it

local function SelectRecipe(i, name)
	selected = { index = i, name = name }
	-- Keep the API-side selection in step (harmless bookkeeping the default
	-- frames also do; DoTradeSkill/DoCraft take the index explicitly).
	if mode == "craft" then
		SelectCraft(i)
	else
		SelectTradeSkill(i)
	end
	view = "detail"
	Render()
end

-- The list indices shift with every filter/expansion change, so the detail
-- view trusts its index only while the name at that index still matches.
local function ValidSelection()
	if not selected then return nil end
	local name = RecipeInfo(selected.index)
	if name == selected.name then return selected.index end
	return nil
end

local function RenderModePicker()
	if not (tradeOpen and craftOpen) then return end
	local savedMode = mode
	local function LineName(m)
		local prev = mode
		mode = m
		local name = SkillLine()
		mode = prev
		return name or m
	end
	st.Row({
		{ label = LineName("trade"), selected = savedMode == "trade", onTap = function()
			mode, view, selected = "trade", "list", nil
			Render()
		end },
		{ label = LineName("craft"), selected = savedMode == "craft", onTap = function()
			mode, view, selected = "craft", "list", nil
			Render()
		end },
	})
end

local function RenderList()
	for i = 1, NumRecipes() do
		local name, kind, numAvailable, subSpellName = RecipeInfo(i)
		if name then
			if kind == "header" then
				st.Text(name, 34, 1, 0.82, 0)
			else
				local c = COLOR[kind] or COLOR.none
				local label = Hex(c) .. name .. "|r"
				if subSpellName and subSpellName ~= "" then
					label = label .. " |cff9999a3" .. subSpellName .. "|r"
				end
				if numAvailable and numAvailable > 0 then
					label = label .. " |cff33cc33[" .. numAvailable .. "]|r"
				end
				local index, recipeName = i, name
				st.Button(label, RecipeIcon(i), function()
					SelectRecipe(index, recipeName)
				end, function(tt)
					if mode == "craft" then
						tt:SetCraftSpell(index)
					else
						tt:SetTradeSkillItem(index)
					end
				end)
			end
		end
	end
	if NumRecipes() == 0 then
		st.Text("No recipes known.", 30, 0.7, 0.7, 0.75)
	end
end

local function RenderDetail(i)
	local name, kind, numAvailable, subSpellName = RecipeInfo(i)
	st.Button("< Back to recipes", nil, function()
		view, selected = "list", nil
		Render()
	end)

	local c = COLOR[kind] or COLOR.none
	st.Text(Hex(c) .. name .. "|r"
		.. (subSpellName and subSpellName ~= "" and (" |cff9999a3" .. subSpellName .. "|r") or ""), 36)

	if mode == "trade" then
		local cooldown = GetTradeSkillCooldown(i)
		if cooldown and cooldown > 0 then
			st.Text("Ready again in " .. WM.FormatDuration(cooldown), 28, 0.85, 0.4, 0.4)
		end
	elseif GetCraftDescription then
		local desc = GetCraftDescription(i)
		if desc and desc ~= "" then
			st.Text(desc, 28, 0.75, 0.75, 0.8)
		end
	end

	local numReagents = NumReagents(i)
	if numReagents > 0 then
		st.Text("Reagents", 32, 1, 0.82, 0)
	end
	local haveAll = true
	for j = 1, numReagents do
		local rName, rTexture, rCount, playerCount = ReagentInfo(i, j)
		rCount = rCount or 1
		playerCount = playerCount or 0
		if playerCount < rCount then haveAll = false end
		local color = playerCount >= rCount and "|cff33cc33" or "|cffcc4444"
		local index, rIndex = i, j
		st.Button((rName or RETRIEVING_ITEM_INFO) .. "  " .. color
			.. playerCount .. " / " .. rCount .. "|r", rTexture, nil,
			function(tt)
				if mode == "craft" then
					tt:SetCraftItem(index, rIndex)
				else
					tt:SetTradeSkillItem(index, rIndex)
				end
			end)
	end

	numAvailable = numAvailable or 0
	if mode == "trade" then
		if numAvailable > 1 then
			st.Anchor(qtyStepper, 140)
		else
			-- SetSilent: parking with Set() from inside this render would
			-- re-enter it via onChange (see CreateStepper).
			qtyStepper.SetSilent(1)
		end
		local index = i
		st.Row({
			{ label = numAvailable > 0 and ("Create x" .. math.min(qtyStepper.Get(), numAvailable))
					or "Missing reagents",
				green = numAvailable > 0,
				disabled = numAvailable < 1,
				onTap = function()
					DoTradeSkill(index, qtyStepper.Get())
				end },
			{ label = "Create All (" .. numAvailable .. ")",
				disabled = numAvailable < 1,
				onTap = function()
					DoTradeSkill(index, numAvailable)
				end },
		})
	else
		-- Platform limitation (era craft API): DoCraft(index) has no repeat
		-- count — enchanting casts once per call, exactly like the default
		-- CraftFrame's single Create button. No quantity/Create All here.
		local index = i
		local b = st.Button(haveAll and "Create" or "Missing reagents", nil, function()
			DoCraft(index)
		end)
		if haveAll then
			local g = WM.Colors.green
			b.borderTex:SetColorTexture(g[1], g[2], g[3], 1)
		else
			WM.SetButtonEnabled(b, false)
		end
	end
end

Render = function()
	if not sheet:IsShown() then return end
	local name, rank, maxRank = SkillLine()
	local title = name or "Crafting"
	if rank and maxRank and maxRank > 0 then
		title = title .. "  " .. rank .. "/" .. maxRank
	end
	sheet.titleText:SetText(title)

	st.Reset()
	RenderModePicker()
	local sel = view == "detail" and ValidSelection() or nil
	if sel then
		RenderDetail(sel)
	else
		if view == "detail" then view = "list" end -- selection went stale
		RenderList()
	end
	st.Finish(mode .. ":" .. view .. ":" .. tostring(sel))
end

--------------------------------------------------------------------------------
-- Session plumbing
--------------------------------------------------------------------------------

-- Collapsed headers change every index below them; keep everything expanded
-- so indices are stable and every recipe is visible. (The expand call fires
-- another *_UPDATE; guarded by only expanding when something is collapsed.)
local function EnsureExpanded()
	if mode == "craft" then
		for i = 1, GetNumCrafts() or 0 do
			local _, _, kind, _, isExpanded = GetCraftInfo(i)
			if kind == "header" and not isExpanded and ExpandCraftSkillLine then
				ExpandCraftSkillLine(0) -- 0 = expand all
				return
			end
		end
	else
		for i = 1, GetNumTradeSkills() or 0 do
			local _, kind, _, isExpanded = GetTradeSkillInfo(i)
			if kind == "header" and not isExpanded then
				ExpandTradeSkillSubClass(0) -- 0 = expand all
				return
			end
		end
	end
end

local function CloseSession(which)
	if which == "trade" then
		tradeOpen = false
	else
		craftOpen = false
	end
	if mode ~= which then return end
	-- The displayed session ended; fall through to the other one if it is
	-- still live, otherwise fold the sheet.
	local other = which == "trade" and "craft" or "trade"
	if (other == "trade" and tradeOpen) or (other == "craft" and craftOpen) then
		mode, view, selected = other, "list", nil
		Render()
	else
		sheet:Hide()
		mode, selected = nil, nil
		view = "list"
		st.ClearView()
	end
end

WM.OnInit(function()
	local Kit = WM.SheetKit
	sheet = Kit.CreateSheet("crafting", "Crafting")
	sheet.OnDismiss = function()
		-- Walk away from every live session; the *_CLOSE events fold the sheet.
		if tradeOpen then CloseTradeSkill() end
		if craftOpen then CloseCraft() end
	end

	scroller = WM.Deck.CreateScroller(sheet.body)
	st = Kit.NewStack(scroller)

	qtyStepper = Kit.CreateStepper(scroller.child, 460, "How many")
	qtyStepper.maxFn = function()
		local sel = ValidSelection()
		if not sel then return 1 end
		local _, _, numAvailable = RecipeInfo(sel)
		return math.max(1, numAvailable or 1)
	end
	qtyStepper.onChange = function() Render() end

	WM.On("TRADE_SKILL_SHOW", function()
		mode, view, selected = "trade", "list", nil
		tradeOpen = true
		EnsureExpanded()
		sheet.Open()
		Render()
	end)
	WM.On("CRAFT_SHOW", function()
		mode, view, selected = "craft", "list", nil
		craftOpen = true
		EnsureExpanded()
		sheet.Open()
		Render()
	end)
	WM.On("TRADE_SKILL_UPDATE", function()
		if mode == "trade" and sheet:IsShown() then
			EnsureExpanded()
			Render()
		end
	end)
	WM.On("CRAFT_UPDATE", function()
		if mode == "craft" and sheet:IsShown() then
			EnsureExpanded()
			Render()
		end
	end)
	WM.On("TRADE_SKILL_CLOSE", function() CloseSession("trade") end)
	WM.On("CRAFT_CLOSE", function() CloseSession("craft") end)

	-- Reagent have-counts move with the bags (crafting consumes mats).
	WM.On("BAG_UPDATE", function()
		if sheet:IsShown() then Render() end
	end)
end)
