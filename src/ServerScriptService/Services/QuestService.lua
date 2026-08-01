-- QuestService — authoritative quest progression for the Getting Started arc.
--
-- Definition-driven: QuestDefinitions declares each step's ObjectiveKind/Target and this
-- service owns one resolver per kind. Adding a quest is a definitions change plus, at
-- most, one new resolver and the domain hook that feeds it.
--
-- Two rules shape the design:
--   1. Facts, not counters. Progress is derived from canonical state plus a bounded
--      ledger of demonstrated facts, so a player who did something early is credited and
--      a reconnect cannot lose progress.
--   2. Steps never un-complete. Some objectives are non-monotonic (owning two buildings
--      stops being true when one is sold), so the persisted step index is a high-water
--      mark and the derived index can only push it forward.

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

local ARC_ID = "opening_tutorial"
local FIRST_QUEST_ID = "gooey_beginning"

-- Bounded demonstrated-objective ledger. Numeric keys clamp; everything else is a flag.
local LEDGER_FLAGS = {
	IntroCompleted = true,
	RubbleCleared = true,
	HealingSequenceCompleted = true,
	LoreCompleted = true,
	NoobClickerPlaced = true,
	StatsEyeEnabled = true,
	BuildViewOpened = true,
	BuildingSold = true,
}

local STORY_RANK = {
	[StoryConfig.STEPS.Meteor] = 1,
	[StoryConfig.STEPS.Healing] = 2,
	[StoryConfig.STEPS.Lore] = 3,
	[StoryConfig.STEPS.BuildTask] = 4,
	[StoryConfig.STEPS.Complete] = 5,
}

-- Which ledger fact a story-transition objective is really asking about.
local STORY_OBJECTIVE_LEDGER_KEY = {
	IntroCompleted = "IntroCompleted",
	[StoryConfig.STEPS.Healing] = "RubbleCleared",
	[StoryConfig.STEPS.BuildTask] = "LoreCompleted",
}

local ACTION_WINDOW_SECONDS = 10
local ACTION_LIMIT = 30

local QUEST_REWARD_RECEIPTS = {}
local ARC_REWARD_RECEIPTS = {}
for _, quest in pairs(QuestDefinitions.Quests) do
	QUEST_REWARD_RECEIPTS[quest.Reward.ReceiptId] = true
end
for _, arc in pairs(QuestDefinitions.Arcs) do
	ARC_REWARD_RECEIPTS[arc.CapstoneReward.ReceiptId] = true
end

local stepStartedAtByPlayer = setmetatable({}, { __mode = "k" })
local rateByPlayer = setmetatable({}, { __mode = "k" })
local buildingPurchasePendingByPlayer = setmetatable({}, { __mode = "k" })

