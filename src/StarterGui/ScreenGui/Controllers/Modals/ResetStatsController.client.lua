local ReplicatedStorage = game:GetService("ReplicatedStorage")

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

-- Reset Stats now lives in the Settings modal bottom bar (moved out of Help).
local settingsModal = screenGui:WaitForChild("SettingsModal")
local bottomBar = settingsModal:WaitForChild("BottomBar")
local resetStatsButton = bottomBar:WaitForChild("ResetStats")

local yesButton = resetStatsButton:FindFirstChild("Yes")
local noButton = resetStatsButton:FindFirstChild("No")

local confirming = false
local debounce = false

local function setConfirming(value)
	confirming = value

	if yesButton then
		yesButton.Visible = value
	end

	if noButton then
		noButton.Visible = value
	end

	if value then
		resetStatsButton.Text = ""
		resetStatsButton.BackgroundTransparency = 1
		resetStatsButton.TextTransparency = 1
	else
		resetStatsButton.Text = "RESET STATS"
		resetStatsButton.BackgroundTransparency = 0
		resetStatsButton.TextTransparency = 0
	end
end

setConfirming(false)

resetStatsButton.MouseButton1Click:Connect(function()
	if debounce or confirming then
		return
	end

	setConfirming(true)
end)

if yesButton then
	yesButton.MouseButton1Click:Connect(function()
		if debounce then
			return
		end

		debounce = true
		Net.fireServer(Net.Names.ResetStats)
		setConfirming(false)
		task.wait(0.5)
		debounce = false
	end)
end

if noButton then
	noButton.MouseButton1Click:Connect(function()
		setConfirming(false)
	end)
end
