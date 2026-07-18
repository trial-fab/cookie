-- StatsEyeController: the buildings-tab "lock all store stats" eye toggle.
--
-- Clicking the eye locks every building card's stats panel open (via ctx.cookieStats.setLockAll)
-- on top of the per-row right-click / long-press locks. The toggle is the StatsEyeToggle
-- ImageButton authored in Studio, a stack of same-canvas (512x512) images:
--   Eyeball (white base) / Orb (white iris ring) / Middle (recolourable iris) / Lines
--   (active-state, hidden until ON). Orb + Middle are the "iris group" that tracks the mouse
--   and translate together; Middle also recolours to the active blue when locked on.
--
-- Iris tracking: the iris looks in the DIRECTION of the cursor and sits on a fixed-radius circle
-- around centre (TRAVEL_RADIUS_RATIO of the icon size). Bleed past the white is masked in Studio
-- by frames layered above Orb/Middle but below the Eyeball, so the code does NOT clamp the travel
-- -- the radius can be as large as looks good and any overflow is simply covered. There is no
-- distance-proportional math; how snappily the iris travels between looks is owned by the
-- smoothing below. GetMouseLocation() includes the topbar inset while GuiObject AbsolutePosition
-- does not, so the inset is subtracted to line the cursor up with the eye centre.
--
-- Smoothness: the mouse only updates a TARGET offset; the rendered position chases it with
-- frame-rate-independent exponential smoothing (current:Lerp(target, 1 - exp(-k*dt))). This
-- decouples the render from the raw pointer cadence, so the iris glides instead of snapping.
-- The smoothing loop runs on RenderStepped ONLY while it is still catching up, and disconnects
-- the moment it settles -- so there are no per-frame writes while idle (which is what the idle
-- throttle on some clients penalises), only while the eye is actually in motion.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local CursorTooltipTuning = require(Shared:WaitForChild("CursorTooltipTuning"))
local IconButton = require(Shared:WaitForChild("IconButton"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

-- Radius of the circle the iris looks along, as a fraction of the icon size. Bleed is masked in
-- Studio (frames above the iris, below the eyeball), so this is a pure look-distance dial: make
-- it whatever looks good. Larger = the eye looks further.
local TRAVEL_RADIUS_RATIO = 0.09

local DEADZONE_PX = 2 -- right on the eye centre: target centre (also avoids a 0/0 direction)
local ACTIVATION_RADIUS_PX = 30 -- only track a cursor within this radius of centre; beyond it, recentre
-- Iris follow smoothness. IRIS_RESPONSIVENESS is the exponential decay rate (1/sec): higher =
-- snappier / tighter to the cursor, lower = floatier / smoother. ~10-16 feels good.
local IRIS_RESPONSIVENESS = 30
local IRIS_SETTLE_EPSILON_PX = 0.05 -- close enough to the target: snap and stop stepping
local LOCK_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ACTIVE_COLOR = Color3.fromRGB(0, 170, 255)
local IDLE_COLOR = Color3.new(1, 1, 1)
local HITBOX_MARGIN_PX = 8

local StatsEyeController = {}

local function createHitbox(toggle)
	local visualButton = toggle:FindFirstChild("StatsEyeButton", true)
	if not (visualButton and visualButton:IsA("ImageButton")) then
		visualButton = toggle:IsA("ImageButton") and toggle or toggle:FindFirstChildWhichIsA("ImageButton", true)
	end
	if not visualButton then
		return toggle:IsA("GuiButton") and toggle or nil
	end

	-- Match the menu-bar controls: when Studio provides a larger frame around the inset image,
	-- cover that whole frame (including its authored UIPadding) with one transparent input proxy.
	if visualButton ~= toggle then
		return IconButton.createHitbox(toggle, visualButton)
	end

	-- Older Studio layouts use StatsEyeToggle itself as the ImageButton, so there is no outer
	-- frame for IconButton.createHitbox to cover. Give that layout the same proxy pattern with a
	-- small amount of hit slop on every side instead of leaving the eye-sized target unchanged.
	local hitbox = toggle:FindFirstChild("Hitbox")
	if not (hitbox and hitbox:IsA("TextButton")) then
		if hitbox then
			hitbox:Destroy()
		end
		hitbox = Instance.new("TextButton")
		hitbox.Name = "Hitbox"
		hitbox.Parent = toggle
	end

	hitbox.BackgroundTransparency = 1
	hitbox.BorderSizePixel = 0
	hitbox.Text = ""
	hitbox.TextTransparency = 1
	hitbox.AutoButtonColor = false
	hitbox.Selectable = false
	hitbox:SetAttribute(Attrs.IconOnly, true)
	hitbox.AnchorPoint = Vector2.new(0.5, 0.5)
	hitbox.Position = UDim2.fromScale(0.5, 0.5)
	hitbox.Size = UDim2.new(1, HITBOX_MARGIN_PX * 2, 1, HITBOX_MARGIN_PX * 2)
	hitbox.ZIndex = toggle.ZIndex + 10
	return hitbox
end

function StatsEyeController.new(ctx)
	local screenGui = ctx.screenGui

	local toggle = screenGui:FindFirstChild("StatsEyeToggle", true)
	if not toggle or not toggle:IsA("GuiObject") then
		warn("[StatsEyeController] StatsEyeToggle not found; eye toggle disabled")
		return {}
	end

	local orb = toggle:FindFirstChild("Orb", true)
	local middle = toggle:FindFirstChild("Middle", true)
	local lines = toggle:FindFirstChild("Lines", true)
	if
		not (orb and orb:IsA("GuiObject"))
		or not (middle and middle:IsA("ImageLabel"))
		or not (lines and lines:IsA("ImageLabel"))
	then
		warn("[StatsEyeController] Orb/Middle/Lines layers missing; eye toggle disabled")
		return {}
	end
	local hitbox = createHitbox(toggle)
	if not hitbox then
		warn("[StatsEyeController] StatsEyeButton not found; eye toggle input disabled")
	end

	-- Orb + Middle move as one. All layers share the icon centre, so an iris offset in px maps
	-- straight onto each layer's Position offset.
	local irisLayers = { orb, middle }
	local targetOffset = Vector2.zero -- where the iris wants to be (updated on mouse move)
	local currentOffset = Vector2.zero -- where it is drawn (chases the target each frame)
	local smoothConn = nil

	local function isOnScreen()
		local current = toggle
		while current and current ~= screenGui do
			if current:IsA("GuiObject") and not current.Visible then
				return false
			end
			current = current.Parent
		end
		return current == screenGui and toggle.AbsoluteSize.X > 0
	end

	local function applyIris()
		local position = UDim2.new(0.5, currentOffset.X, 0.5, currentOffset.Y)
		for _, layer in irisLayers do
			layer.Position = position
		end
	end

	local function stopSmoothing()
		if smoothConn then
			smoothConn:Disconnect()
			smoothConn = nil
		end
	end

	-- Chase the target with frame-rate-independent exponential smoothing, and disconnect once
	-- settled so nothing is written while the eye is at rest.
	local function startSmoothing()
		if smoothConn then
			return
		end
		smoothConn = RunService.RenderStepped:Connect(function(dt)
			local alpha = 1 - math.exp(-IRIS_RESPONSIVENESS * dt)
			currentOffset = currentOffset:Lerp(targetOffset, alpha)
			if (targetOffset - currentOffset).Magnitude <= IRIS_SETTLE_EPSILON_PX then
				currentOffset = targetOffset
				applyIris()
				stopSmoothing()
				return
			end
			applyIris()
		end)
	end

	local function setTarget(offset)
		if offset ~= targetOffset then
			targetOffset = offset
		end
		startSmoothing()
	end

	local function updateIris()
		if not isOnScreen() then
			return
		end

		local iconSize = toggle.AbsoluteSize
		local center = toggle.AbsolutePosition + iconSize / 2
		-- GetMouseLocation() is full-screen (includes the topbar inset) while GuiObject
		-- AbsolutePosition is not, so subtract the inset to put the cursor in the same space as
		-- the eye centre. Verified in-play: without this the cursor reads ~58px low and the eye
		-- looks permanently down. (This holds even though the ScreenGui has IgnoreGuiInset = true.)
		local mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
		local delta = mouse - center
		local dist = delta.Magnitude

		-- Look toward the cursor at the fixed radius while it is within the activation ring;
		-- outside it (or right on the eye centre) target centre. Smoothing does the gliding.
		local offset = Vector2.zero
		if dist > DEADZONE_PX and dist < ACTIVATION_RADIUS_PX then
			offset = delta.Unit * (TRAVEL_RADIUS_RATIO * iconSize.X)
		end

		setTarget(offset)
	end

	-- Event-driven target updates; the smoother owns the per-frame motion.
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			updateIris()
		end
	end)

	local locked = false
	local tooltipRegistration = nil
	local function setLocked(on)
		on = on and true or false
		if locked == on then
			return
		end

		locked = on
		toggle:SetAttribute("StatsLocked", on)
		if ctx.cookieStats then
			ctx.cookieStats.setLockAll(on)
		end
		UiMotion.create(lines, LOCK_TWEEN_INFO, { ImageTransparency = on and 0 or 1 }):Play()
		UiMotion.create(middle, LOCK_TWEEN_INFO, { ImageColor3 = on and ACTIVE_COLOR or IDLE_COLOR }):Play()
		if tooltipRegistration then
			tooltipRegistration:refresh()
		end
	end

	if hitbox then
		if ctx.cursorTooltip then
			tooltipRegistration = ctx.cursorTooltip:registerGui(hitbox, {
				trigger = ctx.cursorTooltip.Trigger.Hover,
				getContent = function()
					if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
						return nil
					end
					return CursorTooltipTuning.getHint("StatsEye", locked)
				end,
			})
		end
		hitbox.Activated:Connect(function()
			setLocked(not locked)
		end)
	end

	-- Initialise: iris centred, lines hidden, middle white, lock off.
	applyIris()
	lines.ImageTransparency = 1
	middle.ImageColor3 = IDLE_COLOR
	toggle:SetAttribute("StatsLocked", false)

	return {
		setLocked = setLocked,
		isLocked = function()
			return locked
		end,
	}
end

return StatsEyeController
