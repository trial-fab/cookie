--!nocheck
-- Pure given-state/when-event/then-state Stage B tests. No Roblox globals or service stubs.

local cache = {}
local function node(path)
	return setmetatable({ Path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return node(string.match(path, "^(.*)%.[^.]+$") or "")
			end
			return node(path == "" and key or path .. "." .. key)
		end,
	})
end

local function loadModule(name)
	if cache[name] then
		return cache[name]
	end
	local chunk = assert(loadstring(assert(SOURCES[name], "missing source " .. name)))
	local env
	env = setmetatable({
		script = node(name),
		require = function(target)
			return loadModule(assert(SOURCES[target.Path] and target.Path, "unknown module " .. tostring(target.Path)))
		end,
		warn = function() end,
	}, { __index = getfenv() })
	setfenv(chunk, env)
	local result = chunk()
	cache[name] = result
	return result
end

local DomainEvents = loadModule("DomainEvents")
local Objectives = loadModule("Objectives.Registry")
local Rewards = loadModule("Rewards.Registry")
local Schema = loadModule("QuestSchema")
local Engine = loadModule("QuestEngine")
local ProductionManifest = loadModule("Content.Manifest")
local EffectRunner = loadModule("Quest.QuestEffectRunner")
local EventRouter = loadModule("Quest.QuestEventRouter")
local Persistence = loadModule("Quest.QuestPersistence")

local failures = 0
local function check(label, condition, detail)
	if condition then
		print("  ok   " .. label)
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and " -- " .. tostring(detail) or ""))
	end
end

local function rejects(label, callback, needle)
	local ok, problem = pcall(callback)
	check(label, not ok and (not needle or string.find(tostring(problem), needle, 1, true) ~= nil), problem)
end

local function fixtureManifest()
	return {
		ContentVersion = 7,
		Arcs = {
			{ Id = "opening", Order = 1, QuestIds = { "foundation", "automation" }, DisplayQuestCount = 2 },
		},
		Definitions = {
			{
				Id = "foundation",
				Version = 1,
				ArcId = "opening",
				Order = 1,
				Lifecycle = { Kind = "OneTime" },
				RequiresDefinitionIds = {},
				Presentation = { StepCompletion = "TutorialStrikeThenReveal" },
				Steps = {
					{ Id = "sell_any", Objective = { Kind = "BuildingSold", Params = { UpgradeId = "Any" } } },
					{
						Id = "own_two",
						Objective = {
							Kind = "BuildingCountAtLeast",
							Params = { UpgradeId = "Noob Clicker", Count = 2 },
						},
					},
				},
				Rewards = { { SlotId = "foundation_gems", Kind = "Gems", Params = { Amount = 5 } } },
			},
			{
				Id = "automation",
				Version = 2,
				ArcId = "opening",
				Order = 2,
				Lifecycle = { Kind = "OneTime" },
				RequiresDefinitionIds = { "foundation" },
				Steps = {
					{ Id = "save_ten", Objective = { Kind = "CookieBalanceAtLeast", Params = { Amount = 10 } } },
					{
						Id = "open_build_view",
						Objective = { Kind = "ClientUiObservation", Params = { Observation = "BuildViewOpened" } },
					},
				},
				Rewards = { { SlotId = "automation_gems", Kind = "Gems", Params = { Amount = 3 } } },
			},
		},
		RetiredRewardReceipts = {},
	}
end

local function content()
	return Schema.ValidateManifest(fixtureManifest(), Objectives, Rewards)
end

local function facts(count, balance)
	return {
		StoryFacts = {},
		HealingManualClicks = 0,
		HealingSequenceCompleted = false,
		UpgradeCounts = { ["Noob Clicker"] = count or 0 },
		UpgradeCosts = {},
		CookieBalance = balance or 0,
	}
end

local function cause(kind, payload, timestamp)
	return assert(DomainEvents.Validate(kind, payload, timestamp or 1))
