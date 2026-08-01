--!nocheck
-- Quest progression tests. Loads the real QuestDefinitions, QuestSnapshot, and
-- QuestService under stubbed Roblox services so progression, reward idempotency, and
-- reconciliation can be exercised without Studio.
--
-- Run with: python3 tools/quest_logic_test.py
-- Add cases here as quests 3-5 land; this caught the regressed-step bug in quest 2.

-- SOURCES is injected by tools/quest_logic_test.py, which inlines each module because
-- the luau CLI sandboxes io. Run the driver, never this file directly.
local function readSource(name)
	return assert(SOURCES[name], "missing source: " .. name)
end

-- ---------------------------------------------------------------- stub services
local StoryConfig = {
	CHAPTER_ID = "GooArrival",
	STEPS = { Meteor = "Meteor", Healing = "Healing", Lore = "Lore", BuildTask = "BuildTask", Complete = "Complete" },
	HEALING_CLICKS = 5,
	FIRST_BUILDING_ID = "Noob Clicker",
}
local UpgradeConfig = {
	["Noob Clicker"] = { BaseCost = 15, CostMultiplier = 1.15, TemplateKind = "Building" },
}
local UpgradePricing = {
	GetCost = function(config, count)
		return math.floor(config.BaseCost * (config.CostMultiplier ^ count))
	end,
}

local firedSnapshots = {}
local handlers = {}
local Net = {
	Names = { QuestSnapshot = "QuestSnapshot", QuestAction = "QuestAction" },
	event = function() end,
	on = function(name, handler)
		handlers[name] = handler
	end,
	fireClient = function(_, _, snapshot)
		table.insert(firedSnapshots, snapshot)
	end,
}

local gemLog = {}
local gemsFail = false
local GemService = {
	AddGems = function(_, amount, source)
		if gemsFail then
			return nil
		end
		table.insert(gemLog, { Amount = amount, Source = source })
		return amount
	end,
}

local profiles = {}
local PlayerDataService = {
	Get = function(player)
		return profiles[player]
	end,
}

local analytics = { started = {}, completed = {}, rewards = {}, quests = {} }
local QuestAnalyticsService = {
	RecordStepStarted = function(_, _, questId, stepId)
		table.insert(analytics.started, questId .. "/" .. stepId)
	end,
	RecordStepCompleted = function(_, _, questId, stepId)
		table.insert(analytics.completed, questId .. "/" .. stepId)
	end,
	RecordRewardGranted = function(_, _, questId, amount)
		table.insert(analytics.rewards, questId .. "=" .. amount)
	end,
	RecordQuestCompleted = function(_, _, questId)
		table.insert(analytics.quests, questId)
	end,
}

-- ------------------------------------------------------------- module resolution
local QuestDefinitions = assert(loadstring(readSource("QuestDefinitions")))()
local QuestSnapshot = assert(loadstring(readSource("QuestSnapshot")))()

local registry = {
	QuestDefinitions = QuestDefinitions,
	Net = Net,
	StoryConfig = StoryConfig,
	UpgradeConfig = UpgradeConfig,
	UpgradePricing = UpgradePricing,
	GemService = GemService,
	PlayerDataService = PlayerDataService,
	QuestAnalyticsService = QuestAnalyticsService,
}

local function moduleNode(name)
	return setmetatable({ __moduleName = name }, {
		__index = function(_, key)
			return moduleNode(key)
		end,
	})
end

local playerRemoving = { Connect = function() end }
local PlayersStub = { PlayerRemoving = playerRemoving }
local fakeGame = {
	GetService = function(_, name)
		if name == "Players" then
			return PlayersStub
		end
		return moduleNode(name)
	end,
}

local env = setmetatable({
	game = fakeGame,
	script = moduleNode("script"),
	require = function(node)
		local name = type(node) == "table" and node.__moduleName
		local module = name and registry[name]
		assert(module, "unstubbed require: " .. tostring(name))
		return module
	end,
	print = function() end,
}, { __index = getfenv() })

local chunk = assert(loadstring(readSource("QuestService")))
setfenv(chunk, env)
local QuestService = chunk()
QuestService.Init()

-- ----------------------------------------------------------------------- helpers
local failures = 0
local function check(label, condition, detail)
	if condition then
		print(("  ok   %s"):format(label))
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and (" -- " .. tostring(detail)) or ""))
	end
end

