-- MobileScale: the shared responsive-UI scaler every menu uses, so one tuned standard
-- governs all viewports. It scales a frame's single UIScale by the CONTINUOUS
-- "design resolution" factor: scale = min(vp.X/1920, vp.Y/1080), clamped to [MIN, MAX].
-- At 1080p this is exactly 1, so PC designs are unchanged; phones/tablets scale down
-- smoothly and large/ultrawide screens scale up within the clamp. Roblox normalizes the
-- viewport to device-independent pixels, so most desktop monitors land near 1.
--
-- Re-evaluates whenever the viewport size or the current camera changes (e.g. an
-- orientation flip).
--
-- Entry points:
--   computeScale(viewportSize, opts) -- pure: the factor for a given Vector2 viewport,
--                                        with no global reads (testable via execute_luau).
--   targetScale(gui, opts)           -- computeScale for the gui's live viewport; for
--   + onViewportChanged(cb)             frames that already drive their own UIScale (e.g.
--                                        an open/close pop) and must FOLD this factor into
--                                        it rather than stack a second UIScale.
--   apply(gui, opts)                 -- frames with no animation UIScale of their own:
--                                        ensures a single UIScale (reusing an existing one,
--                                        like the Store) and keeps its Scale in sync.
--
-- `opts` (optional, all entry points): { multiplier, min, max }. `multiplier` lets a
-- consumer bias the whole curve (the Store band is deliberately larger). `min`/`max`
-- override the default clamp.
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local DESIGN_RESOLUTION = Vector2.new(1920, 1080)
local MIN_SCALE = 0.5
local MAX_SCALE = 1.25

-- How sensitive desktop scaling is to window size. The raw design-res factor (viewport/1920x1080)
-- shrinks UI fast as the window drops below 1080p; this damps that toward 1.0 so modals stay large
-- when there's still room. 1 = raw/full sensitivity, 0 = never scale (always 1). At 0.5 a 1280x720
-- window gives ~0.83 instead of ~0.67. 1080p is always exactly 1 regardless.
local DESKTOP_SENSITIVITY = 0.5

-- Safe-area margins for fitScale/resolveModal (an offset modal fitted to the usable
-- band so it never overflows or overlaps the topbar/hotbar). Tune these if the hotbar height
-- changes. The top is taken from GuiService:GetGuiInset() (the Roblox topbar); the bottom is a
-- fixed reserve for the game's own bottom hotbar/store band, which isn't part of the GUI inset.
local SAFE_SIDE_MARGIN = 12
local SAFE_TOP_MARGIN = 12
local SAFE_BOTTOM_RESERVE = 96
local FIT_FLOOR = 0.2 -- never scale a fitted modal below this

-- Hybrid mobile scale: on a phone the modal's box resizes to fit AND this gentle UIScale shrinks
-- the elements a bit so more content fits per screen (vs native size, which looks huge with only a
-- row or two visible). Closer to 1 = bigger/more readable but fewer rows; lower = more fits.
local MOBILE_SCALE = 0.6

-- Touch-device predicate threshold, kept for mobile-only HUD nudges (shiftLeftOnMobile)
-- and for consumers (Store/Hotbar) that still want a hard mobile branch on top of the
-- continuous scale. This is the single source of that threshold.
local MOBILE_VIEWPORT_MAX_SHORT_SIDE = 600

local MobileScale = {}

MobileScale.DESIGN_RESOLUTION = DESIGN_RESOLUTION
MobileScale.MOBILE_VIEWPORT_MAX_SHORT_SIDE = MOBILE_VIEWPORT_MAX_SHORT_SIDE

local function clamp(value, lower, upper)
	if value < lower then
		return lower
	elseif value > upper then
		return upper
	end
	return value
end

