-- Atomic production client bootstrap for the protocol-v2 quest runtime.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared.Attrs)
local CurrencyRewardFlightConfig = require(Shared.CurrencyRewardFlightConfig)
local GuiNames = require(Shared.GuiNames)
local Net = require(Shared.Net)
local QuestProtocol = require(Shared.Quest.QuestProtocol)
local Content = require(Shared.Quest.Content.Manifest)
local QuestReplayConfig = require(Shared.QuestReplayConfig)

local QuestProgressCompletionStrike = require(script.Parent.QuestProgressCompletionStrike)
local QuestProgressCompletionActions = require(script.Parent.QuestProgressCompletionActions)
local QuestProgressGuideKinds = require(script.Parent.QuestProgressGuideKinds)
local QuestProgressGuideTargets = require(script.Parent.QuestProgressGuideTargets)
local QuestProgressMixerUnlockVisual = require(script.Parent.QuestProgressMixerUnlockVisual)
local QuestProgressObservationBus = require(script.Parent.QuestProgressObservationBus)
local QuestProgressObservations = require(script.Parent.QuestProgressObservations)
local QuestProgressPosition = require(script.Parent.QuestProgressPosition)
local QuestProgressPresentationCoordinator = require(script.Parent.QuestProgressPresentationCoordinator)
local QuestProgressPresentationPolicies = require(script.Parent.QuestProgressPresentationPolicies)
local QuestProgressPresentationQueue = require(script.Parent.QuestProgressPresentationQueue)
local QuestProgressPresentationScheduler = require(script.Parent.QuestProgressPresentationScheduler)
local QuestProgressPresentationSignals = require(script.Parent.QuestProgressPresentationSignals)
local QuestProgressPresentationVisualAdapters = require(script.Parent.QuestProgressPresentationVisualAdapters)
local QuestProgressPresenter = require(script.Parent.QuestProgressPresenter)
local QuestProgressQuestList = require(script.Parent.QuestProgressQuestList)
local QuestProgressReducer = require(script.Parent.QuestProgressReducer)
local QuestProgressReplay = require(script.Parent.QuestProgressReplay)
local QuestProgressV2Controller = require(script.Parent.QuestProgressV2Controller)

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui or screenGui:GetAttribute("QuestProgressControllerRunning") then return end
screenGui:SetAttribute("QuestProgressControllerRunning", true)
screenGui:SetAttribute(Attrs.QuestSnapshotReady, false)

local root = screenGui:WaitForChild(GuiNames.QuestProgress, 10)
if not (root and root:IsA("GuiObject")) then
	warn("QuestProgressController disabled: ScreenGui.QuestProgress was not found")
	return
end
root.Visible = false

local player = Players.LocalPlayer
local position = QuestProgressPosition.bind(root)
local ring = QuestProgressPresenter.bind(root)
local mixerUnlockVisual = QuestProgressMixerUnlockVisual.new(screenGui, root)
local renderer
renderer = QuestProgressQuestList.bind(root, {
	Content = Content,
	OnSelectInstance = function(instanceId) Net.fireServer(Net.Names.QuestSelectV2, instanceId) end,
	OnSetHideCompleted = function(hidden) Net.fireServer(Net.Names.QuestPreferenceV2, hidden) end,
})
if not renderer then return end

local targetAdapter = QuestProgressGuideTargets.new(screenGui, root)
local guides = QuestProgressGuideKinds.new({
	Content = Content,
	Targets = targetAdapter.Targets,
	Show = targetAdapter.Show,
	Hide = targetAdapter.Hide,
	Refresh = targetAdapter.Refresh,
})
local strikeVisual = QuestProgressCompletionStrike.bind(renderer.GetDescription())
local strike = {
	Play = function(_, done)
		if not strikeVisual then done("unavailable"); return false end
		return strikeVisual.playWithCompletion(renderer.GetDescription().Text, done)
	end,
	Reset = function()
		if strikeVisual then strikeVisual.clear(renderer.GetDescription().Text) end
	end,
}

local function getEvent(name)
	local event = screenGui:FindFirstChild(name)
	if event and event:IsA("BindableEvent") then return event end
	event = Instance.new("BindableEvent")
	event.Name = name
	event.Parent = screenGui
	return event
end

