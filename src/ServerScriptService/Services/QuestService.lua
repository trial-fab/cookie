local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestDefinitions = require(ReplicatedStorage.Shared.QuestDefinitions)
local Net = require(ReplicatedStorage.Shared.Net)
local StoryConfig = require(ReplicatedStorage.Shared.StoryConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local UpgradePricing = require(ReplicatedStorage.Shared.UpgradePricing)
local GemService = require(script.Parent.GemService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestAnalyticsService = require(script.Parent.QuestAnalyticsService)

local QuestService = {}

local QUEST_ID = "gooey_beginning"
local ARC_ID = "opening_tutorial"
local LEDGER_KEYS = {
	IntroCompleted = true,
	RubbleCleared = true,
	HealingManualClicks = true,
	HealingSequenceCompleted = true,
	LoreCompleted = true,
	NoobClickerPlaced = true,
}
local STORY_RANK = {
	[StoryConfig.STEPS.Meteor] = 1,
	[StoryConfig.STEPS.Healing] = 2,
	[StoryConfig.STEPS.Lore] = 3,
	[StoryConfig.STEPS.BuildTask] = 4,
	[StoryConfig.STEPS.Complete] = 5,
}
local ACTION_WINDOW_SECONDS = 10
local ACTION_LIMIT = 30
local QUEST_REWARD_RECEIPTS = {
	[QuestDefinitions.Quests[QUEST_ID].Reward.ReceiptId] = true,
}
local ARC_REWARD_RECEIPTS = {
	[QuestDefinitions.Arcs[ARC_ID].CapstoneReward.ReceiptId] = true,
}

local stepStartedAtByPlayer = setmetatable({}, { __mode = "k" })
local rateByPlayer = setmetatable({}, { __mode = "k" })
local buildingPurchasePendingByPlayer = setmetatable({}, { __mode = "k" })

local function copyDictionary(source)
	local result = {}
	if type(source) == "table" then
		for key, value in pairs(source) do
			result[key] = value
		end
	end
	return result
end

local function getPersistent(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil, data
end

local function newState()
	return {
		SchemaVersion = QuestDefinitions.SchemaVersion,
		Initialized = true,
		CompletedQuestIds = {},
		QuestProgress = {},
		ObjectiveLedger = {},
		QuestRewardReceipts = {},
		ArcRewardReceipts = {},
		SelectedQuestId = QUEST_ID,
		HideCompleted = false,
	}
end

local function normalizeBoolDictionary(source, allowlist)
	local normalized = {}
	if type(source) ~= "table" then
		return normalized
	end
	for key, value in pairs(source) do
		if value == true and (not allowlist or allowlist[key]) then
			normalized[key] = true
		end
	end
	return normalized
end

local function normalizeState(raw)
	local state = newState()
	if type(raw) ~= "table" then
		return state
	end

	state.Initialized = raw.Initialized == true
	state.CompletedQuestIds = normalizeBoolDictionary(raw.CompletedQuestIds, QuestDefinitions.Quests)
	state.QuestRewardReceipts = normalizeBoolDictionary(raw.QuestRewardReceipts, QUEST_REWARD_RECEIPTS)
	state.ArcRewardReceipts = normalizeBoolDictionary(raw.ArcRewardReceipts, ARC_REWARD_RECEIPTS)
	state.HideCompleted = raw.HideCompleted == true
	state.SelectedQuestId = QuestDefinitions.Quests[raw.SelectedQuestId] and raw.SelectedQuestId or QUEST_ID

	local ledger = type(raw.ObjectiveLedger) == "table" and raw.ObjectiveLedger or {}
	state.ObjectiveLedger.IntroCompleted = ledger.IntroCompleted == true or nil
	state.ObjectiveLedger.RubbleCleared = ledger.RubbleCleared == true or nil
	state.ObjectiveLedger.HealingManualClicks =
		math.clamp(math.floor(tonumber(ledger.HealingManualClicks) or 0), 0, StoryConfig.HEALING_CLICKS)
	state.ObjectiveLedger.HealingSequenceCompleted = ledger.HealingSequenceCompleted == true or nil
	state.ObjectiveLedger.LoreCompleted = ledger.LoreCompleted == true or nil
	state.ObjectiveLedger.NoobClickerPlaced = ledger.NoobClickerPlaced == true or nil

	local progress = type(raw.QuestProgress) == "table" and raw.QuestProgress[QUEST_ID]
	if type(progress) == "table" then
		local stepIndex = math.floor(tonumber(progress.StepIndex) or 1)
		if (tonumber(raw.SchemaVersion) or 1) < 2 then
			stepIndex += 1
		end
		state.QuestProgress[QUEST_ID] = {
			StepIndex = math.clamp(stepIndex, 1, #QuestDefinitions.Quests[QUEST_ID].Steps),
		}
	end
	return state
end

local function currentStepIndex(state)
	if state.CompletedQuestIds[QUEST_ID] then
		return #QuestDefinitions.Quests[QUEST_ID].Steps + 1
	end
	local ledger = state.ObjectiveLedger
	if ledger.IntroCompleted ~= true then
		return 1
	end
	if ledger.RubbleCleared ~= true then
		return 2
	end
	if
		(tonumber(ledger.HealingManualClicks) or 0) < StoryConfig.HEALING_CLICKS
		or ledger.HealingSequenceCompleted ~= true
	then
		return 3
	end
	if ledger.LoreCompleted ~= true then
		return 4
	end
	if ledger.NoobClickerPlaced ~= true then
		return 5
	end
	return #QuestDefinitions.Quests[QUEST_ID].Steps + 1
end

local function readNoobCount(data)
	local run = type(data) == "table" and data.Run
	local counts = type(run) == "table" and run.UpgradeCounts
	return math.max(0, math.floor(tonumber(type(counts) == "table" and counts[StoryConfig.FIRST_BUILDING_ID]) or 0))
end

local function reconcileCanonicalFacts(state, persistent, data)
	local ledger = state.ObjectiveLedger
	local rank = STORY_RANK[persistent.StoryStep] or 1
	if persistent.IntroSeen == true or rank >= STORY_RANK[StoryConfig.STEPS.Healing] then
		ledger.IntroCompleted = true
	end
	if rank >= STORY_RANK[StoryConfig.STEPS.Healing] then
		ledger.RubbleCleared = true
	end
	if rank >= STORY_RANK[StoryConfig.STEPS.Lore] then
		ledger.HealingManualClicks = StoryConfig.HEALING_CLICKS
		ledger.HealingSequenceCompleted = true
	else
		-- Story owns whether a click was accepted during the rubble/healing transition.
		-- Project that exact count so old quest-only increments cannot remain ahead.
		ledger.HealingManualClicks =
			math.clamp(math.floor(tonumber(persistent.StoryHealingClicks) or 0), 0, StoryConfig.HEALING_CLICKS)
		if ledger.HealingManualClicks < StoryConfig.HEALING_CLICKS then
			ledger.HealingSequenceCompleted = nil
		end
	end
	if rank >= STORY_RANK[StoryConfig.STEPS.BuildTask] or persistent.MixerUnlocked == true then
		ledger.LoreCompleted = true
	end
	if rank >= STORY_RANK[StoryConfig.STEPS.Complete] or readNoobCount(data) > 0 then
		ledger.NoobClickerPlaced = true
	end
end

local function getObjective(state, data, stepIndex)
	local ledger = state.ObjectiveLedger
	if stepIndex == 1 then
		return "Watch the Goo's meteor crash-land.", nil, nil
	elseif stepIndex == 2 then
		return "Clear the meteor rubble.", nil, nil
	elseif stepIndex == 3 then
		local count = math.clamp(tonumber(ledger.HealingManualClicks) or 0, 0, StoryConfig.HEALING_CLICKS)
		return ("Click the cookie 5 times to heal Goob. (%d/%d)"):format(count, StoryConfig.HEALING_CLICKS),
			count,
			StoryConfig.HEALING_CLICKS
	elseif stepIndex == 4 then
		return "Finish talking with the goo.", nil, nil
	end

	-- The completed card remains visible while the Gem reward flies. Keep showing the
	-- objective the player just completed instead of recomputing affordability from the
	-- post-purchase balance and the next Noob Clicker price.
	if ledger.NoobClickerPlaced == true then
		return "Place a Noob Clicker from the Mixer.", nil, nil
	end

	local noobConfig = UpgradeConfig[StoryConfig.FIRST_BUILDING_ID]
	local noobCount = readNoobCount(data)
	local cost = UpgradePricing.GetCost(noobConfig, noobCount) or tonumber(noobConfig and noobConfig.BaseCost) or 0
	local run = type(data) == "table" and data.Run
	local cookies = math.max(0, math.floor(tonumber(type(run) == "table" and run.Cookies) or 0))
	if cookies < cost then
		return ("Save %d cookies for a Noob Clicker. (%d/%d)"):format(cost, math.min(cookies, cost), cost),
			math.min(cookies, cost),
			cost
	end
	return "Place a Noob Clicker from the Mixer.", cost, cost
end

local function buildSnapshot(player, state, data)
	local quest = QuestDefinitions.Quests[QUEST_ID]
	local arc = QuestDefinitions.Arcs[ARC_ID]
	local completed = state.CompletedQuestIds[QUEST_ID] == true
	local stepIndex = currentStepIndex(state)
	local displayStepIndex = math.min(stepIndex, #quest.Steps)
	local description, current, target = getObjective(state, data, displayStepIndex)
	local selected = not completed and state.SelectedQuestId == QUEST_ID and QUEST_ID or nil

	return {
		SchemaVersion = QuestDefinitions.SchemaVersion,
		SelectedQuestId = selected,
		HideCompleted = state.HideCompleted,
		Arcs = {
			{
				Id = arc.Id,
				Title = arc.Title,
				CompletedCount = completed and 1 or 0,
				QuestCount = arc.DisplayQuestCount,
				ArcReward = {
					DisplayName = arc.CapstoneReward.DisplayName,
					Resolved = arc.CapstoneReward.Resolved,
					Received = state.ArcRewardReceipts[arc.CapstoneReward.ReceiptId] == true,
				},
				Quests = {
					{
						Id = quest.Id,
						Title = quest.Title,
						Completed = completed,
						Selectable = not completed,
						Selected = selected == QUEST_ID,
						StepId = quest.Steps[displayStepIndex].Id,
						StepIndex = displayStepIndex,
						StepCount = #quest.Steps,
						Progress = completed and 1 or (displayStepIndex - 1) / #quest.Steps,
						Description = description,
						SubProgress = current,
						SubProgressTarget = target,
						GuideEnabled = not completed and quest.Steps[displayStepIndex].GuideCapability == true,
						Reward = {
							Kind = quest.Reward.Kind,
							Amount = quest.Reward.Amount,
							Granted = state.QuestRewardReceipts[quest.Reward.ReceiptId] == true,
						},
					},
				},
			},
		},
	}
end

local function pushSnapshot(player, state, data)
	if player.Parent == Players then
		Net.fireClient(Net.Names.QuestSnapshot, player, buildSnapshot(player, state, data))
	end
end

local function markStepStart(player, stepIndex, resumed)
	local quest = QuestDefinitions.Quests[QUEST_ID]
	local step = quest.Steps[stepIndex]
	if not step then
		stepStartedAtByPlayer[player] = nil
		return
	end
	stepStartedAtByPlayer[player] = {
		StepId = step.Id,
		StartedAt = os.clock(),
	}
	QuestAnalyticsService.RecordStepStarted(player, ARC_ID, QUEST_ID, step.Id, resumed)
end

local function grantCompletionReward(player, state, data)
	local quest = QuestDefinitions.Quests[QUEST_ID]
	local receiptId = quest.Reward.ReceiptId
	if state.QuestRewardReceipts[receiptId] then
		return false
	end

	-- Completion, receipt, and balance mutation are deliberately yield-free and occur against
	-- the same active profile turn. Presentation is a best-effort consequence of GemService.
	state.CompletedQuestIds[QUEST_ID] = true
	state.QuestRewardReceipts[receiptId] = true
	state.SelectedQuestId = nil
	state.QuestProgress[QUEST_ID] = nil
	local total = GemService.AddGems(player, quest.Reward.Amount, "quest:" .. QUEST_ID, {
		Kind = "Ui",
		Key = "QuestReward",
	})
	if total == nil then
		state.CompletedQuestIds[QUEST_ID] = nil
		state.QuestRewardReceipts[receiptId] = nil
		state.SelectedQuestId = QUEST_ID
		return false
	end
	QuestAnalyticsService.RecordRewardGranted(player, ARC_ID, QUEST_ID, quest.Reward.Amount)
	QuestAnalyticsService.RecordQuestCompleted(player, ARC_ID, QUEST_ID)
	return true
end

local function reconcileAndPublish(player, allowReward)
	local persistent, data = getPersistent(player)
	if not persistent then
		return false
	end
	local state = normalizeState(persistent.QuestState)
	local stateWasInitialized = state.Initialized
	persistent.QuestState = state
	reconcileCanonicalFacts(state, persistent, data)

	local previousStep = state.QuestProgress[QUEST_ID] and state.QuestProgress[QUEST_ID].StepIndex or 1
	local nextStep = currentStepIndex(state)
	if nextStep > #QuestDefinitions.Quests[QUEST_ID].Steps and not state.CompletedQuestIds[QUEST_ID] then
		local quest = QuestDefinitions.Quests[QUEST_ID]
		local previousTimer = stepStartedAtByPlayer[player]
		if previousTimer and previousTimer.StepId == quest.Steps[#quest.Steps].Id then
			QuestAnalyticsService.RecordStepCompleted(
				player,
				ARC_ID,
				QUEST_ID,
				quest.Steps[#quest.Steps].Id,
				os.clock() - previousTimer.StartedAt
			)
		end
		if allowReward then
			grantCompletionReward(player, state, data)
		else
			-- Stage 1 never silently pays historical Chapter completion. Authorized Studio
			-- testers use the whole-onboarding reset before validating the 15-gem faucet.
			state.CompletedQuestIds[QUEST_ID] = true
			state.QuestRewardReceipts[quest.Reward.ReceiptId] = true
			state.SelectedQuestId = nil
			state.QuestProgress[QUEST_ID] = nil
		end
		stepStartedAtByPlayer[player] = nil
	else
		state.QuestProgress[QUEST_ID] = { StepIndex = nextStep }
		if nextStep > previousStep then
			local quest = QuestDefinitions.Quests[QUEST_ID]
			for completedIndex = previousStep, nextStep - 1 do
				local completedStep = quest.Steps[completedIndex]
				if completedStep then
					local timer = stepStartedAtByPlayer[player]
					local elapsed = timer and timer.StepId == completedStep.Id and os.clock() - timer.StartedAt or 0
					QuestAnalyticsService.RecordStepCompleted(player, ARC_ID, QUEST_ID, completedStep.Id, elapsed)
				end
			end
			markStepStart(player, nextStep, false)
		elseif not stepStartedAtByPlayer[player] then
			markStepStart(player, nextStep, stateWasInitialized)
		end
	end
	pushSnapshot(player, state, data)
	return true
end

local function mutateLedger(player, callback)
	local persistent = getPersistent(player)
	if not persistent or type(persistent.QuestState) ~= "table" then
		return false
	end
	local state = persistent.QuestState
	local ledger = type(state.ObjectiveLedger) == "table" and state.ObjectiveLedger
	if not ledger then
		return false
	end
	callback(ledger)
	return reconcileAndPublish(player, true)
end

function QuestService.SetupPlayer(player)
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end
	local hadInitializedState = type(persistent.QuestState) == "table" and persistent.QuestState.Initialized == true
	local allowReward = hadInitializedState or persistent.StoryStep == StoryConfig.STEPS.Meteor
	local ok = reconcileAndPublish(player, allowReward)
	if ok and type(persistent.QuestState) == "table" then
		persistent.QuestState.Initialized = true
	end
	return ok
end

function QuestService.OnStoryStepChanged(player, storyStep)
	return mutateLedger(player, function(ledger)
		local rank = STORY_RANK[storyStep] or 1
		if rank >= STORY_RANK[StoryConfig.STEPS.Healing] then
			ledger.IntroCompleted = true
			ledger.RubbleCleared = true
		end
		if rank >= STORY_RANK[StoryConfig.STEPS.Lore] then
			ledger.HealingManualClicks = StoryConfig.HEALING_CLICKS
			ledger.HealingSequenceCompleted = true
		end
		if rank >= STORY_RANK[StoryConfig.STEPS.BuildTask] then
			ledger.LoreCompleted = true
		end
		if rank >= STORY_RANK[StoryConfig.STEPS.Complete] then
			buildingPurchasePendingByPlayer[player] = nil
			ledger.NoobClickerPlaced = true
		end
	end)
end

function QuestService.OnIntroCompleted(player)
	return mutateLedger(player, function(ledger)
		ledger.IntroCompleted = true
	end)
end

function QuestService.OnHealingCelebrationStarted(player)
	return mutateLedger(player, function(ledger)
		-- StoryService calls this only after accepting the authoritative fifth healing click.
		-- Commit both facts together so its spawned celebration cannot race CookieService's
		-- ordinary quest-ledger projection of that same click.
		ledger.HealingManualClicks = StoryConfig.HEALING_CLICKS
		ledger.HealingSequenceCompleted = true
	end)
end

function QuestService.OnManualCookieClick(player, acceptedHealingClicks)
	acceptedHealingClicks = tonumber(acceptedHealingClicks)
	if not acceptedHealingClicks then
		return false
	end
	return mutateLedger(player, function(ledger)
		ledger.HealingManualClicks = math.clamp(math.floor(acceptedHealingClicks), 0, StoryConfig.HEALING_CLICKS)
	end)
end

function QuestService.OnBuildingPlaced(player, upgradeId)
	if upgradeId ~= StoryConfig.FIRST_BUILDING_ID then
		return false
	end
	buildingPurchasePendingByPlayer[player] = nil
	return mutateLedger(player, function(ledger)
		ledger.NoobClickerPlaced = true
	end)
end

function QuestService.OnCookieBalanceChanged(player)
	if buildingPurchasePendingByPlayer[player] then
		return
	end
	local persistent, data = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" or currentStepIndex(state) ~= 5 then
		return
	end
	pushSnapshot(player, state, data)
end

function QuestService.BeginBuildingPurchase(player, upgradeId)
	if upgradeId ~= StoryConfig.FIRST_BUILDING_ID then
		return false
	end
	local persistent = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" or currentStepIndex(state) ~= 5 then
		return false
	end
	buildingPurchasePendingByPlayer[player] = true
	return true
end

function QuestService.CancelBuildingPurchase(player, upgradeId)
	if upgradeId ~= StoryConfig.FIRST_BUILDING_ID or not buildingPurchasePendingByPlayer[player] then
		return false
	end
	buildingPurchasePendingByPlayer[player] = nil
	return reconcileAndPublish(player, true)
end

function QuestService.ResetForDevelopment(player)
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end
	persistent.QuestState = newState()
	stepStartedAtByPlayer[player] = nil
	buildingPurchasePendingByPlayer[player] = nil
	return true
end

local function acceptAction(player)
	local now = os.clock()
	local rate = rateByPlayer[player]
	if not rate or now - rate.StartedAt >= ACTION_WINDOW_SECONDS then
		rate = { StartedAt = now, Count = 0 }
		rateByPlayer[player] = rate
	end
	if rate.Count >= ACTION_LIMIT then
		return false
	end
	rate.Count += 1
	return true
end

local function handleAction(player, action, value)
	if type(action) ~= "string" or not acceptAction(player) then
		return
	end
	local persistent, data = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" then
		return
	end

	if action == "RequestSnapshot" then
		pushSnapshot(player, state, data)
	elseif action == "SelectQuest" then
		if value == QUEST_ID and not state.CompletedQuestIds[QUEST_ID] then
			state.SelectedQuestId = QUEST_ID
			pushSnapshot(player, state, data)
		end
	elseif action == "SetHideCompleted" then
		if type(value) == "boolean" then
			state.HideCompleted = value
			pushSnapshot(player, state, data)
		end
	end
end

function QuestService.Init()
	QuestDefinitions.Validate()
	Net.event(Net.Names.QuestSnapshot)
	Net.on(Net.Names.QuestAction, handleAction)
	Players.PlayerRemoving:Connect(function(player)
		stepStartedAtByPlayer[player] = nil
		rateByPlayer[player] = nil
		buildingPurchasePendingByPlayer[player] = nil
	end)
	print("QuestService initialized")
end

return QuestService
