local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReminderPulse = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ReminderPulse"))

local SettingsUpgradeReminderPulse = {}

function SettingsUpgradeReminderPulse.new(body)
	local row = body:FindFirstChild("UpgradeReminders", true)
	local mainCircle = row and row:FindFirstChild("Glyph", true)
	local pulseCircle = row and row:FindFirstChild("Glyph2", true)
	if
		not (
			mainCircle
			and pulseCircle
			and (mainCircle:IsA("ImageLabel") or mainCircle:IsA("ImageButton"))
			and (pulseCircle:IsA("ImageLabel") or pulseCircle:IsA("ImageButton"))
		)
	then
		return {
			setState = function() end,
		}
	end

	local tween = nil
	local baseSize = pulseCircle.Size
	local baseTransparency = pulseCircle.ImageTransparency
	local baseMainTransparency = mainCircle.ImageTransparency

	local function stop()
		ReminderPulse.stop(tween)
		tween = nil
		mainCircle.ImageTransparency = baseMainTransparency
		pulseCircle.Size = baseSize
		pulseCircle.ImageTransparency = baseTransparency
	end

	local function setState(enabled, animate)
		stop()
		if enabled and animate then
			tween = ReminderPulse.start(mainCircle, pulseCircle, {
				baseSize = baseSize,
				color = mainCircle.ImageColor3,
				startTransparency = baseTransparency,
			})
		else
			ReminderPulse.setStatic(mainCircle, pulseCircle, {
				color = mainCircle.ImageColor3,
				mainTransparency = if enabled then 0 else 0.5,
			})
		end
	end

	return {
		setState = setState,
	}
end

return SettingsUpgradeReminderPulse