local rewardRequested = getEvent(CurrencyRewardFlightConfig.QuestV2RequestEventName)
local rewardCompleted = getEvent(CurrencyRewardFlightConfig.CompletedEventName)
local rewards = {
	Present = function(context, done)
		local transition = context.Transition or {}
		if transition.RewardKind ~= "Gems" then done("completed"); return function() end end
		local amount = math.max(0, math.floor(tonumber(transition.Projection and transition.Projection.Amount) or 0))
		if amount <= 0 then done("completed"); return function() end end
		local source = "quest-v2:" .. tostring(transition.InstanceId) .. "/" .. tostring(transition.RewardSlotId)
		local connection
		connection = rewardCompleted.Event:Connect(function(currency, completedSource)
			if currency == "Gems" and completedSource == source then
				connection:Disconnect()
				done("completed")
			end
		end)
		rewardRequested:Fire(amount, source, tonumber(player:GetAttribute(Attrs.Gems)) or 0, {
			Kind = "Ui",
			Key = "QuestReward",
		})
		return function(reason)
			if connection.Connected then connection:Disconnect() end
			done(reason or "cancelled")
		end
	end,
}
local passive = { Present = function(_, done) done("completed"); return function() end end }
local storeModeRequest = getEvent(GuiNames.StoreModeRequest)
local completionActions = QuestProgressCompletionActions.new({
	Content = Content,
	Adapters = {
		SetStoreMode = function(params)
			storeModeRequest:Fire(params.Mode)
		end,
	},
	OnDiagnostic = function(problem) warn("Quest completion action: " .. tostring(problem)) end,
})

local signals = QuestProgressPresentationSignals.new()
local function reconcileSignals()
	if screenGui:GetAttribute(Attrs.MixerUnlockPresented) == true then
		signals:Complete("MixerUnlockPresented")
	end
	local storyStep = player:GetAttribute(Attrs.StoryStep)
	if storyStep ~= nil and storyStep ~= "Healing" and (tonumber(player:GetAttribute(Attrs.StoryHealingClicks)) or 0) > 0 then
		signals:Complete("HealingPresentationCompleted")
	end
end
screenGui:GetAttributeChangedSignal(Attrs.MixerUnlockPresented):Connect(reconcileSignals)
player:GetAttributeChangedSignal(Attrs.StoryStep):Connect(reconcileSignals)
reconcileSignals()

local visualAdapters = QuestProgressPresentationVisualAdapters.new({
	Renderer = renderer,
	Guides = guides,
	Strike = strike,
	Rewards = rewards,
	Passive = passive,
})
local policies = QuestProgressPresentationPolicies.new()
local queue = QuestProgressPresentationQueue.new({
	Policies = policies,
	Signals = signals,
	Scheduler = QuestProgressPresentationScheduler,
	Motion = screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true and "Reduced" or "Standard",
	Adapters = visualAdapters,
	OnDiagnostic = function(diagnostic)
		warn(("Quest presentation: %s adapter=%s problem=%s"):format(
			tostring(diagnostic.Kind),
			tostring(diagnostic.Adapter),
			tostring(diagnostic.Problem or diagnostic.Outcome)
		))
	end,
})
screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	queue:SetMotion(screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true and "Reduced" or "Standard")
end)

