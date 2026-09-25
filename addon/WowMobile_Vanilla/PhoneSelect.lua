--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · PhoneSelect — Lua 5.0 port of the Classic Era
-- phone-model selector (docs/PHONE_FRAME.md §6)
-- A panel on the PC-only area beside the red phone outline (right of it, or
-- left when the right side is too narrow — never inside the frame, which is
-- the stream): a search box, the phone list (the 20 most-used models first,
-- then every other model in phones/phones.json), a custom W x H entry, and
-- the live numbers — the game window in physical px and the frame the chosen
-- phone gets inside it. Picking a phone reshapes the outline immediately; the
-- touch layout inside it is rebuilt on /reload (one tap on the panel).
--
-- Sizes here are plain UI units, not WM.Px design px: the panel is for the
-- person at the PC and must not grow or shrink with the phone frame.
--
-- 1.12 differences: Lua 5.0 (table.getn, string.gfind), script handlers read
-- `this`/`arg1`, SetTexture(r,g,b,a), SetWidth/SetHeight, WM.SetShown, no
-- combat lockdown (the combat hide is only about the search box's focus).
--------------------------------------------------------------------------------

local WM = WowMobile

local Band = WM.Band
local Data = WM.PhoneData

local PhoneSelect = {}
WM.PhoneSelect = PhoneSelect

local PANEL_W = 300
local ROWS = 12
local ROW_H = 22
local PAD = 10
local GAP = 12 -- distance from the outline

local GOLD = { 0.83, 0.63, 0.09 }

local panel, tab, search, rows, info, frameInfo, reloadBtn, customW, customH, scrollText
local filtered = {}
local offset = 0

--------------------------------------------------------------------------------
-- Widgets (textures only: no BackdropTemplate differences across clients)
--------------------------------------------------------------------------------

local function Fill(frame, r, g, b, a, layer)
	local t = frame:CreateTexture(nil, layer or "BACKGROUND")
	t:SetAllPoints(frame)
	t:SetTexture(r, g, b, a)
	return t
end

local function Size(f, w, h)
	f:SetWidth(w)
	f:SetHeight(h)
end

local function Text(parent, size, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(WM.FONT, size, "")
	fs:SetJustifyH(justify or "LEFT")
	fs:SetTextColor(0.91, 0.90, 0.87)
	return fs
end

local function Button(parent, label, w, h, onClick)
	local b = CreateFrame("Button", nil, parent)
	Size(b, w, h)
	b.bg = Fill(b, 0.25, 0.20, 0.08, 1)
	b.hl = b:CreateTexture(nil, "HIGHLIGHT")
	b.hl:SetAllPoints(b)
	b.hl:SetTexture(1, 1, 1, 0.08)
	b.text = Text(b, 12, "CENTER")
	b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.text:SetText(label)
	b:SetScript("OnClick", function() onClick(this) end)
	return b
end

local function Edit(parent, w, h, numeric)
	local e = CreateFrame("EditBox", nil, parent)
	Size(e, w, h)
	e:SetAutoFocus(false)
	if e.SetFont then
		e:SetFont(WM.FONT, 12)
	else
		e:SetFontObject(ChatFontNormal)
	end
	if e.SetTextInsets then e:SetTextInsets(6, 6, 0, 0) end
	if numeric then
		e:SetMaxLetters(4)
		if e.SetNumeric then e:SetNumeric(true) end
	else
		e:SetMaxLetters(40)
	end
	Fill(e, 1, 1, 1, 0.08)
	e:SetScript("OnEscapePressed", function() this:ClearFocus() end)
	e:SetScript("OnEnterPressed", function() this:ClearFocus() end)
	return e
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

local function Matches(p, terms)
	local hay = string.lower(p.brand .. " " .. p.model .. " " .. p.id)
	for i = 1, table.getn(terms) do
		if not string.find(hay, terms[i], 1, true) then return false end
	end
	return true
end

-- The table arrives in selector order (popularity rank, then brand/model).
local function Filter(query)
	local terms = {}
	for t in string.gfind(string.lower(query or ""), "%S+") do
		table.insert(terms, t)
	end
	local out = {}
	for i = 1, table.getn(Data.list) do
		local p = Data.list[i]
		if Matches(p, terms) then table.insert(out, p) end
	end
	return out
end
PhoneSelect.Filter = Filter

local function RenderRows()
	if not panel then return end
	local n = table.getn(filtered)
	local maxOffset = math.max(0, n - ROWS)
	if offset > maxOffset then offset = maxOffset end
	if offset < 0 then offset = 0 end
	local cur = Band.phone and Band.phone.id
	for i = 1, ROWS do
		local row = rows[i]
		local p = filtered[offset + i]
		if p then
			row.phone = p
			local rank = ""
			if p.popularity > 0 then rank = p.popularity .. ". " end
			row.name:SetText(rank .. Band.PhoneName(p))
			row.dims:SetText(p.streamW .. "x" .. p.streamH)
			local on = p.id == cur
			WM.SetShown(row.sel, on)
			if on then
				row.name:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
			else
				row.name:SetTextColor(0.91, 0.90, 0.87)
			end
			row:Show()
		else
			row.phone = nil
			row:Hide()
		end
	end
	if n == 0 then
		scrollText:SetText("no phone matches — try a shorter search, or enter a custom size below")
	elseif n > ROWS then
		scrollText:SetText(string.format("%d-%d of %d  (mouse wheel to scroll)",
			offset + 1, math.min(offset + ROWS, n), n))
	elseif n == 1 then
		scrollText:SetText("1 phone")
	else
		scrollText:SetText(n .. " phones")
	end
end

local function RenderInfo()
	if not panel then return end
	local c, px = Band.client, Band.px
	local approx = ""
	if px.approx then approx = " (UI units)" end
	info:SetText(string.format("Game window: %d x %d px%s", c.w, c.h, approx))
	frameInfo:SetText(string.format("Phone: %s\nFrame: %d x %d px (inside the red outline)",
		Band.PhoneName(Band.phone), px.width, px.height))
	WM.SetShown(reloadBtn, Band.NeedsReload())
end

--------------------------------------------------------------------------------
-- Placement: beside the outline, never over the frame
--------------------------------------------------------------------------------

local function Place()
	if not panel then return end
	local ringUI = Data.ringPx * Band.unit
	local uiW = UIParent:GetWidth()
	local rightSpace = uiW - Band.right - ringUI
	local leftSpace = Band.left - ringUI
	local need = PANEL_W + 2 * GAP
	panel:ClearAllPoints()
	tab:ClearAllPoints()
	local side
	if rightSpace >= need then
		side = "right"
		panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.right + ringUI + GAP, -(Band.top + GAP))
	elseif leftSpace >= need then
		side = "left"
		panel:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", Band.left - ringUI - GAP, -(Band.top + GAP))
	end
	PhoneSelect.side = side
	-- The reopen tab follows the same rule: never inside the streamed frame
	-- (a portrait window leaves no room at all — /wm phone still works).
	PhoneSelect.tabOK = true
	if rightSpace >= 130 + 2 * GAP then
		tab:SetPoint("TOPLEFT", UIParent, "TOPLEFT", Band.right + ringUI + GAP, -(Band.top + GAP))
	elseif leftSpace >= 130 + 2 * GAP then
		tab:SetPoint("TOPRIGHT", UIParent, "TOPLEFT", Band.left - ringUI - GAP, -(Band.top + GAP))
	else
		PhoneSelect.tabOK = false
	end
end

local hiddenByCombat = false

local function Visible()
	return not (WM.db and WM.db.phonePanelHidden)
end

local function Refresh()
	if not panel then return end
	Place()
	RenderInfo()
	RenderRows()
	local canShow = PhoneSelect.side ~= nil and not hiddenByCombat
	WM.SetShown(panel, canShow and Visible())
	WM.SetShown(tab, PhoneSelect.tabOK and not hiddenByCombat and not panel:IsShown())
end

function PhoneSelect.Show(show)
	if WM.db then WM.db.phonePanelHidden = not show end
	Refresh()
	if show and PhoneSelect.side == nil then
		WM.Print("the game window is too narrow to show the phone selector beside the outline — use /wm phone <name> (e.g. /wm phone iphone 16) or /wm phone 1080x2340")
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Build()
	panel = CreateFrame("Frame", "WowMobilePhoneSelect", UIParent)
	panel:SetFrameStrata("HIGH")
	panel:SetWidth(PANEL_W)
	panel:EnableMouse(true)
	panel:SetClampedToScreen(true)
	Fill(panel, 0.06, 0.06, 0.09, 0.96)
	local edge = panel:CreateTexture(nil, "BORDER")
	edge:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	edge:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	edge:SetHeight(2)
	edge:SetTexture(1, 0, 0, 1)

	local title = Text(panel, 14)
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
	title:SetText("WoW Mobile — your phone")
	title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	local close = Button(panel, "x", 22, 22, function() PhoneSelect.Show(false) end)
	close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

	local hint = Text(panel, 11)
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	hint:SetWidth(PANEL_W - 2 * PAD)
	hint:SetText("The red outline is your phone screen: arrange your UI inside it. Pick your phone so the outline matches it.")
	hint:SetTextColor(0.62, 0.60, 0.66)

	info = Text(panel, 12)
	info:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
	frameInfo = Text(panel, 12)
	frameInfo:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -4)
	frameInfo:SetWidth(PANEL_W - 2 * PAD)

	search = Edit(panel, PANEL_W - 2 * PAD, 24)
	search:SetPoint("TOPLEFT", frameInfo, "BOTTOMLEFT", 0, -10)
	local ph = Text(search, 12)
	ph:SetPoint("LEFT", search, "LEFT", 6, 0)
	ph:SetText("Search phones (e.g. \"galaxy s25\")")
	ph:SetTextColor(0.5, 0.5, 0.55)
	search:SetScript("OnTextChanged", function()
		local q = this:GetText()
		WM.SetShown(ph, q == "")
		filtered = Filter(q)
		offset = 0
		RenderRows()
	end)

	local list = CreateFrame("Frame", nil, panel)
	list:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -6)
	Size(list, PANEL_W - 2 * PAD, ROWS * ROW_H)
	list:EnableMouseWheel(true)
	-- 1.12 OnMouseWheel: arg1 = wheel direction.
	list:SetScript("OnMouseWheel", function()
		offset = offset - arg1 * 3
		RenderRows()
	end)
	rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		Size(row, PANEL_W - 2 * PAD, ROW_H)
		row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * ROW_H)
		row.sel = Fill(row, GOLD[1], GOLD[2], GOLD[3], 0.18)
		row.sel:Hide()
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		hl:SetTexture(1, 1, 1, 0.07)
		row.name = Text(row, 12)
		row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
		row.name:SetPoint("RIGHT", row, "RIGHT", -80, 0)
		row.dims = Text(row, 11, "RIGHT")
		row.dims:SetPoint("RIGHT", row, "RIGHT", -6, 0)
		row.dims:SetTextColor(0.62, 0.60, 0.66)
		row:SetScript("OnClick", function()
			if this.phone then
				Band.SetPhone(this.phone.id)
			end
		end)
		rows[i] = row
	end
	scrollText = Text(panel, 10)
	scrollText:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -4)
	scrollText:SetTextColor(0.62, 0.60, 0.66)

	local customLabel = Text(panel, 12)
	customLabel:SetPoint("TOPLEFT", scrollText, "BOTTOMLEFT", 0, -10)
	customLabel:SetText("Not listed? Stream size:")
	customW = Edit(panel, 56, 22, true)
	customW:SetPoint("TOPLEFT", customLabel, "BOTTOMLEFT", 0, -4)
	local x = Text(panel, 12)
	x:SetPoint("LEFT", customW, "RIGHT", 4, 0)
	x:SetText("x")
	customH = Edit(panel, 56, 22, true)
	customH:SetPoint("LEFT", x, "RIGHT", 4, 0)
	local use = Button(panel, "Use", 60, 22, function()
		if not Band.SetCustom(customW:GetText(), customH:GetText()) then
			WM.Print("custom size must be portrait (height > width), 100..8000 px each — e.g. 1080 x 2340")
		end
	end)
	use:SetPoint("LEFT", customH, "RIGHT", 8, 0)

	reloadBtn = Button(panel, "Reload UI to rebuild the layout", PANEL_W - 2 * PAD, 26, function()
		ReloadUI()
	end)
	reloadBtn.bg:SetTexture(0.55, 0.10, 0.10, 1)
	reloadBtn:SetPoint("TOPLEFT", customW, "BOTTOMLEFT", 0, -12)
	reloadBtn:Hide()

	-- Total height: everything above is anchored top-down.
	panel:SetHeight(PAD + 18 + 6 + 30 + 8 + 14 + 4 + 30 + 10 + 24 + 6 + ROWS * ROW_H + 4 + 12 + 10 + 14 + 4 + 22 + 12 + 26 + PAD)

	tab = Button(UIParent, "Phone: pick model", 130, 24, function() PhoneSelect.Show(true) end)
	tab:SetFrameStrata("HIGH")
	tab.bg:SetTexture(0.45, 0.05, 0.05, 0.95)

	filtered = Filter("")
