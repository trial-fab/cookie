-- UiGradientAnimator: reusable, reduced-motion-aware continuous UIGradient animation.
-- Callers own the persistent UIGradient instance and its Enabled state; this module owns only
-- the tween lifecycle. No GuiObjects are created and no per-frame Lua work is performed.

local UiMotion = require(script.Parent:WaitForChild("UiMotion"))

local UiGradientAnimator = {}

UiGradientAnimator.Mode = table.freeze({
	Rotate = "Rotate",
	Horizontal = "Horizontal",
})

local function assertMode(mode)
	assert(
		mode == UiGradientAnimator.Mode.Rotate or mode == UiGradientAnimator.Mode.Horizontal,
		("Unsupported UIGradient animation mode %q"):format(tostring(mode))
	)
end

function UiGradientAnimator.new(gradient, options)
	assert(gradient and gradient:IsA("UIGradient"), "UiGradientAnimator requires a UIGradient")
	options = options or {}

	local mode = options.mode or UiGradientAnimator.Mode.Rotate
	assertMode(mode)

	local duration = math.max(0.01, tonumber(options.duration) or 4)
	local restRotation = tonumber(options.restRotation) or 0
	local restOffset = options.restOffset or Vector2.zero
	local startOffset = options.startOffset or Vector2.new(-1, restOffset.Y)
	local endOffset = options.endOffset or Vector2.new(1, restOffset.Y)
	local active = false
	local destroyed = false
	local tween = nil

	local function stopTween()
		if tween then
			tween:Cancel()
			tween = nil
		end
	end

	local function applyRestPose()
		gradient.Rotation = restRotation
		gradient.Offset = restOffset
	end

	local function refresh()
		stopTween()
		if destroyed or not active or not gradient.Parent or UiMotion.isReduced(gradient) then
			applyRestPose()
			return
		end

		local goal
		if mode == UiGradientAnimator.Mode.Rotate then
			gradient.Rotation = restRotation
			gradient.Offset = restOffset
			goal = { Rotation = restRotation + 360 }
		else
			gradient.Rotation = restRotation
			gradient.Offset = startOffset
			goal = { Offset = endOffset }
		end

		tween = UiMotion.create(
			gradient,
			TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
			goal
		)
		tween:Play()
	end

	local handle = {}

	function handle.setActive(value)
		local nextActive = value == true
		if active == nextActive then
			return
		end
		active = nextActive
		refresh()
	end

	function handle.setDuration(value)
		local nextDuration = math.max(0.01, tonumber(value) or duration)
		if duration == nextDuration then
			return
		end
		duration = nextDuration
		refresh()
	end

	function handle.refresh()
		refresh()
	end

	function handle.destroy()
		if destroyed then
			return
		end
		destroyed = true
		active = false
		stopTween()
		applyRestPose()
	end

	local screenGui = gradient:FindFirstAncestorOfClass("ScreenGui")
	if screenGui then
		local Attrs = require(script.Parent:WaitForChild("Attrs"))
		local connection = screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(refresh)
		local destroy = handle.destroy
		function handle.destroy()
			if destroyed then
				return
			end
			connection:Disconnect()
			destroy()
		end
	end

	applyRestPose()
	return handle
end

return UiGradientAnimator
