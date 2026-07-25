-- Keeps the quest progress widget beneath Roblox's top-left icon and below the
-- default chat window while chat is open.

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local QuestProgressPosition = {}

local REST_X_PX = 16
local REST_Y_PX = 64
local CHAT_GAP_PX = 16
local CHAT_POLL_SECONDS = 0.1

local function getChatActive()
	local success, active = pcall(function()
		return StarterGui:GetCore("ChatActive")
	end)
	return success and active == true
end

local function getChatBottom()
	local window = TextChatService.ChatWindowConfiguration
	local input = TextChatService.ChatInputBarConfiguration
	local windowBottom = window.AbsolutePosition.Y + window.AbsoluteSize.Y
	local inputBottom = input.AbsolutePosition.Y + input.AbsoluteSize.Y
	return math.max(windowBottom, inputBottom)
end

function QuestProgressPosition.bind(questProgress)
	if not (questProgress and questProgress:IsA("GuiObject")) then
		return nil
	end

	local connections = {}
	local elapsed = CHAT_POLL_SECONDS
	local lastChatActive = nil

	local function refresh()
		questProgress.AnchorPoint = Vector2.new(0, 0)

		local guiOrigin = questProgress.AbsolutePosition
			- Vector2.new(questProgress.Position.X.Offset, questProgress.Position.Y.Offset)
		local chatActive = getChatActive()
		local localY = REST_Y_PX
		if chatActive then
			local chatBottom = getChatBottom()
			local chatClearedY = math.ceil(chatBottom + CHAT_GAP_PX - guiOrigin.Y)
			localY = math.max(localY, chatClearedY)
		end

		questProgress.Position = UDim2.fromOffset(REST_X_PX, localY)
		lastChatActive = chatActive
	end

	local window = TextChatService.ChatWindowConfiguration
	local input = TextChatService.ChatInputBarConfiguration
	for _, signal in ipairs({
		GuiService:GetPropertyChangedSignal("TopbarInset"),
		window:GetPropertyChangedSignal("AbsolutePosition"),
		window:GetPropertyChangedSignal("AbsoluteSize"),
		input:GetPropertyChangedSignal("AbsolutePosition"),
		input:GetPropertyChangedSignal("AbsoluteSize"),
	}) do
		table.insert(connections, signal:Connect(refresh))
	end
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(deltaTime)
			elapsed += deltaTime
			if elapsed < CHAT_POLL_SECONDS then
				return
			end
			elapsed = 0
			local chatActive = getChatActive()
			if chatActive ~= lastChatActive then
				refresh()
			end
		end)
	)

	refresh()
	task.defer(refresh)

	return {
		refresh = refresh,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return QuestProgressPosition
