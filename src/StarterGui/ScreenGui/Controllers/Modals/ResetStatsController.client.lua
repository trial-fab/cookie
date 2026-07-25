-- The public run-only reset is retired during the quest rollout. Keep the authored
-- control inert and hidden until the future paid/non-paid full-reset contract ships.
local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
local settingsModal = screenGui and screenGui:FindFirstChild("SettingsModal")
local bottomBar = settingsModal and settingsModal:FindFirstChild("BottomBar")
local resetStatsButton = bottomBar and bottomBar:FindFirstChild("ResetStats")

if resetStatsButton and resetStatsButton:IsA("GuiObject") then
	resetStatsButton.Visible = false
	resetStatsButton.Active = false
	resetStatsButton.Selectable = false
end
