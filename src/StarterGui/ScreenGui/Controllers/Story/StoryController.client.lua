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
local StoryConfig = require(Shared:WaitForChild("StoryConfig"))

local dialogue = require(script.Parent:WaitForChild("StoryDialogue")).new(screenGui)
local prompt = require(script.Parent:WaitForChild("StoryPrompt")).new(screenGui)
local loreRunning = false

local function getCookies()
	local leaderstats = player:FindFirstChild("leaderstats")
	local cookies = leaderstats and leaderstats:FindFirstChild("Cookies")
	return cookies and cookies.Value or 0
end

local function refresh()
	local step = player:GetAttribute(Attrs.StoryStep)
	if step == StoryConfig.STEPS.Healing then
		local clicks = player:GetAttribute(Attrs.StoryHealingClicks) or 0
		prompt.show(StoryConfig.Prompts[step]:format(clicks, StoryConfig.HEALING_CLICKS))
	elseif step == StoryConfig.STEPS.Lore then
		prompt.hide()
		if not loreRunning then
			loreRunning = true
			task.spawn(function()
				dialogue.play(StoryConfig.Dialogue)
				if player:GetAttribute(Attrs.StoryStep) == StoryConfig.STEPS.Lore then
					Net.fireServer(Net.Names.StoryAction, "CompleteLore")
				end
				loreRunning = false
			end)
		end
	elseif step == StoryConfig.STEPS.BuildTask then
		dialogue.hide()
		prompt.show(StoryConfig.Prompts[step]:format(StoryConfig.FIRST_BUILDING_COST))
	else
		dialogue.hide()
		prompt.hide()
	end
end

player:GetAttributeChangedSignal(Attrs.StoryStep):Connect(refresh)
player:GetAttributeChangedSignal(Attrs.StoryHealingClicks):Connect(refresh)

task.spawn(function()
	local leaderstats = player:WaitForChild("leaderstats", 30)
	local cookies = leaderstats and leaderstats:WaitForChild("Cookies", 10)
	if cookies then
		cookies.Changed:Connect(function()
			if player:GetAttribute(Attrs.StoryStep) == StoryConfig.STEPS.BuildTask then
				local remaining = math.max(0, StoryConfig.FIRST_BUILDING_COST - getCookies())
				if remaining > 0 then
					prompt.show(("Collect %d more cookies, then open the %s and place a Noob Clicker."):format(remaining, StoryConfig.TOOL_NAME))
				else
					prompt.show(("Open the %s and place a Noob Clicker."):format(StoryConfig.TOOL_NAME))
				end
			end
		end)
	end
end)

Net.on(Net.Names.StoryStateChanged, function()
	refresh()
end)

Net.fireServer(Net.Names.StoryAction, "RequestState")
refresh()
