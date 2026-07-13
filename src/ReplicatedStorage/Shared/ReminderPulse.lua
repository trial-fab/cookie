local ReminderPulse = {}
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))

local CIRCLE_IMAGE = "rbxassetid://107794869621542"
local DEFAULT_TWEEN_INFO = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, 0.15)

local function configureCircle(circle, color)
	circle.Image = CIRCLE_IMAGE
	circle.ImageColor3 = color
	circle.BackgroundTransparency = 1
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
end

function ReminderPulse.start(mainCircle, pulseCircle, options)
	options = options or {}
	local color = options.color or mainCircle.ImageColor3
	local baseSize = options.baseSize or pulseCircle.Size

	configureCircle(mainCircle, color)
	configureCircle(pulseCircle, color)
	mainCircle.ImageTransparency = options.mainTransparency or 0
	pulseCircle.ImageTransparency = options.startTransparency or 0.45
	pulseCircle.Size = baseSize

	local tween = UiMotion.create(pulseCircle, options.tweenInfo or DEFAULT_TWEEN_INFO, {
		ImageTransparency = options.targetTransparency or 1,
		Size = options.targetSize or UDim2.fromScale(1, 1),
	})
	tween:Play()
	return tween, baseSize
end

function ReminderPulse.setStatic(mainCircle, pulseCircle, options)
	options = options or {}
	local color = options.color or mainCircle.ImageColor3

	configureCircle(mainCircle, color)
	configureCircle(pulseCircle, color)
	mainCircle.ImageTransparency = options.mainTransparency or 0
	pulseCircle.ImageTransparency = options.pulseTransparency or 1
	pulseCircle.Size = options.pulseSize or options.targetSize or UDim2.fromScale(1, 1)
end

function ReminderPulse.stop(tween)
	if tween then
		tween:Cancel()
	end
end

return ReminderPulse
