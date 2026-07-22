-- Reusable click/tap confirmation spin for an authored GuiButton.
local UiMotion = require(script.Parent:WaitForChild("UiMotion"))

local ClickSpin = {}

function ClickSpin.bind(button, action, isEnabled, onComplete)
	assert(button and button:IsA("GuiButton"), "ClickSpin requires a GuiButton")
	local activeTween

	local function play()
		if isEnabled and not isEnabled() then
			return false
		end
		if action then
			action()
		end

		if activeTween then
			activeTween:Cancel()
		end
		local restRotation = button.Rotation % 360
		button.Rotation = restRotation
		local tween = UiMotion.create(
			button,
			TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Rotation = restRotation + 360 }
		)
		activeTween = tween
		tween.Completed:Once(function(playbackState)
			if activeTween == tween then
				activeTween = nil
				button.Rotation = restRotation
				if playbackState == Enum.PlaybackState.Completed and onComplete then
					onComplete()
				end
			end
		end)
		tween:Play()
		return true
	end

	local connection = button.Activated:Connect(play)
	return {
		play = play,
		destroy = function()
			connection:Disconnect()
			if activeTween then
				activeTween:Cancel()
				activeTween = nil
			end
		end,
	}
end

return ClickSpin
