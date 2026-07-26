-- Rewardless, client-local Chapter 1 quest presentation. It never sends quest or
-- story completion and restores the authoritative snapshot when replay ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local QuestReplayConfig = require(ReplicatedStorage.Shared.QuestReplayConfig)

local QuestProgressReplay = {}

local function getEvent(screenGui, name)
	local event = screenGui:FindFirstChild(name)
	if event and event:IsA("BindableEvent") then
		return event
	end
	event = Instance.new("BindableEvent")
	event.Name = name
	event.Parent = screenGui
	return event
end

function QuestProgressReplay.new(screenGui, presenter, onStarted, onStopped)
	local player = Players.LocalPlayer
	local generation = 0
	local active = false
	local manualClickBaseline = 0
	local waitingDialogue = false
	local connections = {}

	local function render(stepIndex, description, progress)
		presenter.renderReplay({
			Title = "A Gooey Beginning",
			Description = description,
			StepIndex = stepIndex,
			StepCount = 5,
			Progress = progress,
			GuideEnabled = false,
		})
	end

	local function stop()
		local wasActive = active
		generation += 1
		active = false
		waitingDialogue = false
		presenter.renderReplay(nil)
		if wasActive and onStopped then
			onStopped()
		end
	end

	local function completeDialogue()
		if not active then
			return
		end
		render(5, "Buy and place a Noob Clicker from the Mixer.", 0.8)
		local token = generation
		task.delay(1.25, function()
			if active and generation == token then
				render(5, "Chapter replay complete.", 1)
				task.delay(0.8, function()
					if active and generation == token then
						stop()
					end
				end)
			end
		end)
	end

	local function requestDialogue()
		if waitingDialogue then
			return
		end
		waitingDialogue = true
		render(4, "Finish talking with the goo.", 0.6)
		local event = getEvent(screenGui, QuestReplayConfig.DialogueRequestedEvent)
		if event then
			event:Fire()
		else
			completeDialogue()
		end
	end

	local startedEvent = getEvent(screenGui, QuestReplayConfig.StartedEvent)
	local introCompletedEvent = getEvent(screenGui, QuestReplayConfig.IntroCompletedEvent)
	local rubbleEvent = getEvent(screenGui, QuestReplayConfig.RubbleClearedEvent)
	local dialogueCompletedEvent = getEvent(screenGui, QuestReplayConfig.DialogueCompletedEvent)

	if startedEvent then
		table.insert(
			connections,
			startedEvent.Event:Connect(function()
				generation += 1
				active = true
				waitingDialogue = false
				manualClickBaseline = tonumber(player:GetAttribute(Attrs.ManualClicks)) or 0
				if onStarted then
					onStarted()
				end
				render(1, "Watch the Goo's meteor crash-land.", 0)
			end)
		)
	end
	if introCompletedEvent then
		table.insert(
			connections,
			introCompletedEvent.Event:Connect(function()
				if active then
					render(2, "Clear the meteor rubble.", 0.2)
				end
			end)
		)
	end
	if rubbleEvent then
		table.insert(
			connections,
			rubbleEvent.Event:Connect(function()
				if active then
					waitingDialogue = false
					manualClickBaseline = tonumber(player:GetAttribute(Attrs.ManualClicks)) or 0
					render(3, "Click the cookie 5 times to heal Goob. (0/5)", 0.4)
				end
			end)
		)
	end
	if dialogueCompletedEvent then
		table.insert(connections, dialogueCompletedEvent.Event:Connect(completeDialogue))
	end
	table.insert(
		connections,
		player:GetAttributeChangedSignal(Attrs.ManualClicks):Connect(function()
			if not active then
				return
			end
			local count = math.clamp(
				math.floor((tonumber(player:GetAttribute(Attrs.ManualClicks)) or 0) - manualClickBaseline),
				0,
				5
			)
			render(3, ("Click the cookie 5 times to heal Goob. (%d/5)"):format(count), 0.4)
			if count >= 5 then
				requestDialogue()
			end
		end)
	)
	table.insert(
		connections,
		player.CharacterAdded:Connect(function()
			if active then
				stop()
			end
		end)
	)

	return {
		stop = stop,
		destroy = function()
			stop()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
		end,
	}
end

return QuestProgressReplay
