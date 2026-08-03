-- Rewardless, client-local Chapter 1 quest presentation. It never sends quest or
-- story completion and restores the authoritative snapshot when replay ends.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local OpeningContent = require(ReplicatedStorage.Shared.Quest.Content.Manifest)
local QuestContentReader = require(ReplicatedStorage.Shared.Quest.QuestContentReader)
local QuestCopy = require(ReplicatedStorage.Shared.Quest.QuestCopy)
local QuestReplayConfig = require(ReplicatedStorage.Shared.QuestReplayConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

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
	local definition = assert(OpeningContent.DefinitionsById.gooey_beginning, "missing canonical replay quest")
	local currentStepId
	local currentProjection
	local currentProgress

	local function inputKind()
		if UserInputService.PreferredInput == Enum.PreferredInput.KeyboardAndMouse then
			return "Keyboard"
		elseif UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
			return "Gamepad"
		end
		return "Touch"
	end

	local function copyContext()
		return {
			InputKind = inputKind(),
			FormatNumber = NumberFormat.exact,
			ResolveUpgradeDisplayName = function(upgradeId)
				local config = UpgradeConfig[upgradeId]
				return config and config.DisplayName or upgradeId
			end,
		}
	end

	local function render(stepId, projection, progress)
		local step = assert(definition.StepById[stepId], "unknown canonical replay step")
		local description = assert(QuestContentReader.RenderStep(
			OpeningContent,
			definition.Id,
			stepId,
			projection,
			copyContext()
		))
		currentStepId = stepId
		currentProjection = projection
		currentProgress = progress
		presenter.renderReplay({
			Title = QuestCopy.Fallback(definition.Title),
			Description = description,
			StepIndex = step.Index,
			StepCount = #definition.Steps,
			Progress = progress,
			GuideEnabled = false,
		})
	end

	local function stop()
		local wasActive = active
		generation += 1
		active = false
		waitingDialogue = false
		currentStepId = nil
		currentProjection = nil
		currentProgress = nil
		presenter.renderReplay(nil)
		if wasActive and onStopped then
			onStopped()
		end
	end

	local function completeDialogue()
		if not active then
			return
		end
		render("build_first_helper", {
			Phase = "Affordable",
			Current = 1,
			Target = 1,
			Tokens = { UpgradeId = "Noob Clicker", Current = 1, Target = 1 },
		}, 0.8)
		local token = generation
		task.delay(1.25, function()
			if active and generation == token then
				currentStepId = nil
				currentProjection = nil
				presenter.renderReplay({
					Title = QuestCopy.Fallback(definition.Title),
					Description = QuestCopy.Fallback(definition.Replay.Terminal),
					StepIndex = #definition.Steps,
					StepCount = #definition.Steps,
					Progress = 1,
					GuideEnabled = false,
				})
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
		render("unlock_mixer", { Phase = "Waiting", Current = 0, Target = 1, Tokens = {} }, 0.6)
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
				render("begin_rescue", { Phase = "Waiting", Current = 0, Target = 1, Tokens = {} }, 0)
			end)
		)
	end
	if introCompletedEvent then
		table.insert(
			connections,
			introCompletedEvent.Event:Connect(function()
				if active then
					render("unearth_cookie", { Phase = "Waiting", Current = 0, Target = 1, Tokens = {} }, 0.2)
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
					render("help_goo_recover", {
						Phase = "Healing",
						Current = 0,
						Target = 5,
						Tokens = { Current = 0, Target = 5 },
					}, 0.4)
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
			render("help_goo_recover", {
				Phase = count >= 5 and "Satisfied" or "Healing",
				Current = count,
				Target = 5,
				Tokens = { Current = count, Target = 5 },
			}, 0.4)
			if count >= 5 then
				requestDialogue()
			end
		end)
	)
	table.insert(
		connections,
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(function()
			if active and currentStepId and currentProjection then
				render(currentStepId, currentProjection, currentProgress)
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
