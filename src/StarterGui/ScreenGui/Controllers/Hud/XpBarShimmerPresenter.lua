-- Drives the Studio-authored XP fill gradient from baked presentation values.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UiGradientAnimator = require(Shared:WaitForChild("UiGradientAnimator"))
local Config = require(Shared:WaitForChild("XpBarShimmerConfig"))

local XpBarShimmerPresenter = {}

function XpBarShimmerPresenter.bind(xpFill)
	if not (xpFill and xpFill:IsA("GuiObject")) then
		return nil
	end
	local gradient = xpFill:FindFirstChild("XpFillShimmer")
	if not (gradient and gradient:IsA("UIGradient")) then
		warn("XP-bar shimmer disabled: Studio-authored XpFillShimmer gradient was not found")
		return nil
	end

	gradient.Enabled = true
	local animator = UiGradientAnimator.new(gradient, {
		mode = UiGradientAnimator.Mode.Horizontal,
		duration = Config.SweepSeconds,
		restRotation = Config.AngleDegrees,
		restOffset = Vector2.new(-1, 0),
		startOffset = Vector2.new(-1, 0),
		endOffset = Vector2.new(1, 0),
	})
	local function applyColors()
		local width = Config.BandWidth
		local baseColor = Config.BaseColor
		local highlightColor = Config.HighlightColor
		if width < 1 then
			local halfWidth = width / 2
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, baseColor),
				ColorSequenceKeypoint.new(0.5 - halfWidth, baseColor),
				ColorSequenceKeypoint.new(0.5, highlightColor),
				ColorSequenceKeypoint.new(0.5 + halfWidth, baseColor),
				ColorSequenceKeypoint.new(1, baseColor),
			})
			return
		end

		local halfWidth = width / 2
		local keypoints = {}
		for sample = 0, 12 do
			local position = sample / 12
			local blend = math.clamp(1 - math.abs(position - 0.5) / halfWidth, 0, 1)
			table.insert(keypoints, ColorSequenceKeypoint.new(position, baseColor:Lerp(highlightColor, blend)))
		end
		gradient.Color = ColorSequence.new(keypoints)
	end

	applyColors()
	animator.setActive(Config.Enabled)

	return {
		destroy = function()
			animator.destroy()
		end,
	}
end

return XpBarShimmerPresenter
