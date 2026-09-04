--------------------------------------------------------------------------------
-- WowMobile · Viewport
-- Shrinks the 3D world (WorldFrame) to a square anchored to the top of the
-- 9:16 band (the full window in portrait mode, the centered landscape band
-- otherwise — Band.lua) and paints a black backdrop over the band region
-- below it — the "control deck" that owns all primary UI (see
-- docs/ARCHITECTURE.md §1). In landscape mode the world OUTSIDE the band is
-- deliberately not rendered: WorldFrame is sized to the band-width square,
-- and Band.lua's side rails black out the rest of the window.
--
-- Publishes:
--   WM.WorldSquare — insecure frame exactly covering the world region, used as
--                    the anchor for auras, minimap, quick bars and tooltips.
--   WM.Viewport.Apply() — (re)applies the configured ratio.
--   WM.Viewport.OnApply(fn)/HeightPx() — reflow hook + current height for the
--                    overlays that must track the configurable square height.
--------------------------------------------------------------------------------

local _, WM = ...

local Viewport = {}
WM.Viewport = Viewport

-- Anchor/overlay for the world region. Mouse-disabled: world taps must reach
-- WorldFrame (targeting, camera) untouched. Anchored to the band frame — NOT
-- UIParent — which is what carries the square (and everything hanging off it)
-- into the centered band in landscape mode; in portrait mode the band frame
-- covers the whole window and this is identical to the pre-band layout.
local bandHost = WM.BandFrame or UIParent -- Band.lua loads first; nil-guard mirrors Core's crash-tolerance style
local square = CreateFrame("Frame", "WowMobileWorldSquare", UIParent)
square:SetPoint("TOPLEFT", bandHost, "TOPLEFT", 0, 0)
square:SetPoint("TOPRIGHT", bandHost, "TOPRIGHT", 0, 0)
square:SetHeight(WM.Px(1080))
square:SetFrameStrata("BACKGROUND")
square:EnableMouse(false)
WM.WorldSquare = square

-- Black backdrop behind everything below the square, spanning the band. The
-- deck's flat 2D look is also what keeps the H.264 encoder cheap there.
local backdrop = CreateFrame("Frame", "WowMobileDeckBackdrop", UIParent)
backdrop:SetPoint("TOPLEFT", square, "BOTTOMLEFT", 0, 0)
backdrop:SetPoint("BOTTOMRIGHT", bandHost, "BOTTOMRIGHT", 0, 0)
backdrop:SetFrameStrata("BACKGROUND")
backdrop:SetFrameLevel(0)
backdrop:EnableMouse(false)
local black = backdrop:CreateTexture(nil, "BACKGROUND")
black:SetAllPoints()
black:SetColorTexture(0, 0, 0, 1)
WM.DeckBackdrop = backdrop

-- viewport.height is design px of the 1080-wide window (the saved variable
-- ARCHITECTURE §1 documents, default 1080); as a fraction of the design width
-- it scales to any real capture resolution.
function Viewport.HeightPx()
	return (WM.db and WM.db.viewport.height) or 1080
end

-- World-square overlays whose layout depends on the configurable square
-- height (quick-bar column, party-frame re-home) register here. Callbacks run
-- inside Apply's out-of-combat closure — secure Show/Hide and SetScale are
-- legal there — receiving the square height in design px, and must be
-- idempotent (Apply re-runs on login, /wm viewport, and scale/size changes).
local reflowers = {}

function Viewport.OnApply(fn)
	reflowers[#reflowers + 1] = fn
end

-- Last height a bounds-clamp notice was printed for: Apply re-runs on every
-- loading screen and scale/size change, so the notice dedupes on the clamped
-- value instead of spamming chat (and the phone screen) each time.
local warnedClampPx

function Viewport.Apply()
	WM.OutOfCombat("viewport", function()
		local heightPx = Viewport.HeightPx()
		-- Re-clamp against the LIVE mode's bounds. Config.SetHeight clamps at
		-- set time only, but the bounds move with the window mode: a height
		-- saved legally under a taller-than-9:16 portrait window (RatioMax up
		-- to 1.20) exceeds the exactly-9:16 band mode's ceiling after the
		-- server switches layouts. Applied verbatim it would sink the world
		-- square's bottom rows under the bottom-anchored deck stack, so clamp
		-- for use here — the saved value is deliberately NOT rewritten, since
		-- a transient window resize must not ratchet the user's choice down —
		-- and say so once, because the phone splits its gesture zones by its
		-- own World viewport setting, which must track the value actually
		-- applied.
		if WM.Config and WM.Config.HeightBounds then
			local lo, hi = WM.Config.HeightBounds()
			local clamped = heightPx
			if clamped < lo then clamped = lo end
			if clamped > hi then clamped = hi end
			if clamped ~= heightPx then
				if warnedClampPx ~= clamped then
					warnedClampPx = clamped
					WM.Print(string.format(
						"saved world viewport height %d is outside this window mode's bounds (%d..%d) — using %d; set the same value in the phone client (Set > World viewport), or /wm viewport to re-save",
						heightPx, lo, hi, clamped))
				end
				heightPx = clamped
			end
		end
		local ratio = heightPx / 1080
		-- Height in UI units equals the BAND width in UI units at ratio 1.0
		-- (the band IS the design space; full window width in portrait mode).
		-- Converted into WorldFrame's own coordinate space because WorldFrame
		-- does not inherit uiScale from UIParent — offsets passed to SetPoint
		-- are in the moved frame's space, so the band-left offset converts too.
		local bandLeftUI = (WM.Band and WM.Band.left) or 0
		local bandWidthUI = (WM.Band and WM.Band.width) or UIParent:GetWidth()
		local heightUI = bandWidthUI * ratio
		local toWF = UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale()
		WorldFrame:ClearAllPoints()
		WorldFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", bandLeftUI * toWF, 0)
		WorldFrame:SetSize(bandWidthUI * toWF, heightUI * toWF)
		square:SetHeight(heightUI)
		for i = 1, #reflowers do
			reflowers[i](heightPx)
		end
	end)
end

WM.OnInit(function()
	Viewport.Apply()

	-- Error/info text ("Out of range", quest progress lines): top-center of
	-- the world square, below the aura rows AND their duration texts — the
	-- debuff cells end at y=208 and their cell.remain texts hang 24 px below,
	-- to ~232 (Auras.lua) — so y=240, the same clearance lane as the quest
	-- tracker (QuestLog.lua), well away from resting thumbs. StaticPopups
	-- (head at y=230, Blizzard.lua) live on the DIALOG strata and draw over
	-- this transient text either way.
	UIErrorsFrame:ClearAllPoints()
	UIErrorsFrame:SetPoint("TOP", square, "TOP", 0, -WM.Px(240))
	UIErrorsFrame:SetWidth(WM.Px(1000))
	if UIErrorsFrame.SetFont then
		UIErrorsFrame:SetFont(STANDARD_TEXT_FONT, WM.Px(32), "OUTLINE")
	end
end)

-- Loading screens don't reset WorldFrame geometry, but scale/resolution
-- changes invalidate both the px factor and the square; re-apply cheaply.
WM.On("PLAYER_ENTERING_WORLD", function() Viewport.Apply() end)
WM.On("UI_SCALE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
WM.On("DISPLAY_SIZE_CHANGED", function()
	WM.UpdatePxFactor()
	Viewport.Apply()
end)
