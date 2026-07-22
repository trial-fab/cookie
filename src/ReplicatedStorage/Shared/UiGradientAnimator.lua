-- UiGradientAnimator: reusable, reduced-motion-aware continuous UIGradient animation.
-- Callers own the persistent UIGradient instance and its Enabled state; this module owns only
-- the animation lifecycle. Rotate/Horizontal use TweenService; ColorCycle shares one throttled
-- heartbeat across all active gradients to circularly phase a single palette without a seam.

local RunService = game:GetService("RunService")
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))

local UiGradientAnimator = {}

UiGradientAnimator.Mode = table.freeze({
	Rotate = "Rotate",
	Horizontal = "Horizontal",
	ColorCycle = "ColorCycle",
})

local CYCLE_INTERVAL = 1 / 30
local CYCLE_VISIBLE_ARC = 0.55
local CYCLE_COLOR_SAMPLES = 12
local cycleEntries = {}
local cycleConnection = nil
local cycleElapsed = 0

local function updateCycleConnection()
	if next(cycleEntries) == nil then
		if cycleConnection then
			cycleConnection:Disconnect()
			cycleConnection = nil
		end
		cycleElapsed = 0
		return
	end
	if cycleConnection then
		return
	end

	cycleConnection = RunService.Heartbeat:Connect(function(deltaTime)
		cycleElapsed += deltaTime
		if cycleElapsed < CYCLE_INTERVAL then
			return
		end
		local elapsed = cycleElapsed
		cycleElapsed = 0
		for entry in pairs(cycleEntries) do
			entry.step(elapsed)
		end
		if next(cycleEntries) == nil then
			updateCycleConnection()
		end
	end)
end

local function setCycleRegistered(entry, registered)
	if registered then
		cycleEntries[entry] = true
	else
		cycleEntries[entry] = nil
	end
	updateCycleConnection()
end

local function extractPalette(sequence)
	local palette = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		table.insert(palette, keypoint.Value)
	end
	if #palette > 1 and palette[#palette] == palette[1] then
		table.remove(palette)
	end
	return palette
end

local function samplePalette(palette, position)
	local count = #palette
	if count == 1 then
		return palette[1]
	end
	position %= 1
	local scaled = position * count
	local index = math.floor(scaled) + 1
	local alpha = scaled - math.floor(scaled)
	local nextIndex = index % count + 1
	return palette[index]:Lerp(palette[nextIndex], alpha)
end

local function makeCyclicSequence(palette, phase)
	if #palette < 2 then
		return ColorSequence.new(palette[1] or Color3.new(1, 1, 1))
	end

	local keypoints = {}
	for sample = 0, CYCLE_COLOR_SAMPLES do
		local position = sample / CYCLE_COLOR_SAMPLES
		local color = samplePalette(palette, position * CYCLE_VISIBLE_ARC - phase)
		table.insert(keypoints, ColorSequenceKeypoint.new(position, color))
	end
	return ColorSequence.new(keypoints)
end

local function assertMode(mode)
	assert(
		mode == UiGradientAnimator.Mode.Rotate
			or mode == UiGradientAnimator.Mode.Horizontal
			or mode == UiGradientAnimator.Mode.ColorCycle,
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
	local reverses = options.reverses == true
	local colorSequence = gradient.Color
	local palette = extractPalette(colorSequence)
	local phase = 0
	local active = false
	local destroyed = false
	local tween = nil
	local cycleEntry

	local function stopTween()
		if tween then
			tween:Cancel()
			tween = nil
		end
	end

	local function applyRestPose()
		gradient.Rotation = restRotation
		gradient.Offset = restOffset
		if mode == UiGradientAnimator.Mode.ColorCycle then
			gradient.Color = colorSequence
		end
	end

	local function refresh()
		stopTween()
		setCycleRegistered(cycleEntry, false)
		if destroyed or not active or not gradient.Parent or UiMotion.isReduced(gradient) then
			applyRestPose()
			return
		end

		if mode == UiGradientAnimator.Mode.ColorCycle then
			gradient.Rotation = restRotation
			gradient.Offset = restOffset
			phase = 0
			gradient.Color = makeCyclicSequence(palette, phase)
			setCycleRegistered(cycleEntry, true)
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
			TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, reverses),
			goal
		)
		tween:Play()
	end

	local handle = {}
	cycleEntry = {
		step = function(deltaTime)
			if destroyed or not active or not gradient.Parent then
				setCycleRegistered(cycleEntry, false)
				return
			end
			phase = (phase + deltaTime / duration) % 1
			gradient.Color = makeCyclicSequence(palette, phase)
		end,
	}

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

	function handle.setColorSequence(value)
		if typeof(value) ~= "ColorSequence" or colorSequence == value then
			return
		end
		colorSequence = value
		palette = extractPalette(value)
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
		setCycleRegistered(cycleEntry, false)
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
