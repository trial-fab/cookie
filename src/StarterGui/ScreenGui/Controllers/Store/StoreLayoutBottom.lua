-- StoreLayoutBottom: the horizontal "bottom bar" layout strategy. Same interface as
-- StoreLayout (applyStoreScale / snapStoreToRows / getMaxVisibleRows / getStoreScale) so the
-- StoreController orchestrator can pick either one by mode without changing its call sites.
--
-- Where StoreLayout (the sidebar) grows the store vertically and snaps it to the number of
-- rows that fit, this strategy pins the shell to a thin, full-width band along the bottom of
-- the screen and lets the PageTemplate scroll HORIZONTALLY through fixed-width cards. The
-- shell's internal arrangement (PageTemplate / TabBar / TopBar offsets) is authored in Studio
-- and left untouched -- we only drive the outer Size/Position/Anchor and the scroll axis.
local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

local DEFAULT_BAND_HEIGHT = 230 -- fallback if the authored shell height is missing
local SIDE_MARGIN = 0 -- gap from each screen edge; 0 = band spans the full screen width
local BOTTOM_MARGIN = 0 -- gap from the screen bottom; 0 = band is flush with the bottom edge
-- Desktop store scale. We can't size off "big monitor": Roblox normalizes the UI coordinate
-- space for DPI, so a 27" 1440p and a 24" 1080p both report ~1080-1150px short side -- the
-- viewport can't tell them apart. The band looked small at scale 1, so we just bump the base
-- desktop scale; DPI normalization keeps it visually consistent across monitors. Mobile still
-- shrinks separately.
local DEFAULT_STORE_SCALE = 1.15
local MOBILE_STORE_SCALE = 0.82
local MOBILE_BAND_MAX_HEIGHT_FRACTION = 0.42 -- band never eats more than this slice of the screen

local StoreLayoutBottom = {}

function StoreLayoutBottom.new(ctx)
	local store = ctx.store
	local pageContainer = ctx.pageContainer
	local storeScale = ctx.storeScale
	local baseStoreSize = ctx.baseStoreSize

	local M = {}

	-- The authored band height (StoreBottom is ~230px). Scale components are ignored here;
	-- the bottom bar is a fixed-height band, not a proportion of the screen.
	local bandHeight = (baseStoreSize and baseStoreSize.Y.Offset > 0) and baseStoreSize.Y.Offset or DEFAULT_BAND_HEIGHT

	local function getStoreScale()
		return math.max(storeScale.Scale, 0.01)
	end
	M.getStoreScale = getStoreScale

	-- Viewport read + the touch/short-side mobile predicate are shared (Shared/MobileScale)
	-- so there is one source of that logic. The band keeps its OWN scale constants below
	-- (a deliberately-larger desktop band, fixed mobile shrink) rather than the continuous
	-- design-resolution curve, which would make a full-width bottom bar tiny on phones.
	local function getViewportSize()
		return MobileScale.getViewportSize(store)
	end

	local function shouldUseMobile()
		return MobileScale.shouldUseMobile(store)
	end

	-- Mobile shrinks; every other (desktop) viewport uses the bumped base scale.
	local function targetScale()
		if shouldUseMobile() then
			return MOBILE_STORE_SCALE
		end

		return DEFAULT_STORE_SCALE
	end

	-- Force the PageTemplate to scroll horizontally regardless of how it was authored, so a
	-- stray Studio edit (e.g. ScrollingDirection left on Y) can't silently break the strip.
	local function enforceScroll()
		if not pageContainer:IsA("ScrollingFrame") then
			return
		end

		pageContainer.ScrollingDirection = Enum.ScrollingDirection.X
		pageContainer.AutomaticCanvasSize = Enum.AutomaticSize.X

		local layout = pageContainer:FindFirstChildOfClass("UIListLayout")
		if layout then
			layout.FillDirection = Enum.FillDirection.Horizontal
		end
	end

	-- Pin the shell to a thin, full-width band at the bottom of the screen. On phones, shrink
	-- everything through the shell UIScale and clamp the band so it never covers the play area.
	local function applyStoreScale()
		if not store:IsA("GuiObject") then
			return
		end

		enforceScroll()

		local useMobile = shouldUseMobile()
		storeScale.Scale = targetScale()

		local viewport = getViewportSize()
		local effectiveHeight = bandHeight
		if useMobile and viewport.Y > 0 then
			-- bandHeight is the unscaled content height; the UIScale shrinks the visual, but
			-- still clamp the scaled footprint to a fraction of the screen on short devices.
			local scaledHeight = bandHeight * getStoreScale()
			local maxHeight = viewport.Y * MOBILE_BAND_MAX_HEIGHT_FRACTION
			if scaledHeight > maxHeight then
				effectiveHeight = maxHeight / getStoreScale()
			end
		end

		-- The UIScale (storeScale) multiplies the band's rendered size about its anchor, so a
		-- full-width band (Size.X = 1) at scale > 1 overflows the screen left/right. Counter the
		-- scale on the width so the RENDERED width is exactly the viewport: base = 1/scale, which
		-- the UIScale multiplies back up to 1 (full screen) -- flush, no bleed, at any scale.
		-- Height intentionally stays unscaled here so the UIScale can grow it (taller content).
		local scale = getStoreScale()
		local widthScale = 1 / scale
		local marginOffset = -2 * SIDE_MARGIN / scale -- keep margins in screen px after the UIScale
		store.AnchorPoint = Vector2.new(0.5, 1)
		store.Size = UDim2.new(widthScale, marginOffset, 0, math.floor(effectiveHeight + 0.5))
		store.Position = UDim2.new(0.5, 0, 1, -BOTTOM_MARGIN)
	end
	M.applyStoreScale = applyStoreScale

	-- The band is a fixed height; cards scroll horizontally, so every item is "visible" and
	-- there is no vertical row-fitting to compute. Returning a large count lets renderRows
	-- show the whole category (it clamps to #orderedUpgradeIds itself).
	M.getMaxVisibleRows = function()
		return math.huge
	end

	-- No vertical snapping in bottom mode -- just keep the band/scroll config asserted. The
	-- horizontal canvas grows automatically (AutomaticCanvasSize = X).
	M.snapStoreToRows = function()
		enforceScroll()
	end

	return M
end

return StoreLayoutBottom