end

local function findEffect(effects, kind)
	for _, effect in ipairs(effects) do
		if effect.Kind == kind then
			return effect
		end
	end
end

local function applyEffects(c, state, session, effects, when, success)
	local transitions = {}
	for _, effect in ipairs(effects) do
		local nextTransitions, followups
		state, session, nextTransitions, followups =
			Engine.applyEffectResult(c, state, session, effect, success ~= false, when)
		for _, value in ipairs(nextTransitions) do
			table.insert(transitions, value)
		end
		for _, followup in ipairs(followups) do
			state, session = Engine.applyEffectResult(c, state, session, followup, true, when)
		end
	end
	return state, session, transitions
end

print("\nSchema and closed registries")
local c = content()
check(
	"manifest validates and builds global trigger indexes",
	#c.TriggerIndex.BuildingSold == 2 and #c.TriggerIndex.CookieBalanceChanged == 1
)
check("OneTime instance identity is definition/version-derived", c.Definitions[2].InstanceId == "onetime:automation:v2")
local receipt = c.Definitions[1].Rewards[1].ReceiptId
check(
	"reward receipt includes definition, version, instance, and slot",
	receipt == "reward:v1:foundation:v1:onetime:foundation:v1:foundation_gems",
	receipt
)
check(
	"boost vocabulary is registered with reusable Quest 5 objectives",
	DomainEvents.IsKnown("BoostPurchased")
		and DomainEvents.IsKnown("BoostFieldDropped")
		and #Objectives.KindsForTrigger("BoostPurchased") == 1
		and #Objectives.KindsForTrigger("BoostFieldDropped") == 1
)
check(
	"Stage E opening content and reward execution are active together",
	#ProductionManifest.Definitions == 5
		and ProductionManifest.DefinitionsById.understanding_upgrades ~= nil
		and ProductionManifest.DefinitionsById.powering_up ~= nil
		and string.find(QUEST_SERVICE_SOURCE, "Enabled = true", 1, true) ~= nil
)
check(
	"committed payload validates",
	DomainEvents.Validate("CookieBalanceChanged", { Balance = 4, Source = "Autoclick", CommitState = "Committed" }, 1)
		~= nil
)
check(
	"pending purchase payload is valid but not routable",
	not DomainEvents.IsCommitted(
		assert(
			DomainEvents.Validate(
				"CookieBalanceChanged",
				{ Balance = 0, Source = "PendingPurchase", CommitState = "PendingPurchase" },
				1
			)
		)
	)
)
check("unknown trigger is rejected", DomainEvents.Validate("MadeUpEvent", {}, 1) == nil)
check("objective kind contract rejects unknown triggers", not Objectives.ValidateKindContract({
	Kind = "BadKind",
	ProgressMode = "Canonical",
	ActiveTriggers = { "MadeUpEvent" },
	CaptureTriggers = {},
	Phases = { "Waiting" },
}))
check("objective kind contract rejects capture-only triggers", not Objectives.ValidateKindContract({
	Kind = "BadCaptureKind",
	ProgressMode = "CapturedFact",
	ActiveTriggers = {},
	CaptureTriggers = { "BuildingSold" },
	Capture = function() return {} end,
	Phases = { "Waiting" },
}))
check("objective kind contract rejects unknown live sources", not Objectives.ValidateKindContract({
	Kind = "BadLiveKind",
	ProgressMode = "Canonical",
	ActiveTriggers = {},
	CaptureTriggers = {},
	LiveProgress = { Source = "MadeUpBalance", Phases = { "Waiting" } },
	Phases = { "Waiting" },
}))
local liveSaving = Objectives.ResolveLiveProgress(
	{ Kind = "BuildingPlaced", Params = { UpgradeId = "Noob Clicker", ShowAffordability = true } },
	{
		Satisfied = false,
		Current = 4,
		Target = 15,
		ProgressFraction = 4 / 15,
		Phase = "Saving",
		Tokens = { Current = 4, Target = 15 },
	},
	{ CookieBalance = 9 }
)
check(
	"live progress is objective-declared and presentation-only",
	liveSaving.Current == 9 and liveSaving.ProgressFraction == nil and liveSaving.Tokens.Current == 9
)
local affordableProjection = {
	Satisfied = false,
	Current = 15,
	Target = 15,
	ProgressFraction = 1,
	Phase = "Affordable",
	Tokens = { Current = 15, Target = 15 },
}
check(
	"live progress preserves transaction-safe undeclared phases",
	Objectives.ResolveLiveProgress(
		{ Kind = "BuildingPlaced", Params = { UpgradeId = "Noob Clicker", ShowAffordability = true } },
		affordableProjection,
		{ CookieBalance = 0 }
	) == affordableProjection
)
check(
	"BuildingPlaced progress bar belongs only to its saving phase",
	Objectives.ShowsProgressBar(
		{ Kind = "BuildingPlaced", Params = { UpgradeId = "Noob Clicker", ShowAffordability = true } },
		liveSaving
	)
		and not Objectives.ShowsProgressBar(
			{ Kind = "BuildingPlaced", Params = { UpgradeId = "Noob Clicker", ShowAffordability = true } },
			affordableProjection
		)
)
local boostModule = Objectives.Get("BoostPurchased")
check(
	"active and durable capture triggers remain distinct",
	table.find(boostModule.ActiveTriggers, "GemBalanceChanged") ~= nil
		and table.find(boostModule.CaptureTriggers, "GemBalanceChanged") == nil
)
check("structured result rejects undeclared phases", not Objectives.ValidateResult("BuildingSold", {
	Satisfied = false,
	Current = 0,
	Target = 1,
	Phase = "FreeForm",
}))
check("structured result rejects non-finite progress", not Objectives.ValidateResult("BuildingSold", {
	Satisfied = false,
	Current = 0 / 0,
	Target = 1,
	Phase = "WaitingForSale",
}))
check(
	"non-finite event values are rejected",
	DomainEvents.Validate(
		"CookieBalanceChanged",
		{ Balance = 0 / 0, Source = "Autoclick", CommitState = "Committed" },
		1
	) == nil
)

