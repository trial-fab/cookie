-- Applies title-specific colors, strokes, and reduced-motion-aware gradients to an authored
-- TextLabel/TextButton. The label may contain TitleGradient (UIGradient) and TitleStroke
-- (UIStroke); callers still get the solid-color fallback when either authored layer is absent.
local TitleEffectConfig = require(script.Parent:WaitForChild("TitleEffectConfig"))
local UiGradientAnimator = require(script.Parent:WaitForChild("UiGradientAnimator"))

local TitleTextEffects = {}

function TitleTextEffects.bind(label)
	assert(label and (label:IsA("TextLabel") or label:IsA("TextButton")), "TitleTextEffects requires text")

	local gradient = label:FindFirstChild("TitleGradient") or label:FindFirstChildWhichIsA("UIGradient")
	local stroke = label:FindFirstChild("TitleStroke") or label:FindFirstChildWhichIsA("UIStroke")
	local animator = gradient
			and UiGradientAnimator.new(gradient, {
				mode = UiGradientAnimator.Mode.ColorCycle,
				duration = 4,
			})
		or nil
	local titleDef = nil
	local unlocked = true
	local active = false

	local function refresh()
		local effect = titleDef and TitleEffectConfig.ByTitleId[titleDef.Id] or nil
		if not unlocked then
			label.TextColor3 = TitleEffectConfig.LockedTextColor
			if gradient then
				gradient.Enabled = false
			end
			if animator then
				animator.setActive(false)
			end
			if stroke then
				stroke.Color = TitleEffectConfig.LockedStrokeColor
				stroke.Transparency = TitleEffectConfig.LockedStrokeTransparency
			end
			return
		end

		label.TextColor3 = effect and effect.TextColor or Color3.new(1, 1, 1)
		if gradient then
			gradient.Enabled = effect ~= nil and effect.Gradient ~= nil
			if effect and effect.Gradient then
				if animator then
					animator.setColorSequence(effect.Gradient)
				else
					gradient.Color = effect.Gradient
				end
			end
		end
		if animator then
			animator.setDuration(effect and effect.Duration or 4)
			animator.setActive(effect ~= nil and effect.Animated and active)
		end
		if stroke then
			stroke.Color = effect and effect.StrokeColor or Color3.fromRGB(20, 24, 35)
			stroke.Transparency = effect and effect.StrokeTransparency or 0.75
		end
	end

	local handle = {}

	function handle.apply(nextTitleDef, isUnlocked)
		titleDef = nextTitleDef
		unlocked = isUnlocked ~= false
		refresh()
	end

	function handle.setActive(value)
		active = value == true
		refresh()
	end

	function handle.destroy()
		if animator then
			animator.destroy()
		end
	end

	refresh()
	return handle
end

return TitleTextEffects
