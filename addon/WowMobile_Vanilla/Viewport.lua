--------------------------------------------------------------------------------
-- WowMobile (Vanilla 1.12) · Viewport
-- Shrinks the 3D world (WorldFrame) to a square anchored to the top of the
-- 1080x1920 window and paints a black backdrop over the region below it — the
-- "control deck" that owns all primary UI.
--
-- Publishes:
--   WM.WorldSquare — frame exactly covering the world region, used as the
--                    anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--
-- WorldFrame geometry manipulation is the classic 1.12 "viewport" technique
-- (CT_Viewport-style): WorldFrame does not inherit uiScale from UIParent, so
-- the height is converted into its own coordinate space.
--------------------------------------------------------------------------------

local WM = WowMobile

local Viewport = {}
WM.Viewport = Viewport

-- Anchor/overlay for the world region. Mouse-disabled: world taps must reach
-- WorldFrame (targeting, camera) untouched.
local square = CreateFrame("Frame", "WowMobileWorldSquare", UIParent)
square:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
square:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
square:SetHeight(WM.Px(1080))
square:SetFrameStrata("BACKGROUND")
square:EnableMouse(false)
WM.WorldSquare = square

-- Black backdrop behind everything below the square. The deck's flat 2D look
-- is also what keeps the H.264 encoder cheap in that region.
local backdrop = CreateFrame("Frame", "WowMobileDeckBackdrop", UIParent)
backdrop:SetPoint("TOPLEFT", square, "BOTTOMLEFT", 0, 0)
backdrop:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
backdrop:SetFrameStrata("BACKGROUND")
backdrop:SetFrameLevel(0)
backdrop:EnableMouse(false)
local black = backdrop:CreateTexture(nil, "BACKGROUND")
black:SetAllPoints(backdrop)
black:SetTexture(0, 0, 0, 1)
WM.DeckBackdrop = backdrop

-- viewport.height is design px of the 1080-wide window (default 1080); as a
-- fraction of the design width it scales to any real capture resolution.
function Viewport.HeightPx()
	return (WM.db and WM.db.viewport and WM.db.viewport.height) or 1080
end

-- World-square overlays whose layout depends on the configurable square
-- height register here; callbacks receive the square height in design px and
-- must be idempotent (Apply re-runs on login, /wm viewport, world entry).
local reflowers = {}

function Viewport.OnApply(fn)
	table.insert(reflowers, fn)
end