local function newPlayer(overrides)
	local player = { Name = "Tester", Parent = PlayersStub }
	profiles[player] = {
		Persistent = {
			StoryStep = (overrides and overrides.StoryStep) or StoryConfig.STEPS.Meteor,
			IntroSeen = overrides and overrides.IntroSeen or nil,
			StoryHealingClicks = overrides and overrides.StoryHealingClicks or 0,
			MixerUnlocked = overrides and overrides.MixerUnlocked or nil,
			Gems = 0,
			QuestState = overrides and overrides.QuestState or nil,
		},
		Run = {
			Cookies = (overrides and overrides.Cookies) or 0,
			UpgradeCounts = (overrides and overrides.UpgradeCounts) or {},
		},
	}
	return player
end

local function state(player)
	return profiles[player].Persistent.QuestState
end

local function tracked(player)
	local snapshot = firedSnapshots[#firedSnapshots]
	local _, quest = QuestSnapshot.getTracked(snapshot)
	return quest
end

local function reset()
	firedSnapshots = {}
	gemLog = {}
	gemsFail = false
	analytics = { started = {}, completed = {}, rewards = {}, quests = {} }
end

-- =============================================================== definitions
print("QuestDefinitions")
check("validates", pcall(QuestDefinitions.Validate))
check("schema is v3", QuestDefinitions.SchemaVersion == 3)
check("arc lists two staged quests", #QuestDefinitions.Arcs.opening_tutorial.QuestIds == 2)
check("arc still displays five", QuestDefinitions.Arcs.opening_tutorial.DisplayQuestCount == 5)
check("mixer_training has 4 steps", #QuestDefinitions.Quests.mixer_training.Steps == 4)
check("arc gem total so far is 25", QuestDefinitions.Quests.gooey_beginning.Reward.Amount
	+ QuestDefinitions.Quests.mixer_training.Reward.Amount == 25)
local receipts = {}
local duplicate = false
for _, quest in pairs(QuestDefinitions.Quests) do
	if receipts[quest.Reward.ReceiptId] then
		duplicate = true
	end
	receipts[quest.Reward.ReceiptId] = true
end
check("reward receipts are unique", not duplicate)

-- =============================================================== fresh player
print("\nFresh player through quest 1")
reset()
local p = newPlayer()
QuestService.SetupPlayer(p)
check("starts on begin_rescue", tracked(p).StepId == "begin_rescue", tracked(p).StepId)
check("quest 2 hidden while locked", #firedSnapshots[#firedSnapshots].Arcs[1].Quests == 1)

QuestService.OnIntroCompleted(p)
check("intro credits to rubble step", tracked(p).StepId == "unearth_cookie", tracked(p).StepId)
check("ring shows 20 percent", math.abs(tracked(p).Progress - 0.2) < 1e-6, tracked(p).Progress)

profiles[p].Persistent.StoryStep = StoryConfig.STEPS.Healing
QuestService.OnStoryStepChanged(p, StoryConfig.STEPS.Healing)
check("rubble credits to healing", tracked(p).StepId == "help_goo_recover", tracked(p).StepId)

profiles[p].Persistent.StoryHealingClicks = 3
QuestService.OnManualCookieClick(p, 3)
check("sub-progress renders 3/5", tracked(p).Description:find("(3/5)", 1, true) ~= nil, tracked(p).Description)

profiles[p].Persistent.StoryHealingClicks = 5
QuestService.OnHealingCelebrationStarted(p)
check("healing credits to dialogue", tracked(p).StepId == "unlock_mixer", tracked(p).StepId)

profiles[p].Persistent.StoryStep = StoryConfig.STEPS.BuildTask
QuestService.OnStoryStepChanged(p, StoryConfig.STEPS.BuildTask)
check("dialogue credits to helper", tracked(p).StepId == "build_first_helper", tracked(p).StepId)
check("affordability copy names 15", tracked(p).Description:find("15 cookies", 1, true) ~= nil, tracked(p).Description)
check("touch affordability copy says tap", tracked(p).Description:find("Tap the cookie", 1, true) == 1,
	tracked(p).Description)
check("keyboard affordability copy says click", tracked(p).DescriptionKeyboard ~= nil and
	tracked(p).DescriptionKeyboard:find("Click the cookie", 1, true) == 1, tracked(p).DescriptionKeyboard)

profiles[p].Run.Cookies = 15
QuestService.OnCookieBalanceChanged(p)
check("affordable copy switches", tracked(p).Description == "Buy and place a Noob Clicker from the Mixer.",
	tracked(p).Description)

QuestService.BeginBuildingPurchase(p, "Noob Clicker")
profiles[p].Run.Cookies = 0
QuestService.OnCookieBalanceChanged(p)
check("copy frozen during purchase", tracked(p).Description == "Buy and place a Noob Clicker from the Mixer.",
	tracked(p).Description)

profiles[p].Run.UpgradeCounts["Noob Clicker"] = 1
QuestService.OnBuildingPlaced(p, "Noob Clicker")
check("quest 1 completed", state(p).CompletedQuestIds.gooey_beginning == true)
check("granted 15 gems once", #gemLog == 1 and gemLog[1].Amount == 15, #gemLog)
check("quest 2 now tracked", tracked(p).Id == "mixer_training", tracked(p).Id)
check("quest 2 starts at see_the_numbers", tracked(p).StepId == "see_the_numbers", tracked(p).StepId)
check("arc header counts 1 of 5", firedSnapshots[#firedSnapshots].Arcs[1].CompletedCount == 1)

-- =============================================================== quest 2
print("\nQuest 2 — Mixer Training")
QuestService.OnBuildingPlaced(p, "Noob Clicker")
check("re-placing does not double-pay", #gemLog == 1, #gemLog)

-- Sold before its step is reached: the fact must be banked, not skip earlier steps.
QuestService.OnBuildingSold(p, "Noob Clicker")
check("early sale does not skip stats step", tracked(p).StepId == "see_the_numbers", tracked(p).StepId)

-- Observations go through the real remote handler, allowlist and all.
local observe = handlers.QuestAction
check("action handler registered", type(observe) == "function")
observe(p, "Observe", "NotOnTheAllowlist")
check("unknown observation rejected", tracked(p).StepId == "see_the_numbers", tracked(p).StepId)
observe(p, "Observe", "StatsEyeEnabled")
check("stats credit advances to hire step", tracked(p).StepId == "hire_another_noob", tracked(p).StepId)
check("hire step sub-progress 1/2", tracked(p).Description:find("(1/2)", 1, true) ~= nil, tracked(p).Description)

profiles[p].Run.UpgradeCounts["Noob Clicker"] = 2
QuestService.OnBuildingPlaced(p, "Noob Clicker")
check("second noob advances to build view", tracked(p).StepId == "look_from_above", tracked(p).StepId)
check("keyboard variant carried", tracked(p).DescriptionKeyboard ~= nil and
	tracked(p).DescriptionKeyboard:find("(V)", 1, true) ~= nil, tracked(p).DescriptionKeyboard)

-- Selling now drops the count below 2 — the step must not un-complete.
profiles[p].Run.UpgradeCounts["Noob Clicker"] = 1
QuestService.OnBuildingSold(p, "Noob Clicker")
check("hire step stays complete after selling", tracked(p).StepId == "look_from_above", tracked(p).StepId)

check("stats step announced its awaited observation", (function()
	-- The snapshot has to name the fact so a client whose first report was dropped can
	-- re-assert it; without this the player is stranded with the control already on.
	local snapshot = firedSnapshots[#firedSnapshots]
	local _, quest = QuestSnapshot.getTracked(snapshot)
	return quest.StepId ~= "look_from_above" or quest.AwaitingObservation == "BuildViewOpened"
end)(), tracked(p).AwaitingObservation)

observe(p, "Observe", "BuildViewOpened")
check("build view credits to sell step", tracked(p).StepId == "undo_a_purchase", tracked(p).StepId)
check("non-observation step awaits nothing", tracked(p).AwaitingObservation == nil, tracked(p).AwaitingObservation)
-- A repeated report of an already-banked fact must be a harmless no-op.
observe(p, "Observe", "BuildViewOpened")
observe(p, "Observe", "StatsEyeEnabled")
check("repeat reports are idempotent", tracked(p).StepId == "undo_a_purchase", tracked(p).StepId)
QuestService.OnBuildingSold(p, "Noob Clicker")
check("quest 2 completes", state(p).CompletedQuestIds.mixer_training == true)
check("granted 10 gems", #gemLog == 2 and gemLog[2].Amount == 10, #gemLog)
check("arc header counts 2 of 5", firedSnapshots[#firedSnapshots].Arcs[1].CompletedCount == 2)
check("no quest tracked after last staged quest", tracked(p) == nil or tracked(p).Completed == true)

-- ================================================= stats already on beforehand
-- The reported failure: the control is already toggled on when the step arrives, so no
-- attribute ever changes and the client has nothing new to send. The step must credit
-- from the banked fact, and the snapshot must name the awaited key so a client whose
-- earlier report was dropped can re-assert it.
print("\nObservation already true before its step")
reset()
local early = newPlayer({ StoryStep = StoryConfig.STEPS.BuildTask, MixerUnlocked = true })
QuestService.SetupPlayer(early)
local earlyObserve = handlers.QuestAction
earlyObserve(early, "Observe", "StatsEyeEnabled") -- toggled on back in quest 1
profiles[early].Run.UpgradeCounts["Noob Clicker"] = 1
QuestService.OnBuildingPlaced(early, "Noob Clicker")
check("quest 2 skips the stats step it already satisfied", tracked(early).StepId == "hire_another_noob",
	tracked(early).StepId)

-- And the dropped-report case: the fact is true on the client but never reached the
-- server, so the step waits and must advertise what it is waiting for.
reset()
local dropped = newPlayer({ StoryStep = StoryConfig.STEPS.BuildTask, MixerUnlocked = true })
QuestService.SetupPlayer(dropped)
profiles[dropped].Run.UpgradeCounts["Noob Clicker"] = 1
QuestService.OnBuildingPlaced(dropped, "Noob Clicker")
check("stranded step names its awaited fact", tracked(dropped).AwaitingObservation == "StatsEyeEnabled",
	tracked(dropped).AwaitingObservation)
handlers.QuestAction(dropped, "Observe", "StatsEyeEnabled") -- the client re-asserts
check("re-asserted fact unblocks the step", tracked(dropped).StepId == "hire_another_noob",
	tracked(dropped).StepId)

-- =============================================================== idempotency
print("\nIdempotency and reconnect")
reset()
local saved = state(p)
local returning = newPlayer({
	StoryStep = StoryConfig.STEPS.Complete,
	UpgradeCounts = { ["Noob Clicker"] = 1 },
	QuestState = saved,
})
QuestService.SetupPlayer(returning)
check("reconnect pays nothing again", #gemLog == 0, #gemLog)
check("both quests still complete", state(returning).CompletedQuestIds.gooey_beginning == true
	and state(returning).CompletedQuestIds.mixer_training == true)

-- =============================================================== backfill
print("\nBackfill (existing profile, no quest state)")
reset()
local legacy = newPlayer({
	StoryStep = StoryConfig.STEPS.Complete,
	MixerUnlocked = true,
	UpgradeCounts = { ["Noob Clicker"] = 4 },
})
QuestService.SetupPlayer(legacy)
check("quest 1 backfills complete", state(legacy).CompletedQuestIds.gooey_beginning == true)
check("backfill pays no gems", #gemLog == 0, #gemLog)
check("receipts burned so it cannot pay later",
	state(legacy).QuestRewardReceipts["quest_reward_gooey_beginning_v1"] == true)
check("quest 2 not auto-completed by count alone", state(legacy).CompletedQuestIds.mixer_training ~= true)
check("quest 2 tracked at stats step", tracked(legacy).Id == "mixer_training"
	and tracked(legacy).StepId == "see_the_numbers", tracked(legacy).StepId)

-- =============================================================== failed grant
print("\nFailed gem grant retries")
reset()
local unlucky = newPlayer({ StoryStep = StoryConfig.STEPS.BuildTask, MixerUnlocked = true })
QuestService.SetupPlayer(unlucky)
gemsFail = true
profiles[unlucky].Run.UpgradeCounts["Noob Clicker"] = 1
QuestService.OnBuildingPlaced(unlucky, "Noob Clicker")
check("quest held incomplete when grant fails", state(unlucky).CompletedQuestIds.gooey_beginning ~= true)
check("no receipt burned on failure",
	state(unlucky).QuestRewardReceipts["quest_reward_gooey_beginning_v1"] ~= true)
local completedBefore = #analytics.completed
gemsFail = false
QuestService.OnBuildingPlaced(unlucky, "Noob Clicker")
check("retry completes and pays", state(unlucky).CompletedQuestIds.gooey_beginning == true and #gemLog == 1)
check("retry did not replay step analytics", #analytics.completed == completedBefore,
	("%d -> %d"):format(completedBefore, #analytics.completed))

-- =============================================================== snapshot helper
print("\nQuestSnapshot.getTracked")
local snap = {
	SelectedQuestId = "mixer_training",
	Arcs = { { Quests = { { Id = "gooey_beginning", Completed = true }, { Id = "mixer_training", Selected = true } } } },
}
local _, q = QuestSnapshot.getTracked(snap)
check("finds the selected quest, not index 1", q.Id == "mixer_training", q.Id)
local _, q2 = QuestSnapshot.getTracked({
	Arcs = { { Quests = { { Id = "a", Completed = true }, { Id = "b", Completed = false } } } },
})
check("falls back to first incomplete", q2.Id == "b", q2.Id)
check("nil snapshot is safe", select(2, QuestSnapshot.getTracked(nil)) == nil)

print(("\n%d failure(s)"):format(failures))
if failures > 0 then
	os.exit(1)
end
