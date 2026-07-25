local StoryDialogue = {}

function StoryDialogue.new(screenGui)
	local frame = screenGui:WaitForChild("StoryDialogue", 10)
	local speaker = frame and frame:WaitForChild("Speaker", 10)
	local body = frame and frame:WaitForChild("Body", 10)
	local continueButton = frame and frame:WaitForChild("Continue", 10)
	local skipButton = frame and frame:WaitForChild("Skip", 10)

	if frame and frame:IsA("GuiObject") then
		frame.Visible = false
	end

	local api = {}

	function api.play(lines)
		if not frame or not frame:IsA("GuiObject") or not continueButton or not continueButton:IsA("GuiButton") then
			warn("StoryDialogue: authored frame or Continue button was unavailable")
			return false
		end

		frame.Visible = true
		if skipButton and skipButton:IsA("GuiObject") then
			skipButton.Visible = true
		end

		local skipped = false
		for _, line in ipairs(lines) do
			if speaker and speaker:IsA("TextLabel") then
				speaker.Text = line.Speaker or ""
			end
			if body and body:IsA("TextLabel") then
				body.Text = line.Text or ""
			end

			local advanced = false
			local continueConnection = continueButton.Activated:Connect(function()
				advanced = true
			end)
			local skipConnection
			if skipButton and skipButton:IsA("GuiButton") then
				skipConnection = skipButton.Activated:Connect(function()
					skipped = true
					advanced = true
				end)
			end

			while not advanced and frame.Parent do
				task.wait()
			end
			continueConnection:Disconnect()
			if skipConnection then
				skipConnection:Disconnect()
			end

			if skipped then
				break
			end
		end

		frame.Visible = false
		return true
	end

	function api.hide()
		if frame and frame:IsA("GuiObject") then
			frame.Visible = false
		end
	end

	return api
end

return StoryDialogue
