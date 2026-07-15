-- Binds the Studio-authored reset icon beside the General section heading. The expected template
-- is an 18x18 transparent ImageButton named ResetSettingsButton, placed at the far-right edge of
-- the same container as Section_general, using rbxassetid://110687387051850. Appearance and
-- placement stay in Studio; this module owns only the reset action and click spin.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiMotion = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UiMotion"))

local SettingsResetButton = {}

function SettingsResetButton.new(body, resetToDefaults)
	local button = body:FindFirstChild("ResetSettingsButton", true)
	if not (button and button:IsA("ImageButton")) then
		return
	end

	local activeTween
	button.Activated:Connect(function()
		resetToDefaults()

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
		tween.Completed:Once(function()
			if activeTween == tween then
				activeTween = nil
				button.Rotation = restRotation
			end
		end)
		tween:Play()
	end)
end

return SettingsResetButton