-- Pure: the continuous design-resolution factor for a given viewport. No global reads so
-- it can be asserted directly (e.g. computeScale(Vector2.new(1920,1080)) == 1).
local function computeScale(viewportSize, opts)
	opts = opts or {}
	if not viewportSize or viewportSize.X <= 0 or viewportSize.Y <= 0 then
		return clamp(opts.multiplier or 1, opts.min or MIN_SCALE, opts.max or MAX_SCALE)
	end

	local ratio = math.min(viewportSize.X / DESIGN_RESOLUTION.X, viewportSize.Y / DESIGN_RESOLUTION.Y)
	-- Damp how far the scale moves away from 1.0 (less sensitive to window size). 1080p (ratio 1)
	-- is unaffected; smaller windows shrink more gently.
	local sensitivity = opts.sensitivity or DESKTOP_SENSITIVITY
	local damped = (1 + (ratio - 1) * sensitivity) * (opts.multiplier or 1)

	return clamp(damped, opts.min or MIN_SCALE, opts.max or MAX_SCALE)
end
MobileScale.computeScale = computeScale

local function getViewportSize(gui)
	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0 then
		return camera.ViewportSize
	end

	local parent = gui and gui.Parent
	if parent and parent:IsA("GuiObject") and parent.AbsoluteSize.X > 0 and parent.AbsoluteSize.Y > 0 then
		return parent.AbsoluteSize
	end

	return Vector2.zero
end
MobileScale.getViewportSize = getViewportSize

-- Insets from the physical viewport edges to Roblox's Core UI safe rectangle. A full-screen
-- surface may still draw edge-to-edge, but its header and primary content must start inside
-- these offsets so they are not hidden by a notch or topbar controls. Compact modal close
-- buttons intentionally use the game's separate topbar control slot instead.
-- GetInsetArea is preferred because this ScreenGui deliberately renders with no automatic
-- insets. The GetGuiInset fallback keeps older clients usable if the newer API is unavailable.
function MobileScale.getCoreSafeOffsets(gui)
	local ok, noneRect, coreRect = pcall(function()
		return GuiService:GetInsetArea(Enum.ScreenInsets.None),
			GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
	end)
	if ok and noneRect and coreRect then
		return Vector2.new(
			math.max(0, coreRect.Min.X - noneRect.Min.X),
			math.max(0, coreRect.Min.Y - noneRect.Min.Y)
		), Vector2.new(
			math.max(0, noneRect.Max.X - coreRect.Max.X),
			math.max(0, noneRect.Max.Y - coreRect.Max.Y)
		)
	end

	local insetTopLeft = GuiService:GetGuiInset()
	return Vector2.new(math.max(0, insetTopLeft.X), math.max(0, insetTopLeft.Y)), Vector2.zero
end

local function isCompactViewport(viewportSize, touchEnabled)
	if not touchEnabled then
		return false
	end
	if not viewportSize or viewportSize.X <= 0 or viewportSize.Y <= 0 then
		return false
	end
	return math.min(viewportSize.X, viewportSize.Y) <= MOBILE_VIEWPORT_MAX_SHORT_SIDE
end
MobileScale.isCompactViewport = isCompactViewport

local function shouldUseMobile(gui)
	return isCompactViewport(getViewportSize(gui), UserInputService.TouchEnabled)
end
MobileScale.shouldUseMobile = shouldUseMobile

-- The continuous responsive scale for the gui's live viewport.
function MobileScale.targetScale(gui, opts)
	return computeScale(getViewportSize(gui), opts)
end

-- Returns `position` shifted left by `px` pixels of X-offset on a mobile viewport, otherwise
-- unchanged. Used to nudge right-edge HUD clear of rounded screen corners when the ScreenGui's
-- device-safe clipping is off. Pair with onViewportChanged to re-apply on orientation changes.
function MobileScale.shiftLeftOnMobile(position, px, gui)
	local shift = shouldUseMobile(gui) and px or 0
	return UDim2.new(position.X.Scale, position.X.Offset - shift, position.Y.Scale, position.Y.Offset)
end

-- Run `callback` once now and again whenever the viewport size or current camera changes.
function MobileScale.onViewportChanged(callback)
	callback()

	local connections = {}
	local cameraConnection = nil
	local function add(connection)
		table.insert(connections, connection)
		return connection
	end

	local function bindCamera(camera)
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		if camera then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(callback)
		end
	end

	bindCamera(Workspace.CurrentCamera)
	add(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bindCamera(Workspace.CurrentCamera)
		callback()
	end))

	return {
		destroy = function()
			if cameraConnection then
				cameraConnection:Disconnect()
				cameraConnection = nil
			end
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
		Destroy = function(self)
			self:destroy()
		end,
	}
