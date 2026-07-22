-- Binds the Studio-authored reset icon beside the General section heading. The expected template
-- is an 18x18 transparent ImageButton named ResetSettingsButton, placed at the far-right edge of
-- the same container as Section_general, using rbxassetid://110687387051850. Appearance and
-- placement stay in Studio; this module owns only the reset action and click spin.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClickSpin = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClickSpin"))

local SettingsResetButton = {}

function SettingsResetButton.new(body, resetToDefaults)
	local button = body:FindFirstChild("ResetSettingsButton", true)
	if not (button and button:IsA("ImageButton")) then
		return
	end

	ClickSpin.bind(button, resetToDefaults)
end

return SettingsResetButton