--------------------------------------------------------------------------------
-- Profile state
--------------------------------------------------------------------------------

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
		SelectedQuestId = FIRST_QUEST_ID,
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

	local rawVersion = tonumber(raw.SchemaVersion) or 1
	state.Initialized = raw.Initialized == true
	state.CompletedQuestIds = normalizeBoolDictionary(raw.CompletedQuestIds, QuestDefinitions.Quests)
	state.QuestRewardReceipts = normalizeBoolDictionary(raw.QuestRewardReceipts, QUEST_REWARD_RECEIPTS)
	state.ArcRewardReceipts = normalizeBoolDictionary(raw.ArcRewardReceipts, ARC_REWARD_RECEIPTS)
	state.HideCompleted = raw.HideCompleted == true
	state.SelectedQuestId = QuestDefinitions.Quests[raw.SelectedQuestId] and raw.SelectedQuestId or nil

	local ledger = type(raw.ObjectiveLedger) == "table" and raw.ObjectiveLedger or {}
	for key in pairs(LEDGER_FLAGS) do
		state.ObjectiveLedger[key] = ledger[key] == true or nil
	end
	state.ObjectiveLedger.HealingManualClicks =
		math.clamp(math.floor(tonumber(ledger.HealingManualClicks) or 0), 0, StoryConfig.HEALING_CLICKS)

	local rawProgress = type(raw.QuestProgress) == "table" and raw.QuestProgress or {}
	for questId, quest in pairs(QuestDefinitions.Quests) do
		local progress = rawProgress[questId]
		if type(progress) == "table" then
			local stepIndex = math.floor(tonumber(progress.StepIndex) or 1)
			-- v1 stored the index of the step being worked on before the auto-credited
			-- intro step existed; v2 onward stores the same 1-based index this build uses.
			if rawVersion < 2 and questId == FIRST_QUEST_ID then
				stepIndex += 1
			end
			state.QuestProgress[questId] = {
				StepIndex = math.clamp(stepIndex, 1, #quest.Steps + 1),
			}
		end
	end
	return state
end

--------------------------------------------------------------------------------
-- Canonical reconciliation
--------------------------------------------------------------------------------

local function readUpgradeCount(data, upgradeId)
	local run = type(data) == "table" and data.Run
	local counts = type(run) == "table" and run.UpgradeCounts
	return math.max(0, math.floor(tonumber(type(counts) == "table" and counts[upgradeId]) or 0))
end

-- Facts the server can prove from canonical data always win over stored ledger entries,
-- so a ledger that drifted (or a profile written by an older build) is corrected on load.
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
	if rank >= STORY_RANK[StoryConfig.STEPS.Complete] or readUpgradeCount(data, StoryConfig.FIRST_BUILDING_ID) > 0 then
		ledger.NoobClickerPlaced = true
	end
end

--------------------------------------------------------------------------------
-- Objective resolvers
--------------------------------------------------------------------------------

-- Each resolver returns: satisfied, current, target.
-- current/target are optional and drive the generic "(x/y)" sub-progress.
local resolvers = {}

resolvers.StoryTransition = function(step, ctx)
	local key = STORY_OBJECTIVE_LEDGER_KEY[step.ObjectiveTarget]
	return key ~= nil and ctx.ledger[key] == true
end

resolvers.ManualOwnerClickCount = function(step, ctx)
	local target = step.ObjectiveTarget
	local current = math.clamp(tonumber(ctx.ledger.HealingManualClicks) or 0, 0, target)
	-- The story owns the celebration that ends the healing beat, so the count alone is
	-- not enough: the fifth click is only done once that sequence reports completion.
	return current >= target and ctx.ledger.HealingSequenceCompleted == true, current, target
end

resolvers.BuildingPlaced = function(step, ctx)
	if step.ObjectiveTarget == StoryConfig.FIRST_BUILDING_ID then
		return ctx.ledger.NoobClickerPlaced == true
	end
	return readUpgradeCount(ctx.data, step.ObjectiveTarget) > 0
end

resolvers.BuildingCountAtLeast = function(step, ctx)
	local target = step.ObjectiveTarget
	local current = readUpgradeCount(ctx.data, target.UpgradeId)
	return current >= target.Count, math.min(current, target.Count), target.Count
end

resolvers.BuildingSold = function(_, ctx)
	return ctx.ledger.BuildingSold == true
end

resolvers.ClientUiObservation = function(step, ctx)
	return ctx.ledger[step.ObjectiveTarget] == true
end

local function evaluateStep(step, ctx)
	local resolver = resolvers[step.ObjectiveKind]
	if not resolver then
		return false
	end
	return resolver(step, ctx)
end

--------------------------------------------------------------------------------
-- Quest evaluation
--------------------------------------------------------------------------------

local function isUnlocked(quest, state)
	for _, dependencyId in ipairs(quest.RequiresQuestIds) do
		if state.CompletedQuestIds[dependencyId] ~= true then
			return false
		end
	end
	return true
end

-- The first step at or after `fromIndex` whose objective is not satisfied, or #steps + 1
-- when the rest are all satisfied. A later step satisfied early does not skip an earlier
-- incomplete one; it simply costs nothing when the player reaches it.
--
-- Starting at the stored index is what makes a step stay done. Several objectives are
-- non-monotonic on purpose -- `undo_a_purchase` sells the very Noob Clicker that
-- satisfied `hire_another_noob` -- so a derivation that always restarted at step 1 would
-- park the quest behind its own regressed step and never let it finish.
local function derivedStepIndex(quest, ctx, fromIndex)
	for index = fromIndex, #quest.Steps do
		if not evaluateStep(quest.Steps[index], ctx) then
			return index
		end
	end
	return #quest.Steps + 1
end

local function resolveStepIndex(quest, state, ctx)
	if state.CompletedQuestIds[quest.Id] then
		return #quest.Steps + 1
	end
	local stored = state.QuestProgress[quest.Id]
	local storedIndex =
		math.clamp(math.floor(tonumber(type(stored) == "table" and stored.StepIndex) or 1), 1, #quest.Steps + 1)
	return derivedStepIndex(quest, ctx, storedIndex)
end

--------------------------------------------------------------------------------
-- Copy
--------------------------------------------------------------------------------

-- The only dynamic line in the arc so far. It must never publish the post-deduction
-- balance between payment and the authoritative placement result, or the card flickers
-- back to "save 15 cookies" during a purchase that is already succeeding.
local function firstHelperCopy(ctx)
	if ctx.ledger.NoobClickerPlaced == true or ctx.purchasePending then
		return "Buy and place a Noob Clicker from the Mixer.", nil, nil
	end

	local config = UpgradeConfig[StoryConfig.FIRST_BUILDING_ID]
	local owned = readUpgradeCount(ctx.data, StoryConfig.FIRST_BUILDING_ID)
	local cost = UpgradePricing.GetCost(config, owned) or tonumber(config and config.BaseCost) or 0
	local run = type(ctx.data) == "table" and ctx.data.Run
	local cookies = math.max(0, math.floor(tonumber(type(run) == "table" and run.Cookies) or 0))
	if cookies < cost then
		local current = math.min(cookies, cost)
		local touch = ("Tap the cookie until you have %d cookies. (%d/%d)"):format(
			cost,
			current,
			cost
		)
		local keyboard = ("Click the cookie until you have %d cookies. (%d/%d)"):format(cost, current, cost)
		return touch, current, cost, keyboard
	end
	return "Buy and place a Noob Clicker from the Mixer.", cost, cost
end

local dynamicCopy = {
	FirstHelperAffordability = firstHelperCopy,
}

local function describeStep(step, ctx)
	local resolver = step.DynamicCopy and dynamicCopy[step.DynamicCopy]
	if resolver then
		return resolver(ctx)
	end

	local _, current, target = evaluateStep(step, ctx)
	local description = step.CompactObjective
	local keyboard = step.CompactObjectiveKeyboard
	if current and target and target > 1 then
		local suffix = (" (%d/%d)"):format(current, target)
		description ..= suffix
		if keyboard then
			keyboard ..= suffix
		end
	end
	return description, current, target, keyboard
end

--------------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------------

local function makeContext(player, persistent, data, state)
	return {
		ledger = state.ObjectiveLedger,
		persistent = persistent,
		data = data,
		purchasePending = buildingPurchasePendingByPlayer[player] == true,
	}
end

local function buildSnapshot(state, ctx)
	local arcs = {}
	for _, arc in ipairs(QuestDefinitions.GetArcsInOrder()) do
		local quests = {}
		local completedCount = 0
		for _, quest in ipairs(QuestDefinitions.GetArcQuests(arc.Id)) do
			local completed = state.CompletedQuestIds[quest.Id] == true
			if completed then
				completedCount += 1
			end
			if completed or isUnlocked(quest, state) then
				local stepIndex = resolveStepIndex(quest, state, ctx)
				local displayStepIndex = math.min(stepIndex, #quest.Steps)
				local step = quest.Steps[displayStepIndex]
				local description, current, target, keyboard = describeStep(step, ctx)
				table.insert(quests, {
					Id = quest.Id,
					Title = quest.Title,
					Completed = completed,
					Selectable = not completed,
					Selected = state.SelectedQuestId == quest.Id and not completed,
					StepId = step.Id,
					StepIndex = displayStepIndex,
					StepCount = #quest.Steps,
					Progress = completed and 1 or (displayStepIndex - 1) / #quest.Steps,
					Description = description,
					DescriptionKeyboard = keyboard,
					SubProgress = current,
					SubProgressTarget = target,
					GuideEnabled = not completed and step.GuideCapability == true,
					-- Lets the client re-assert a UI-only fact it may have reported before
					-- this profile's quest state existed. Naming the awaited key is safe:
					-- it is already in the shared definitions.
					AwaitingObservation = not completed
							and step.ObjectiveKind == "ClientUiObservation"
							and step.ObjectiveTarget
						or nil,
					Reward = {
						Kind = quest.Reward.Kind,
						Amount = quest.Reward.Amount,
						Granted = state.QuestRewardReceipts[quest.Reward.ReceiptId] == true,
					},
				})
			end
		end

		table.insert(arcs, {
			Id = arc.Id,
			Title = arc.Title,
			CompletedCount = completedCount,
			QuestCount = arc.DisplayQuestCount,
			ArcReward = {
				DisplayName = arc.CapstoneReward.DisplayName,
				Resolved = arc.CapstoneReward.Resolved,
				Received = state.ArcRewardReceipts[arc.CapstoneReward.ReceiptId] == true,
			},
			Quests = quests,
		})
	end

	return {
		SchemaVersion = QuestDefinitions.SchemaVersion,
		SelectedQuestId = state.SelectedQuestId,
		HideCompleted = state.HideCompleted,
		Arcs = arcs,
	}
end

local function pushSnapshot(player, state, ctx)
	if player.Parent == Players then
		Net.fireClient(Net.Names.QuestSnapshot, player, buildSnapshot(state, ctx))
	end
end

--------------------------------------------------------------------------------
-- Progression
--------------------------------------------------------------------------------

local function markStepStart(player, quest, stepIndex, resumed)
	local step = quest.Steps[stepIndex]
	if not step then
		stepStartedAtByPlayer[player] = nil
		return
	end
	stepStartedAtByPlayer[player] = {
		QuestId = quest.Id,
		StepId = step.Id,
		StartedAt = os.clock(),
	}
	QuestAnalyticsService.RecordStepStarted(player, ARC_ID, quest.Id, step.Id, resumed)
end

local function recordStepCompleted(player, quest, step)
	local timer = stepStartedAtByPlayer[player]
	local elapsed = timer and timer.QuestId == quest.Id and timer.StepId == step.Id and os.clock() - timer.StartedAt
		or 0
	QuestAnalyticsService.RecordStepCompleted(player, ARC_ID, quest.Id, step.Id, elapsed)
end

-- Completion, receipt, and balance mutation are deliberately yield-free and occur against
-- the same active profile turn. Presentation is a best-effort consequence of GemService.
local function grantCompletionReward(player, quest, state)
	local receiptId = quest.Reward.ReceiptId
	if state.QuestRewardReceipts[receiptId] then
		return true
	end

	state.QuestRewardReceipts[receiptId] = true
	local total = GemService.AddGems(player, quest.Reward.Amount, "quest:" .. quest.Id, {
		Kind = "Ui",
		Key = "QuestReward",
	})
	if total == nil then
		state.QuestRewardReceipts[receiptId] = nil
		return false
	end
	QuestAnalyticsService.RecordRewardGranted(player, ARC_ID, quest.Id, quest.Reward.Amount)
	return true
end

local function nextSelectableQuest(state)
	for _, arc in ipairs(QuestDefinitions.GetArcsInOrder()) do
		for _, quest in ipairs(QuestDefinitions.GetArcQuests(arc.Id)) do
			if state.CompletedQuestIds[quest.Id] ~= true and isUnlocked(quest, state) then
				return quest
			end
		end
	end
	return nil
end

-- One evaluation pass over every unlocked quest. Returns true when something changed, so
-- the caller can settle a cascade: completing a quest unlocks the next, which may already
-- be satisfied for a player who performed those actions before the quest existed.
local function advanceOnce(player, state, ctx, allowReward)
	local changed = false
	for _, arc in ipairs(QuestDefinitions.GetArcsInOrder()) do
		for _, quest in ipairs(QuestDefinitions.GetArcQuests(arc.Id)) do
			if state.CompletedQuestIds[quest.Id] ~= true and isUnlocked(quest, state) then
				local stored = state.QuestProgress[quest.Id]
				local previousIndex = math.floor(tonumber(type(stored) == "table" and stored.StepIndex) or 1)
				local nextIndex = resolveStepIndex(quest, state, ctx)

				if nextIndex > previousIndex then
					for index = previousIndex, math.min(nextIndex - 1, #quest.Steps) do
						recordStepCompleted(player, quest, quest.Steps[index])
					end
				end
				-- Store the advance before attempting the grant, so a failed grant retries
				-- on the next pass without replaying this step's analytics.
				state.QuestProgress[quest.Id] = { StepIndex = nextIndex }

				if nextIndex > #quest.Steps then
					local paid = true
					if allowReward then
						paid = grantCompletionReward(player, quest, state)
					else
						-- Studio/backfill path: burn the receipt so the faucet cannot pay
						-- historical completion before the economy gate passes.
						state.QuestRewardReceipts[quest.Reward.ReceiptId] = true
					end

					if paid then
						state.QuestProgress[quest.Id] = nil
						state.CompletedQuestIds[quest.Id] = true
						QuestAnalyticsService.RecordQuestCompleted(player, ARC_ID, quest.Id)
						if state.SelectedQuestId == quest.Id then
							state.SelectedQuestId = nil
						end
						stepStartedAtByPlayer[player] = nil
						changed = true
					end
				elseif nextIndex ~= previousIndex then
					changed = true
				end
			end
		end
	end
	return changed
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

	local ctx = makeContext(player, persistent, data, state)

	-- Bounded: every pass either advances a step or completes a quest, and both are
	-- monotonic, so this settles rather than spins.
	local passes = 0
	local questCount = 0
	for _ in pairs(QuestDefinitions.Quests) do
		questCount += 1
	end
	while passes < questCount + 1 and advanceOnce(player, state, ctx, allowReward) do
		passes += 1
	end

	local tracked = state.SelectedQuestId and QuestDefinitions.Quests[state.SelectedQuestId]
	if not tracked or state.CompletedQuestIds[tracked.Id] == true or not isUnlocked(tracked, state) then
		tracked = nextSelectableQuest(state)
		state.SelectedQuestId = tracked and tracked.Id or nil
	end

	if tracked then
		local trackedIndex = math.min(resolveStepIndex(tracked, state, ctx), #tracked.Steps)
		local trackedStep = tracked.Steps[trackedIndex]
		local timer = stepStartedAtByPlayer[player]
		if not timer or timer.QuestId ~= tracked.Id or timer.StepId ~= trackedStep.Id then
			markStepStart(player, tracked, trackedIndex, stateWasInitialized)
		end
	else
		stepStartedAtByPlayer[player] = nil
	end

	pushSnapshot(player, state, ctx)
	return true
end

local function mutateLedger(player, callback)
	local persistent = getPersistent(player)
	if not persistent or type(persistent.QuestState) ~= "table" then
		return false
	end
	local ledger = type(persistent.QuestState.ObjectiveLedger) == "table" and persistent.QuestState.ObjectiveLedger
	if not ledger then
		return false
	end
	callback(ledger)
	return reconcileAndPublish(player, true)
end

-- The tracked step, or nil. Used by the balance/purchase hooks so they only do work for
-- the one step whose copy actually depends on the live balance.
local function trackedStep(player, persistent, data, state)
	local tracked = state.SelectedQuestId and QuestDefinitions.Quests[state.SelectedQuestId]
	if not tracked then
		return nil
	end
	local ctx = makeContext(player, persistent, data, state)
	return tracked.Steps[math.min(resolveStepIndex(tracked, state, ctx), #tracked.Steps)], ctx
end

--------------------------------------------------------------------------------
-- Public API — domain services call in, never the reverse
--------------------------------------------------------------------------------

function QuestService.SetupPlayer(player)
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end
	local hadInitializedState = type(persistent.QuestState) == "table" and persistent.QuestState.Initialized == true
	-- A brand-new profile earns its rewards by playing. An existing profile that predates
	-- the quest system backfills without payment until the economy gate passes; see
	-- docs/quest-getting-started-arc.md §16.3.
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
	if type(upgradeId) ~= "string" then
		return false
	end
	if upgradeId == StoryConfig.FIRST_BUILDING_ID then
		buildingPurchasePendingByPlayer[player] = nil
		return mutateLedger(player, function(ledger)
			ledger.NoobClickerPlaced = true
		end)
	end

	-- Other buildings carry no ledger fact: their objectives read the canonical count and
	-- re-derive on the next reconcile anyway. Only republish when a step is actually
	-- displaying such a count, so ordinary late-game placement does not reconcile the
	-- whole arc and push a snapshot on every placed building.
	local persistent, data = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" then
		return false
	end
	local step = trackedStep(player, persistent, data, state)
	if step and step.ObjectiveKind == "BuildingCountAtLeast" then
		return reconcileAndPublish(player, true)
	end
	return false
end

function QuestService.OnBuildingSold(player, upgradeId)
	if type(upgradeId) ~= "string" then
		return false
	end
	-- Any accepted sale proves the lesson, so a player who already sold something else is
	-- never asked to prove it again on a Noob Clicker.
	return mutateLedger(player, function(ledger)
		ledger.BuildingSold = true
	end)
end

function QuestService.OnCookieBalanceChanged(player)
	if buildingPurchasePendingByPlayer[player] then
		return
	end
	local persistent, data = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" then
		return
	end
	local step, ctx = trackedStep(player, persistent, data, state)
	if not step or step.DynamicCopy ~= "FirstHelperAffordability" then
		return
	end
	pushSnapshot(player, state, ctx)
end

function QuestService.BeginBuildingPurchase(player, upgradeId)
	if upgradeId ~= StoryConfig.FIRST_BUILDING_ID then
		return false
	end
	local persistent, data = getPersistent(player)
	local state = persistent and persistent.QuestState
	if type(state) ~= "table" then
		return false
	end
	local step = trackedStep(player, persistent, data, state)
	if not step or step.DynamicCopy ~= "FirstHelperAffordability" then
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

--------------------------------------------------------------------------------
-- Client actions
--------------------------------------------------------------------------------

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
		pushSnapshot(player, state, makeContext(player, persistent, data, state))
	elseif action == "SelectQuest" then
		local quest = QuestDefinitions.Quests[value]
		if quest and state.CompletedQuestIds[quest.Id] ~= true and isUnlocked(quest, state) then
			state.SelectedQuestId = quest.Id
			reconcileAndPublish(player, true)
		end
	elseif action == "SetHideCompleted" then
		if type(value) == "boolean" then
			state.HideCompleted = value
			pushSnapshot(player, state, makeContext(player, persistent, data, state))
		end
	elseif action == "Observe" then
		-- UI-only facts with no canonical server trace. The allowlist is closed and none
		-- of them is ever treated as economic authorization.
		if QuestDefinitions.Observations[value] and state.ObjectiveLedger[value] ~= true then
			mutateLedger(player, function(ledger)
				ledger[value] = true
			end)
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