-- The intended square height in UI units, derived ONLY from live
-- measurements taken at call time: UIParent's width (scale-free — a design
-- ratio of 1.0 means "square = window width", true at any resolution and any
-- effective scale) capped so the fixed deck stack still fits below it. The
-- cap only engages when the window is not the portrait 9:16 shape the design
-- assumes (a landscape/clamped window — the "world stretched across the
-- whole screen" field failure); the caller reports that.
-- Returns heightUI, clamped(boolean).
local function ComputeHeightUI()
	local ratio = Viewport.HeightPx() / 1080
	local heightUI = UIParent:GetWidth() * ratio
	local deckFixed = (WM.Config and WM.Config.DECK_FIXED_PX) or 790
	local maxUI = UIParent:GetHeight() - WM.Px(deckFixed)
	if maxUI < UIParent:GetHeight() * 0.25 then
		maxUI = UIParent:GetHeight() * 0.25 -- degenerate window: keep SOME world
	end
	if heightUI > maxUI then
		return maxUI, true
	end
	return heightUI, false
end

local badShapeReported = false
local verifyQueued = false

function Viewport.Apply()
	local heightUI, clamped = ComputeHeightUI()
	-- What the overlays must lay out against: the square that actually
	-- applied, expressed back in design px (equals the configured height
	-- whenever the clamp did not engage).
	local heightPx = heightUI * 1080 / UIParent:GetWidth()
	-- Converted into WorldFrame's own coordinate space because WorldFrame
	-- does not inherit uiScale from UIParent (both effective scales are LIVE
	-- measurements, so this is right whatever the cvars say).
	local heightWF = heightUI * UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
	WorldFrame:ClearAllPoints()
	WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
	WorldFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
	WorldFrame:SetHeight(heightWF)
	square:SetHeight(heightUI)
	if clamped and not badShapeReported then
		badShapeReported = true
		WM.ReportError(string.format(
			"Viewport.lua: window is not the portrait shape the deck needs (%.0fx%.0f UI units)"
				.. " — world square clamped; run the server wizard so it writes the 9:16"
				.. " gxWindowedResolution, then reload",
			UIParent:GetWidth(), UIParent:GetHeight()))
		WM.ShowSetupBanner("The WoW window is not the portrait size WoW Mobile configured.")
	end
	for i = 1, table.getn(reflowers) do
		reflowers[i](heightPx)
	end
	-- Self-verification: measure what actually ended up on screen shortly
	-- after (geometry settles within a frame or two). One pending check at a
	-- time — Apply re-runs on login/world-entry/setting changes.
	if not verifyQueued then
		verifyQueued = true
		WM.After(0.5, function()
			verifyQueued = false
			Viewport.Verify()
		end)
	end
end

-- Measure WorldFrame's ACTUAL on-screen rect against the intended square
-- (both sides in physical screen px via the live effective scales). Any
-- mismatch — a client that reset WorldFrame behind our back, a scale that
-- shifted after Apply, SetHeight silently refused — is recorded like a crash
-- (/wm errors lists it) and raises the reload banner: a stretched world must
-- never pass silently again.
local verifyReported = false

function Viewport.Verify()
	local wfL, wfR = WorldFrame:GetLeft(), WorldFrame:GetRight()
	local wfT, wfB = WorldFrame:GetTop(), WorldFrame:GetBottom()
	local uL, uR, uT = UIParent:GetLeft(), UIParent:GetRight(), UIParent:GetTop()
	if not wfL or not wfR or not wfT or not wfB or not uL then return end
	local ws = WorldFrame:GetEffectiveScale()
	local us = UIParent:GetEffectiveScale()
	local wantH = ComputeHeightUI() * us -- intended square, re-measured NOW
	local wantW = (uR - uL) * us
	local tol = 2 + wantW * 0.005 -- rounding slack: 0.5% + 2 screen px
	local badTop = math.abs(wfT * ws - uT * us) > tol
	local badW = math.abs((wfR - wfL) * ws - wantW) > tol
	local badH = math.abs((wfT - wfB) * ws - wantH) > tol
	if not (badTop or badW or badH) then return end
	if not verifyReported then
		verifyReported = true
		WM.ReportError(string.format(
			"Viewport.lua: world square did not apply — WorldFrame is %.0fx%.0f px at top %.0f,"
				.. " wanted %.0fx%.0f at top %.0f (world looks stretched); reload to reapply",
			(wfR - wfL) * ws, (wfT - wfB) * ws, wfT * ws, wantW, wantH, uT * us))
	end
	WM.ShowSetupBanner("The 3D world viewport did not apply — the world looks stretched.")
end

WM.OnInit(function()
	Viewport.Apply()

	-- Error/info text ("Out of range", quest progress lines): top-center of
	-- the world square, below the aura rows AND their duration texts — the
	-- debuff cells end at y=208 and their cell.remain texts hang to ~232
	-- (Auras.lua) — so y=240, the same clearance lane as the quest tracker
	-- (QuestLog.lua), well away from resting thumbs.
	UIErrorsFrame:ClearAllPoints()
	UIErrorsFrame:SetPoint("TOP", square, "TOP", 0, -WM.Px(240))
	UIErrorsFrame:SetWidth(WM.Px(1000))
	if UIErrorsFrame.SetFont then
		UIErrorsFrame:SetFont(WM.FONT, WM.Px(32), "OUTLINE")
	end
end)

-- Loading screens don't reset WorldFrame geometry, but scale/resolution
-- changes invalidate both the px factor and the square; re-apply cheaply.
-- (UI_SCALE_CHANGED / DISPLAY_SIZE_CHANGED are later-client events — TryOn
-- drops them silently if this 1.12 build lacks them.)
WM.On("PLAYER_ENTERING_WORLD", function() Viewport.Apply() end)
-- The freshness check also compares the LIVE window against the size the
-- deck's frames were laid out with; a change here means those frames are
-- stale — the check raises the reload banner (the square itself re-applies
-- correctly either way).
WM.TryOn("UI_SCALE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
	WM.CheckLayoutFresh()
end)
WM.TryOn("DISPLAY_SIZE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
	WM.CheckLayoutFresh()
end)
