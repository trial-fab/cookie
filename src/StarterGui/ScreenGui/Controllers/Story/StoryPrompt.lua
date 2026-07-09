local StoryPrompt = {}

function StoryPrompt.new(screenGui)
	local frame = screenGui:FindFirstChild("StoryPrompt")
	local label = frame and frame:FindFirstChild("Message", true)

	if frame and frame:IsA("GuiObject") then
		frame.Visible = false
	end

	local api = {}

	function api.show(text)
		if not frame or not frame:IsA("GuiObject") then
			return
		end
		if label and label:IsA("TextLabel") then
			label.Text = text
		end
		frame.Visible = true
	end

	function api.hide()
		if frame and frame:IsA("GuiObject") then
			frame.Visible = false
		end
	end

	return api
end

return StoryPrompt