local observations = QuestProgressObservations.bind(screenGui, QuestProgressObservationBus.Publish)
local replayActive = false
local localMilestoneSent = {}
local reducer = QuestProgressReducer.new({
	Protocol = QuestProtocol,
	OnDiagnostic = function(diagnostic) warn("Quest protocol: " .. tostring(diagnostic.Kind)) end,
})
local coordinator
coordinator = QuestProgressPresentationCoordinator.new({
	Reducer = reducer,
	Queue = queue,
	ShouldSuppressPresentation = function() return replayActive end,
	ApplyCompletionAction = function(transition, snapshot)
		completionActions:Run({ Transition = transition, Snapshot = snapshot })
	end,
	ApplySnapshot = function(snapshot, metadata)
		if metadata.SessionChanged and type(renderer.ResetPresentation) == "function" then
			renderer.ResetPresentation()
			table.clear(localMilestoneSent)
		end
		renderer.ApplySnapshot(snapshot, metadata)
		-- Ordinary snapshot republishes can arrive while an ordered strike/reward
		-- ceremony is active. Only a protocol session replacement may cancel it;
		-- RenderCurrent owns the normal strike-to-next-instruction handoff.
		if strikeVisual and metadata.SessionChanged then
			strikeVisual.clear(renderer.GetDescription().Text)
		end
		local selected
		for _, instance in ipairs(snapshot.Instances or {}) do
			if instance.Selected then
				selected = instance
				break
			end
		end
		-- A reconnect/plain snapshot has no completion transition to replay. If
		-- the arc is terminal, restore the retained final card's completed strike
		-- directly; live completion still uses the ordered strike animation.
		if strikeVisual and metadata.TransitionCount == 0 and not selected then
			local displayed = renderer.GetDisplayedInstance()
			if displayed and displayed.Completed then
				strikeVisual.render(renderer.GetDescription().Text, true, false)
			end
		end
		local definition = selected and Content.DefinitionsById[selected.DefinitionId]
		local step = definition and definition.StepById[selected.CurrentStep.StepId]
		local objective = step and step.Objective
		observations.setAwaiting(objective and objective.Kind == "ClientUiObservation" and objective.Params.Observation or nil)
		screenGui:SetAttribute(Attrs.QuestSnapshotReady, true)
		-- Plain snapshots reconcile guidance only when no older transition owns
		-- the card. Otherwise the snapshot's successor guide would appear during
		-- the outgoing quest's strike/reward hold.
		if not replayActive and metadata.TransitionCount == 0 and selected and queue:IsIdle() then
			local context = { Snapshot = snapshot, Instance = selected, Step = selected.CurrentStep, Motion = queue.Motion }
			guides:Stop(context, function() end)
			guides:Start(context, function() end)
		end
	end,
})

local disconnectObservationSender = QuestProgressObservationBus.Bind(function(observation)
	Net.fireServer(Net.Names.QuestObservationV2, observation)
end)

local rubbleProgressEvent = getEvent(QuestReplayConfig.RubbleProgressEvent)
rubbleProgressEvent.Event:Connect(function(current, target)
	local state = reducer:GetState()
	local snapshot = state.Snapshot
	local selected
	for _, instance in ipairs(snapshot and snapshot.Instances or {}) do
		if instance.Selected then
			selected = instance
			break
		end
	end
	if not selected then return end
	local definition = Content.DefinitionsById[selected.DefinitionId]
	local step = definition and definition.StepById[selected.CurrentStep.StepId]
	if not (step and step.LocalProgress) then return end
	renderer.SetLocalProgress(step.Id, current, target)
	if tonumber(current) >= tonumber(target) then
		local key = selected.InstanceId .. "/" .. step.LocalProgress.Id
		if not localMilestoneSent[key] then
			localMilestoneSent[key] = true
			coordinator:HandleLocalPresentation({
				Kind = "LocalPresentationMilestone",
				LocalId = key,
				InstanceId = selected.InstanceId,
				DefinitionId = selected.DefinitionId,
				StepId = step.Id,
				StepIndex = selected.StepIndex,
				PresentationOnly = true,
				PresentationPolicy = step.LocalProgress.CompletionPolicy,
				Projection = { Satisfied = true, Phase = "Satisfied", Current = target, Target = target, Tokens = { Current = target, Target = target } },
			})
		end
	end
end)

QuestProgressReplay.new(screenGui, renderer, function()
	replayActive = true
	guides:Stop({}, function() end)
end, function()
	replayActive = false
	local state = reducer:GetState()
	if state.Snapshot then
		renderer.ApplySnapshot(state.Snapshot, {})
		local selected
		for _, instance in ipairs(state.Snapshot.Instances or {}) do
			if instance.Selected then
				selected = instance
				break
			end
		end
		if selected then
			guides:Start({ Snapshot = state.Snapshot, Instance = selected, Step = selected.CurrentStep, Motion = queue.Motion }, function() end)
		end
	end
end)

local controller = QuestProgressV2Controller.new({
	Protocol = QuestProtocol,
	Coordinator = coordinator,
	BindEnvelope = function(callback) return Net.on(Net.Names.QuestEnvelopeV2, callback) end,
	SendReady = function(request) Net.fireServer(Net.Names.QuestReadyV2, request) end,
})
controller:Start()

script.Destroying:Connect(function()
	controller:Stop()
	disconnectObservationSender()
	observations.destroy()
	queue:Destroy()
	guides:Stop({}, function() end)
	targetAdapter.Destroy()
	if strikeVisual then strikeVisual.destroy() end
	if ring then ring.destroy() end
	if position then position.destroy() end
	if mixerUnlockVisual then mixerUnlockVisual.destroy() end
	renderer.destroy()
end)
