local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui or screenGui:GetAttribute("StoryControllerRunning") then
	return
end
screenGui:SetAttribute("StoryControllerRunning", true)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local Net = require(Shared:WaitForChild("Net"))
local QuestReplayConfig = require(Shared:WaitForChild("QuestReplayConfig"))
local StoryConfig = require(Shared:WaitForChild("StoryConfig"))

local dialogue = require(script.Parent:WaitForChild("StoryDialogue")).new(screenGui)
local loreRunning = false
local replayDialogueRunning = false

local function getEvent(name)
	local event = screenGui:FindFirstChild(name)
	if event and event:IsA("BindableEvent") then
		return event
	end
	event = Instance.new("BindableEvent")
	event.Name = name
	event.Parent = screenGui
	return event
end

local function refresh()
	local step = player:GetAttribute(Attrs.StoryStep)
	if step == StoryConfig.STEPS.Lore then
		if not loreRunning and not replayDialogueRunning then
			loreRunning = true
			task.spawn(function()
				local presented = dialogue.play(StoryConfig.Dialogue)
				if presented and player:GetAttribute(Attrs.StoryStep) == StoryConfig.STEPS.Lore then
					Net.fireServer(Net.Names.StoryAction, "CompleteLore")
				end
				loreRunning = false
			end)
		end
	elseif not replayDialogueRunning then
		dialogue.hide()
	end
end

getEvent(QuestReplayConfig.DialogueRequestedEvent).Event:Connect(function()
	if loreRunning or replayDialogueRunning then
		return
	end
	replayDialogueRunning = true
	task.spawn(function()
		dialogue.play(StoryConfig.Dialogue)
		replayDialogueRunning = false
		getEvent(QuestReplayConfig.DialogueCompletedEvent):Fire()
		refresh()
	end)
end)

player:GetAttributeChangedSignal(Attrs.StoryStep):Connect(refresh)
Net.on(Net.Names.StoryStateChanged, refresh)
Net.fireServer(Net.Names.StoryAction, "RequestState")
refresh()
