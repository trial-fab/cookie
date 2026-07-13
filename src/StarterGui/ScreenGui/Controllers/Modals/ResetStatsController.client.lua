local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

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
	local restoreResetFocus = GuiService.SelectedObject == yesButton or GuiService.SelectedObject == noButton
	confirming = value

	if yesButton then
		yesButton.Visible = value
		yesButton.Active = value
		yesButton.Selectable = value
	end

	if noButton then
		noButton.Visible = value
		noButton.Active = value
		noButton.Selectable = value
	end
	resetStatsButton.Selectable = not value

	if value then
		resetStatsButton.Text = ""
		resetStatsButton.BackgroundTransparency = 1
		resetStatsButton.TextTransparency = 1
	else
		resetStatsButton.Text = "RESET STATS"
		resetStatsButton.BackgroundTransparency = 0
		resetStatsButton.TextTransparency = 0
	end

	if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
		if value and yesButton then
			GuiService.SelectedObject = yesButton
		elseif restoreResetFocus then
			GuiService.SelectedObject = resetStatsButton
		end
	end
end

setConfirming(false)

resetStatsButton.Activated:Connect(function()
	if debounce or confirming then
		return
	end

	setConfirming(true)
end)

if yesButton then
	yesButton.Activated:Connect(function()
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
	noButton.Activated:Connect(function()
		setConfirming(false)
	end)
end

settingsModal:GetAttributeChangedSignal("Open"):Connect(function()
	if settingsModal:GetAttribute("Open") ~= true and confirming then
		setConfirming(false)
	end
end)