end

local function bindViewport(gui, callback)
	local handle = MobileScale.onViewportChanged(callback)
	gui.Destroying:Once(function()
		handle:destroy()
	end)
end

-- The usable vertical band on screen: [topEdge, bottomEdge] in raw screen pixels, clear of the
-- Roblox topbar (GUI inset) and the bottom hotbar reserve. The ScreenGui has IgnoreGuiInset on,
-- so coordinate 0 is the true screen top and we must dodge the topbar ourselves.
local function usableBand(gui)
	local vp = getViewportSize(gui)
	local insetTopLeft = GuiService:GetGuiInset()
	local topEdge = insetTopLeft.Y + SAFE_TOP_MARGIN
	local bottomEdge = vp.Y - SAFE_BOTTOM_RESERVE
	return vp, topEdge, bottomEdge
end

-- Like targetScale, but for an OFFSET-sized modal: also clamps the scale so the modal's rendered
-- box (offset * scale) fits inside the safe area, so it never overflows a narrow phone or overlaps
-- the topbar/hotbar. Falls back to the plain design-res scale for non-offset frames.
function MobileScale.fitScale(gui, opts)
	local design = MobileScale.targetScale(gui, opts)
	if not (gui and gui:IsA("GuiObject")) then
		return design
	end

	local baseW, baseH = gui.Size.X.Offset, gui.Size.Y.Offset
	local vp, topEdge, bottomEdge = usableBand(gui)
	if baseW <= 0 or baseH <= 0 or vp.X <= 0 or vp.Y <= 0 then
		return design -- not an offset-sized frame: nothing to fit to
	end

	local availW = vp.X - 2 * SAFE_SIDE_MARGIN
	local availH = bottomEdge - topEdge
	local fit = math.min(design, availW / baseW, availH / baseH)
	return math.max(fit, FIT_FLOOR)
end

-- Lay out a modal for the current device regime and return the resting UIScale its pop should
-- target. `designSize` is the authored offset box (capture it ONCE before the first call, since
-- this rewrites gui.Size on mobile).
--
--   Desktop: the authored offset box, design-res scaled (~1 at 1080p), centered in the safe band.
--   Mobile (touch + small viewport): the box is RESIZED to fit the safe area and UIScale stays at
--     native (1) — so the shrink happens on the Size, not the UIScale, and TEXT keeps its authored
--     readable size instead of scaling down with everything. This is the documented best practice
--     (fixed-size text, container reflows). `opts.mobileScale` can bump native size if desired.
--   Desktop with `opts.nativeTextDesktop`: the same resize-to-fit strategy keeps UIScale at 1,
--     so scrollable modals do not make every label smaller merely because the Studio window is
--     below the design resolution.
function MobileScale.resolveModal(gui, designSize, opts)
	opts = opts or {}
	if not (gui and gui:IsA("GuiObject")) then
		return 1
	end

	local vp, topEdge, bottomEdge = usableBand(gui)
	if shouldUseMobile(gui) and opts.mobilePresentation == "fullscreen" and vp.X > 0 and vp.Y > 0 then
		-- The modal surface covers the physical viewport. Its controller is responsible for
		-- placing its header/content below getCoreSafeOffsets(); keeping UIScale at 1 preserves
		-- authored text and touch-target sizes.
		gui.AnchorPoint = Vector2.new(0.5, 0.5)
		gui.Position = UDim2.fromScale(0.5, 0.5)
		gui.Size = UDim2.fromScale(1, 1)
		return 1
	end

	local centerY = (topEdge + bottomEdge) / 2
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Position = UDim2.new(0.5, 0, 0, math.floor(centerY + 0.5))

	if shouldUseMobile(gui) and vp.X > 0 and vp.Y > 0 then
		-- Hybrid: split the shrink between the box and a gentle UIScale. Pick the mobile scale,
		-- then size the box so the SCALED box (box * scale) fills the safe area, capped at the
		-- design size. Most of the fit comes from the box resize; the modest scale just makes
		-- elements a touch smaller so more fits per screen, with text far more readable than a
		-- full design-res shrink.
		local s = opts.mobileScale or MOBILE_SCALE
		local availW = vp.X - 2 * SAFE_SIDE_MARGIN
		local availH = bottomEdge - topEdge
		local width = math.min(designSize.X, availW / s)
		local height = math.min(designSize.Y, availH / s)
		gui.Size = UDim2.fromOffset(math.floor(width + 0.5), math.floor(height + 0.5))
		return s
	end

	if opts.nativeTextDesktop and vp.X > 0 and vp.Y > 0 then
		local availW = vp.X - 2 * SAFE_SIDE_MARGIN
		local availH = bottomEdge - topEdge
		gui.Size = UDim2.fromOffset(
			math.floor(math.min(designSize.X, availW) + 0.5),
			math.floor(math.min(designSize.Y, availH) + 0.5)
		)
		return 1
	end

	-- Desktop: restore the authored offset box and design-res scale it to fit.
	gui.Size = UDim2.fromOffset(designSize.X, designSize.Y)
	return MobileScale.fitScale(gui, opts)