end

--------------------------------------------------------------------------------
-- /wm phone
--------------------------------------------------------------------------------

function PhoneSelect.Command(arg)
	arg = arg or ""
	if arg == "" then
		PhoneSelect.Show(not (panel and panel:IsShown()))
		return
	end
	local _, _, w, h = string.find(arg, "^(%d+)%s*[xX]%s*(%d+)$")
	if w then
		if not Band.SetCustom(w, h) then
			WM.Print("custom size must be portrait (height > width), 100..8000 px each — e.g. /wm phone 1080x2340")
		end
		return
	end
	if Band.SetPhone(string.lower(arg)) then return end
	local hits = Filter(arg)
	local n = table.getn(hits)
	if n == 1 then
		Band.SetPhone(hits[1].id)
	elseif n == 0 then
		WM.Print("no phone matches \"" .. arg .. "\" — /wm phone opens the list; /wm phone WxH sets a custom size")
	else
		WM.Print(string.format("%d phones match \"%s\":", n, arg))
		for i = 1, math.min(n, 8) do
			WM.Print("  /wm phone " .. hits[i].id .. "  — " .. Band.PhoneName(hits[i]))
		end
		if panel then
			search:SetText(arg)
			PhoneSelect.Show(true)
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

WM.OnInit(function()
	Build()
	Band.OnChange(Refresh)
	Refresh()
end)

-- Out of the way in combat (a focused search box would swallow keys the
-- fight needs).
WM.On("PLAYER_REGEN_DISABLED", function()
	hiddenByCombat = true
	if search then search:ClearFocus() end
	Refresh()
end)
WM.On("PLAYER_REGEN_ENABLED", function()
	hiddenByCombat = false
	Refresh()
end)