local malformed = fixtureManifest()
malformed.Definitions[1].Steps[1].Objective.Kind = "Unknown"
rejects("malformed objective fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "unknown objective")
malformed = fixtureManifest()
malformed.Definitions[1].Rewards[1].Kind = "Cookies"
rejects("malformed reward fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "unknown reward")
local unsupportedLifecycleRejected = true
for _, lifecycle in ipairs({ "Repeatable", "Daily", "Weekly", "Seasonal", "Event" }) do
	malformed = fixtureManifest()
	malformed.Definitions[1].Lifecycle.Kind = lifecycle
	local ok, problem = pcall(Schema.ValidateManifest, malformed, Objectives, Rewards)
	unsupportedLifecycleRejected = unsupportedLifecycleRejected
		and not ok
		and string.find(tostring(problem), "unsupported launch lifecycle", 1, true) ~= nil
end
check("every unsupported launch lifecycle fails closed", unsupportedLifecycleRejected)
malformed = fixtureManifest()
malformed.Definitions[1].Id = "Bad ID"
rejects("malformed stable ID fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "definition IDs")
malformed = fixtureManifest()
malformed.Definitions[2].Steps[1].Id = "sell_any"
rejects("duplicate step IDs fail closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "step IDs")
malformed = fixtureManifest()
malformed.Definitions[1].RequiresDefinitionIds = { "automation" }
malformed.Definitions[2].RequiresDefinitionIds = {}
rejects("invalid unlock order fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "dependencies must precede")
malformed = fixtureManifest()
malformed.Definitions[1].RequiresDefinitionIds = { "automation" }
malformed.Definitions[2].RequiresDefinitionIds = { "foundation" }
rejects("dependency cycles fail closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "dependency cycle")
malformed = fixtureManifest()
malformed.Definitions[2].Rewards[1].SlotId = "foundation_gems"
rejects("duplicate reward slots fail closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "reward slot IDs")
malformed = fixtureManifest()
malformed.Definitions[1].Rewards[1].Params.Amount = math.huge
rejects("non-finite reward parameters fail closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "Gems Amount")
malformed = fixtureManifest()
malformed.Definitions[1].Presentation.StepCompletion = "OneOffStepBranch"
rejects("unknown presentation policy fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "unknown step completion policy")
malformed = fixtureManifest()
local active = Schema.ValidateManifest(malformed, Objectives, Rewards).Definitions[1].Rewards[1].ReceiptId
malformed = fixtureManifest()
malformed.RetiredRewardReceipts = { active }
rejects("active and retired receipt collision fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "collides")
malformed = fixtureManifest()
for index = 3, 130 do
	table.insert(malformed.Definitions, malformed.Definitions[1])
end
rejects("unbounded content fails closed", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "size bound")

local phaseState = Schema.NewState(c)
phaseState.Instances[c.Definitions[1].InstanceId] = {
	DefinitionId = "foundation",
	DefinitionVersion = 1,
	InstanceId = c.Definitions[1].InstanceId,
	StepIndex = 1,
	Completed = false,
	RewardPending = false,
	PhaseRanks = { sell_any = 99 },
}
rejects("malformed stored phase fails closed", function()
	Schema.NormalizeState(phaseState, c)
end, "objective phase")
local collisionState = Schema.NewState(c)
collisionState.RewardReceipts["not-derived"] = true
rejects("unknown receipt identity fails closed", function()
	Schema.NormalizeState(collisionState, c)
end, "reward receipts")
local oldContentState = Schema.NewState(c)
oldContentState.ContentVersion = 6
local normalizedContentState, contentChanged = Schema.NormalizeState(oldContentState, c)
check(
	"content-version change preserves valid universal state and requests reconciliation",
	contentChanged and normalizedContentState.ContentVersion == 7
)

local persisted = { Persistent = { Gems = 41, QuestState = { SchemaVersion = 3, LegacyMarker = true } } }
local persistence = Persistence.new({
	GetData = function()
		return persisted
	end,
	Schema = Schema,
	Content = c,
})
local loaded = persistence:Load({}, "Setup")
check(
	"clean replacement state initializes without reading QuestState v3",
	loaded
		and loaded.State.SchemaVersion == 1
		and persisted.Persistent.QuestState.LegacyMarker == true
		and persisted.Persistent.Gems == 41
)
persisted.Persistent.UniversalQuestState = { SchemaVersion = 3 }
check(
	"malformed replacement state fails closed without a legacy fallback",
	persistence:Load({}, "Setup") == nil and persisted.Persistent.QuestState.LegacyMarker == true
)
loaded = persistence:Load({}, "Reset")
check(
	"replacement reset clears only universal quest state",
	loaded
		and loaded.State.SchemaVersion == 1
		and persisted.Persistent.Gems == 41
		and persisted.Persistent.QuestState.LegacyMarker == true
)

print("\nPure engine state transitions")
check(
	"engine source has no Roblox/service/clock boundary calls",
	not string.find(ENGINE_SOURCE, "game:GetService", 1, true)
		and not string.find(ENGINE_SOURCE, "GemService", 1, true)
		and not string.find(ENGINE_SOURCE, "Net.", 1, true)
		and not string.find(ENGINE_SOURCE, "os.clock", 1, true)
		and not string.find(ENGINE_SOURCE, "os.time", 1, true)
		and not string.find(ENGINE_SOURCE, "task.", 1, true)
)
local state, session = Schema.NewState(c), {}
state, session = Engine.reduce(
	c,
	state,
	facts(0, 0),
	cause("BuildingSold", { UpgradeId = "Noob Clicker", Count = 0, SoldCount = 1 }, 1),
	session
)
check(
	"early captured sale does not skip the current order",
	state.Instances[c.Definitions[1].InstanceId].StepIndex == 2
)
state, session =
	Engine.reduce(c, state, facts(0, 0), cause("UiObservation", { Observation = "BuildViewOpened" }, 2), session)
check(
	"future observation is banked before its quest unlocks",
	state.ObjectiveProgress[c.Definitions[2].InstanceId].open_build_view.Captured == true
)
local transitions, effects
state, session, transitions, effects = Engine.reduce(
	c,
	state,
	facts(2, 0),
	cause("BuildingCountChanged", { UpgradeId = "Noob Clicker", Count = 2 }, 3),
	session
)
check(
	"canonical count advances monotonically into reward settlement",
	state.Instances[c.Definitions[1].InstanceId].StepIndex == 3
		and state.Instances[c.Definitions[1].InstanceId].RewardPending == true
)
state, session = Engine.reduce(
	c,
	state,
	facts(0, 0),
	cause("BuildingSold", { UpgradeId = "Noob Clicker", Count = 0, SoldCount = 2 }, 4),
	session
)
check(
	"regressed canonical count does not un-complete a step",
	state.Instances[c.Definitions[1].InstanceId].StepIndex == 3
)
local rewardEffect = findEffect(effects, "RewardGrant")
local beforeFailure = state
state = select(
	1,
	Engine.applyEffectResult(c, state, session, rewardEffect, false, { Kind = "FullReconcile", Timestamp = 5 })
)
check(
	"failed reward leaves no receipt and quest incomplete",
	state.RewardReceipts[rewardEffect.ReceiptId] == nil and not state.Instances[c.Definitions[1].InstanceId].Completed
)
local retryEffects
state, session, _, retryEffects =
	Engine.reduce(c, state, facts(2, 10), { Kind = "FullReconcile", Timestamp = 6 }, session)
check(
	"failed reward retries with the same stable receipt",
	findEffect(retryEffects, "RewardGrant").ReceiptId == rewardEffect.ReceiptId
)
local rewardTransitions, rewardAnalytics
state, session, rewardTransitions, rewardAnalytics = Engine.applyEffectResult(
	c,
	state,
	session,
	findEffect(retryEffects, "RewardGrant"),
	true,
	{ Kind = "FullReconcile", Timestamp = 6 }
)
check(
	"successful reward records one receipt while completion ordering is pending",
	state.RewardReceipts[rewardEffect.ReceiptId] == true
		and #rewardTransitions == 0
		and session.PendingRewardTransitions[1].Kind == "RewardGranted"
)
state, session = applyEffects(c, state, session, rewardAnalytics, { Kind = "FullReconcile", Timestamp = 6 })
state, session, transitions, effects =
	Engine.reduce(c, state, facts(2, 10), { Kind = "FullReconcile", Timestamp = 6 }, session)
check(
	"reward success completes and cascades to the dependent reward",
	state.Instances[c.Definitions[1].InstanceId].Completed
		and state.Instances[c.Definitions[2].InstanceId].RewardPending
		and findEffect(effects, "RewardGrant") ~= nil
)
local questCompletedAt, rewardGrantedAt, dependentUnlockedAt
for index, value in ipairs(transitions) do
	if value.DefinitionId == "foundation" and value.Kind == "QuestCompleted" then
		questCompletedAt = index
	end
	if value.DefinitionId == "foundation" and value.Kind == "RewardGranted" then
		rewardGrantedAt = index
	end
	if value.DefinitionId == "automation" and value.Kind == "QuestUnlocked" then
		dependentUnlockedAt = index
	end
end
check(
	"quest completion and reward transitions precede dependent cascade presentation",
	questCompletedAt
		and rewardGrantedAt
		and dependentUnlockedAt
		and questCompletedAt < rewardGrantedAt
		and rewardGrantedAt < dependentUnlockedAt
)
check(
	"early captured observation credited only after the earlier balance step",
	state.Instances[c.Definitions[2].InstanceId].StepIndex == 3
)
check("tracked selection moves to the dependent quest", state.SelectedInstanceId == c.Definitions[2].InstanceId)

local secondReward = findEffect(effects, "RewardGrant")
state, session, rewardTransitions, rewardAnalytics =
	Engine.applyEffectResult(c, state, session, secondReward, true, { Kind = "FullReconcile", Timestamp = 7 })
state, session = applyEffects(c, state, session, rewardAnalytics, { Kind = "FullReconcile", Timestamp = 7 })
state, session, transitions, effects =
	Engine.reduce(c, state, facts(2, 10), { Kind = "FullReconcile", Timestamp = 7 }, session)
check(
	"bounded cascade settles both quests in authored order",
	state.Instances[c.Definitions[2].InstanceId].Completed and state.SelectedInstanceId == nil
)
local arcTransition = false
for _, value in ipairs(transitions) do
	if value.Kind == "ArcCompleted" and value.ArcId == "opening" then
		arcTransition = true
	end
end
check("arc completion is explicit and high-water persisted", arcTransition and state.CompletedArcIds.opening == true)
state, session = applyEffects(c, state, session, effects, { Kind = "FullReconcile", Timestamp = 7 })
local replayEffects
state, session, _, replayEffects =
	Engine.reduce(c, state, facts(2, 10), { Kind = "FullReconcile", Timestamp = 8 }, session)
check("completed rewards and analytics are idempotent", #replayEffects == 0)

local selectedState = Schema.NewState(c)
selectedState = select(1, Engine.reduce(c, selectedState, facts(), { Kind = "FullReconcile", Timestamp = 1 }, {}))
local unchanged, selected = Engine.select(c, selectedState, "not-an-instance")
check(
	"invalid tracked selection is rejected",
	not selected and unchanged.SelectedInstanceId == c.Definitions[1].InstanceId
)

local concurrentManifest = fixtureManifest()
concurrentManifest.Definitions[2].RequiresDefinitionIds = {}
local concurrentContent = Schema.ValidateManifest(concurrentManifest, Objectives, Rewards)
local concurrentState = select(
	1,
	Engine.reduce(
		concurrentContent,
		Schema.NewState(concurrentContent),
		facts(),
		{ Kind = "FullReconcile", Timestamp = 1 },
		{}
	)
)
local changedSelection
concurrentState, changedSelection =
	Engine.select(concurrentContent, concurrentState, concurrentContent.Definitions[2].InstanceId)
check(
	"tracked selection accepts another unlocked one-time instance",
	changedSelection and concurrentState.SelectedInstanceId == concurrentContent.Definitions[2].InstanceId
)

-- Full and incremental convergence from the same banked captured facts.
local base = Schema.NewState(c)
base = select(
	1,
	Engine.reduce(
		c,
		base,
		facts(0, 0),
		cause("BuildingSold", { UpgradeId = "Noob Clicker", Count = 0, SoldCount = 1 }, 1),
		{}
	)
)
base =
	select(1, Engine.reduce(c, base, facts(0, 0), cause("UiObservation", { Observation = "BuildViewOpened" }, 2), {}))
local full = select(1, Engine.reduce(c, base, facts(1, 0), { Kind = "FullReconcile", Timestamp = 3 }, {}))
local incremental = select(
	1,
	Engine.reduce(c, base, facts(1, 0), cause("BuildingCountChanged", { UpgradeId = "Noob Clicker", Count = 1 }, 3), {})
)
local function shape(value)
	local result = {}
	for id, instance in pairs(value.Instances) do
		result[id] = instance.StepIndex
	end
	return result
end
local function deepEqual(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in pairs(a) do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end
check("full and incremental reconciliation converge", deepEqual(full, incremental))

print("\nEffect runner retry boundary")
local effectState, effectSession = Schema.NewState(c), {}
effectState, effectSession, _, effects = Engine.reduce(
	c,
	effectState,
	facts(2, 0),
	cause("BuildingSold", { UpgradeId = "Noob Clicker", Count = 2, SoldCount = 1 }, 1),
	effectSession
)
local effect = findEffect(effects, "RewardGrant")
local grantAttempts, failNext, analyticsAttempts = 0, true, 0
local effectRunner = EffectRunner.new({
	Engine = Engine,
	Enabled = true,
	Clock = function()
		return 10
	end,
	ExecuteReward = function()
		grantAttempts += 1
		if failNext then
			failNext = false
			return false
		end
		return true
	end,
	ExecuteAnalytics = function()
		analyticsAttempts += 1
	end,
})
local succeeded
effectState, effectSession, _, _, succeeded = effectRunner:Execute(
	{},
	c,
	effectState,
	effectSession,
	effect,
	{ Kind = "FullReconcile", Timestamp = 2 }
)
check(
	"failed adapter clears transient receipt for retry",
	not succeeded
		and effectState.RewardReceipts[effect.ReceiptId] == nil
		and effectState.AnalyticsReceipts[Schema.QuestAnalyticsId(effect.InstanceId)] == nil
)
effectState, effectSession, _, _, succeeded = effectRunner:Execute(
	{},
	c,
	effectState,
	effectSession,
	effect,
	{ Kind = "FullReconcile", Timestamp = 3 }
)
check(
	"successful retry commits exactly one grant and receipt",
	succeeded and grantAttempts == 2 and effectState.RewardReceipts[effect.ReceiptId] == true
)
effectState, effectSession = effectRunner:Execute(
	{},
	c,
	effectState,
	effectSession,
	effect,
	{ Kind = "FullReconcile", Timestamp = 4 }
)
check("replaying a successful effect cannot duplicate the reward", grantAttempts == 2)
local disabledGrantAttempts = 0
local disabledRunner = EffectRunner.new({
	Engine = Engine,
	Enabled = false,
	ExecuteReward = function()
		disabledGrantAttempts += 1
		return true
	end,
	ExecuteAnalytics = function() end,
})
local disabledState, _, _, _, disabledSuccess = disabledRunner:Execute(
	{},
	c,
	beforeFailure,
	{},
	rewardEffect,
	{ Kind = "FullReconcile", Timestamp = 5 }
)
check(
	"inactive replacement cannot grant alongside the live quest service",
	not disabledSuccess and disabledGrantAttempts == 0 and disabledState.RewardReceipts[rewardEffect.ReceiptId] == nil
)

print("\nRouter performance and ordering")
check(
	"router source has no objective-kind cross-product",
	not string.find(ROUTER_SOURCE, "BuildingCountAtLeast", 1, true)
		and not string.find(ROUTER_SOURCE, "CookieBalanceAtLeast", 1, true)
		and not string.find(ROUTER_SOURCE, "ClientUiObservation", 1, true)
)

local routerManifest = fixtureManifest()
routerManifest.Definitions = {
	{
		Id = "ordered",
		Version = 1,
		ArcId = "opening",
		Order = 1,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = {},
		Steps = {
			{ Id = "intro_fact", Objective = { Kind = "StoryTransition", Params = { Fact = "IntroCompleted" } } },
			{
				Id = "ordered_observation",
				Objective = { Kind = "ClientUiObservation", Params = { Observation = "BuildViewOpened" } },
			},
		},
		Rewards = {},
	},
}
routerManifest.Arcs[1].QuestIds = { "ordered" }
routerManifest.Arcs[1].DisplayQuestCount = 1
local rc = Schema.ValidateManifest(routerManifest, Objectives, Rewards)
local contexts, eventOrder, savedTransitions, contextLoads = {}, {}, {}, 0
local clock = 0
local runner = EffectRunner.new({
	Engine = Engine,
	Enabled = true,
	Clock = function()
		clock += 1
		return clock
	end,
	ExecuteReward = function()
		return true
	end,
	ExecuteAnalytics = function() end,
})
local router
router = EventRouter.new({
	Content = rc,
	DomainEvents = DomainEvents,
	Engine = Engine,
	EffectRunner = runner,
	LoadContext = function(player)
		contextLoads += 1
		return { State = contexts[player] or Schema.NewState(rc) }
	end,
	SaveContext = function(player, context, batch)
		contexts[player] = context.State
		for _, item in ipairs(batch) do
			table.insert(savedTransitions, item.Kind)
		end
	end,
	BuildFacts = function(player, _, event)
		table.insert(eventOrder, event.Kind)
		if event.Kind == "IntroCompleted" then
			router:NotifyDomain(player, "UiObservation", { Observation = "BuildViewOpened" }, event.Timestamp + 1)
		end
		local f = facts()
		if event.Kind == "IntroCompleted" then
			f.StoryFacts.IntroCompleted = true
		end
		return f
	end,
})
local player = {}
router:SetupPlayer(player, 0)
check(
	"setup establishes current and future-capture interests",
	router.InterestByPlayer[player].IntroCompleted and router.InterestByPlayer[player].UiObservation
)
router:NotifyDomain(player, "IntroCompleted", {}, 1)
check(
	"nested domain notifications drain in serialized event order with fresh post-effect facts",
	table.concat(eventOrder, ",") == "FullReconcile,FullReconcile,IntroCompleted,IntroCompleted,UiObservation,UiObservation,UiObservation,UiObservation",
	table.concat(eventOrder, ",")
)
check(
	"serialized turns produce ordered explicit completion transitions",
	table.concat(savedTransitions, ","):find("StepCompleted,QuestCompleted", 1, true) ~= nil,
	table.concat(savedTransitions, ",")
)

local late = {}
contexts[late] = Schema.NewState(rc)
local definition = rc.Definitions[1]
contexts[late].Instances[definition.InstanceId] = {
	DefinitionId = definition.Id,
	DefinitionVersion = definition.Version,
	InstanceId = definition.InstanceId,
	StepIndex = 3,
	Completed = true,
	RewardPending = false,
	PhaseRanks = {},
}
contexts[late].AnalyticsReceipts[Schema.QuestAnalyticsId(definition.InstanceId)] = true
router.InterestByPlayer[late] = {}
local before = contextLoads
local accepted = router:NotifyDomain(late, "CookieBalanceChanged", {
	Balance = 999999,
	Source = "Autoclick",
	CommitState = "Committed",
}, 10)
local measurements = router:GetMeasurements()
check(
	"late-game autoclick rejects before profile/context construction",
	not accepted and contextLoads == before and measurements.EarlyInterestRejections >= 1
)
local pendingBefore = contextLoads
router.InterestByPlayer[player].CookieBalanceChanged = true
router:NotifyDomain(
	player,
	"CookieBalanceChanged",
	{ Balance = 0, Source = "PendingPurchase", CommitState = "PendingPurchase" },
	11
)
check(
	"pending purchase balance rejects before context and preserves refund ordering",
	contextLoads == pendingBefore and router:GetMeasurements().UncommittedRejections == 1
)
local fullBefore = router:GetMeasurements().FullReconciliations
router:ResetPlayer(player, 12)
router:ContentVersionChanged(player, 13)
router:DeveloperCheck(player, 14)
check(
	"reset, content-version, and developer checks all use complete reconciliation",
	router:GetMeasurements().FullReconciliations == fullBefore + 3
)

print(("\n%d failure(s)"):format(failures))
if failures > 0 then
	error(("Stage B quest core has %d failure(s)"):format(failures))
end