end

-- For a frame whose only UIScale is the responsive scale: reuse an existing UIScale (matching
-- the Store) or create one, and keep it in sync with the viewport.
function MobileScale.apply(gui, opts)
	if not (gui and gui:IsA("GuiObject")) then
		return nil
	end

	local scale = gui:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "MobileScale"
		scale.Parent = gui
	end

	bindViewport(gui, function()
		-- opts.mobileScale: a fixed gentle scale on touch/small viewports (like the modals use),
		-- instead of the continuous design-res shrink which can get aggressively small.
		if opts and opts.mobileScale and shouldUseMobile(gui) then
			scale.Scale = opts.mobileScale
		else
			scale.Scale = MobileScale.targetScale(gui, opts)
		end
	end)

	return scale
end

-- Like apply, but runs resolveModal (resize-to-fit + center, native text on mobile) for a modal
-- with no pop animation of its own, e.g. SellConfirm. `designSize` is captured here from the
-- authored box before the first resolve rewrites it.
function MobileScale.applyResolved(gui, opts)
	if not (gui and gui:IsA("GuiObject")) then
		return nil
	end

	local designSize = Vector2.new(gui.Size.X.Offset, gui.Size.Y.Offset)

	local scale = gui:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "MobileScale"
		scale.Parent = gui
	end

	bindViewport(gui, function()
		scale.Scale = MobileScale.resolveModal(gui, designSize, opts)
	end)

	return scale
end

-- The flat mobile-only shrink factor: the fixed MOBILE_SCALE (or opts.mobileScale) on a touch
-- phone, and exactly 1 everywhere else. Unlike targetScale/fitScale it does NOT damp-shrink on
-- smaller desktop windows -- PC/laptop are left untouched. This is the factor used by HUD/overlay
-- elements that should scale down on phones but never on PC.
function MobileScale.mobileFactor(gui, opts)
	if shouldUseMobile(gui) then
		return (opts and opts.mobileScale) or MOBILE_SCALE
	end
	return 1
end

-- Scale an element down on phones only, leaving PC untouched. Drives ONLY a UIScale by
-- mobileFactor (mobile shrink / 1 on PC) -- a single uniform zoom. A UIScale scales the object it
-- is parented to (keeping its anchor-anchored position fixed) AND every descendant in step, so it
-- is safe for a laid-out frame with mixed scale/offset children: everything scales together and the
-- layout never distorts. (Resizing the frame's Size instead double-shrinks scale-sized children vs
-- offset-sized ones -- that overlap bug is why this is UIScale-only, matching MobileScale.apply.)
-- A corner-anchored HUD shrinks toward its corner; a centre-anchored image shrinks about its
-- centre. Reuses an existing UIScale. Re-applies on viewport/orientation changes.
function MobileScale.applyMobileScale(gui, opts)
	if not (gui and gui:IsA("GuiObject")) then
		return nil
	end

	local scale = gui:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "MobileScale"
		scale.Parent = gui
	end

	bindViewport(gui, function()
		scale.Scale = MobileScale.mobileFactor(gui, opts)
	end)

	return scale
end

return MobileScale
