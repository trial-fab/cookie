--!nocheck
-- Pure Stage C server protocol/outbox fixtures. No Roblox globals or services.

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
local Protocol = loadModule("QuestProtocol")
local Outbox = loadModule("Quest.QuestSessionOutbox")
local ProtocolServer = loadModule("Quest.QuestProtocolServer")

local failures = 0
local function check(label, condition, detail)
	if condition then
		print("  ok   " .. label)
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and " -- " .. tostring(detail) or ""))
	end
end

local function manifest()
	return {
		ContentVersion = 9,
		Arcs = {
			{ Id = "fixture_arc", Order = 1, QuestIds = { "fixture_quest" }, DisplayQuestCount = 1 },
		},
		Definitions = {
			{
				Id = "fixture_quest",
				Version = 3,
				ArcId = "fixture_arc",
				Order = 1,
				Lifecycle = { Kind = "OneTime" },
				RequiresDefinitionIds = {},
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					QuestCompletion = "TutorialCompletion",
					Passive = "PassiveToast",
				},
				Steps = {
					{
						Id = "own_two_fixture",
						Objective = {
							Kind = "BuildingCountAtLeast",
							Params = { UpgradeId = "Fixture Builder", Count = 2 },
						},
					},
				},
				Rewards = { { SlotId = "fixture_gems", Kind = "Gems", Params = { Amount = 0 } } },
			},
		},
		RetiredRewardReceipts = {},
	}
end

local content = Schema.ValidateManifest(manifest(), Objectives, Rewards)
local function facts(count)
	return {
		StoryFacts = {},
		HealingManualClicks = 0,
		HealingSequenceCompleted = false,
		UpgradeCounts = { ["Fixture Builder"] = count or 0 },
		UpgradeCosts = {},
		CookieBalance = 0,
	}
end

local function cause(count, timestamp)
	return assert(DomainEvents.Validate(
		"BuildingCountChanged",
		{ UpgradeId = "Fixture Builder", Count = count },
		timestamp
	))
end

local function find(values, kind)
	for _, value in ipairs(values or {}) do
		if value.Kind == kind then
			return value
		end
	end
end

local function containsKey(value, needle)
	if type(value) ~= "table" then
		return false
	end
	for key, child in pairs(value) do
		if tostring(key):find(needle, 1, true) or containsKey(child, needle) then
			return true
		end
	end
	return false
end

print("\nProtocol vocabulary and sanitized shapes")
check("protocol v2 is the only supported version", Protocol.Version == 2)
for _, kind in ipairs({
	"QuestUnlocked",
	"StepMilestoneReached",
	"StepCompleted",
	"QuestCompleted",
	"ArcCompleted",
	"RewardGranted",
}) do
	check("closed vocabulary supports " .. kind, Protocol.IsSupportedTransition(kind))
end
check(
	"future lifecycle transition is reserved but unsupported",
	Protocol.IsReservedTransition("QuestExpired") and not Protocol.IsSupportedTransition("QuestExpired")
)

local state, session, firstTransitions, effects = Engine.reduce(
	content,
	Schema.NewState(content),
	facts(2),
	cause(2, 10),
	{}
)
check(
	"final objective waits for the single quest-completion ceremony",
	find(firstTransitions, "StepCompleted") == nil
)
local rewardEffect = find(effects, "RewardGrant")
local failedState, failedSession, failedTransitions = Engine.applyEffectResult(
	content,
	state,
	session,
	rewardEffect,
	false,
	{ Kind = "FullReconcile", Timestamp = 11 }
)
check("failed reward effect emits no presentation transition", #failedTransitions == 0)

state, session, failedTransitions = Engine.applyEffectResult(
	content,
	state,
	session,
	rewardEffect,
	true,
	{ Kind = "FullReconcile", Timestamp = 12 }
)
check(
	"reward presentation waits behind successful authoritative effect",
	#failedTransitions == 0 and session.PendingRewardTransitions[1].Kind == "RewardGranted"
)
local completionTransitions
state, session, completionTransitions = Engine.reduce(
	content,
	state,
	facts(0),
	{ Kind = "FullReconcile", Timestamp = 13 },
	session
)
local questAt, rewardAt, arcAt
for index, transition in ipairs(completionTransitions) do
	if transition.Kind == "QuestCompleted" then questAt = index end
	if transition.Kind == "RewardGranted" then rewardAt = index end
	if transition.Kind == "ArcCompleted" then arcAt = index end
end
local questCompleted = completionTransitions[questAt]
check(
	"quest completion preserves the event-time 2/2 projection",
	questCompleted and questCompleted.Projection.Current == 2 and questCompleted.Projection.Target == 2
)
check(
	"quest, reward, and arc cascade transitions are deterministic",
	questAt and rewardAt and arcAt and questAt < rewardAt and rewardAt < arcAt
)
check(
	"zero-value reward has structured public projection",
	completionTransitions[rewardAt].Projection.Amount == 0 and completionTransitions[rewardAt].ReceiptId == nil
)

local snapshot = assert(Protocol.BuildSnapshot(content, state, facts(0)))
check(
	"latest snapshot may regress current canonical projection without changing completion",
	snapshot.Instances[1].Completed
		and snapshot.Instances[1].CurrentStep.Projection.Current == 0
		and snapshot.Instances[1].CurrentStep.Projection.Target == 2
)
check("snapshot exposes no raw receipt keys", not containsKey(snapshot, "Receipt"))

print("\nReady-gated session delivery")
local sent, diagnostics, sessionCounter = {}, {}, 0
local outbox = Outbox.new({
	Protocol = Protocol,
	MaxTransitions = 16,
	NewSessionId = function()
		sessionCounter += 1
		return "fixture-session-" .. sessionCounter
	end,
	SendEnvelope = function(_, envelope)
		table.insert(sent, envelope)
	end,
	OnDiagnostic = function(_, diagnostic)
		table.insert(diagnostics, diagnostic)
	end,
})
local server = ProtocolServer.new({ Protocol = Protocol, Outbox = outbox, Content = content })
local player = {}
server:BeginSession(player)
local setupEnvelope, setupProblem = server:Publish(player, select(1, Engine.reduce(
	content,
	Schema.NewState(content),
	facts(2),
	cause(2, 20),
	{}
)), facts(2), firstTransitions)
check("setup transitions queue before Ready", setupEnvelope == nil and setupProblem == "waiting for Ready" and #sent == 0)
server:Publish(player, state, facts(0), completionTransitions)
local readyEnvelope = server:Ready(player, Protocol.ReadyRequest())
check(
	"Ready receives latest snapshot plus current-session pending transitions once",
	readyEnvelope and #sent == 1 and readyEnvelope.Revision == 2 and #readyEnvelope.Transitions == #firstTransitions + #completionTransitions
)
local deliveredStep = find(readyEnvelope.Transitions, "QuestCompleted")
check(
	"event-time 2/2 survives later canonical regression before delivery",
	deliveredStep.Projection.Current == 2
		and readyEnvelope.Snapshot.Instances[1].CurrentStep.Projection.Current == 0
)
check(
	"transition identity carries session/revision/ordinal and definition identities",
	deliveredStep.Id == ("%s:%d:%d"):format(deliveredStep.SessionId, deliveredStep.Revision, deliveredStep.Ordinal)
		and deliveredStep.DefinitionId == "fixture_quest"
		and deliveredStep.DefinitionVersion == 3
		and deliveredStep.InstanceId == content.Definitions[1].InstanceId
)
local duplicateReady = server:Ready(player, Protocol.ReadyRequest())
check(
	"duplicate Ready does not replay the batch",
	duplicateReady == nil and #sent == 1 and server:GetMetrics().DuplicateReadyCalls == 1
)
local plain = server:Publish(player, state, facts(0), {})
check("later plain republish has no old transitions", plain and #plain.Transitions == 0 and #sent == 2)

server:BeginSession(player)
server:Publish(player, state, facts(0), {})
local reconnect = server:Ready(player, Protocol.ReadyRequest())
check(
	"reconnect creates a new session without persisted ceremony replay",
	reconnect.SessionId ~= readyEnvelope.SessionId and #reconnect.Transitions == 0
)
server:ClearPlayer(player)
check("player leave clears session/outbox state", outbox:GetSession(player) == nil)

local earlyReadyPlayer = {}
server:BeginSession(earlyReadyPlayer)
local earlyReady, earlyReadyProblem = server:Ready(earlyReadyPlayer, Protocol.ReadyRequest())
check("Ready may safely arrive before setup snapshot", earlyReady == nil and earlyReadyProblem == "waiting for snapshot")
local earlyDelivery = server:Publish(earlyReadyPlayer, state, facts(0), completionTransitions)
check(
	"first publish after early Ready sends snapshot and queued setup transitions once",
	earlyDelivery and #earlyDelivery.Transitions == #completionTransitions and server:Ready(earlyReadyPlayer, Protocol.ReadyRequest()) == nil
)

local v1 = Protocol.Clone(readyEnvelope)
v1.ProtocolVersion = 1
check("protocol-v1 envelope is rejected", not Protocol.ValidateEnvelope(v1))
local reserved = Protocol.Clone(questCompleted)
reserved.Kind = "QuestExpired"
reserved.PresentationMode = "Tracked"
check(
	"reserved transition is rejected while unsupported",
	select(1, Protocol.StampTransition("reserved-session", 1, 1, reserved)) == nil
)
local privateProjection = Protocol.Clone(questCompleted)
privateProjection.Projection.ReceiptId = "raw-secret"
check(
	"transition projection rejects raw receipt/prose fields",
	select(1, Protocol.StampTransition("private-session", 1, 1, privateProjection)) == nil
)

print("\nBounded overflow behavior")
local overflowDiagnostics, overflowCounter = {}, 0
local bounded = Outbox.new({
	Protocol = Protocol,
	MaxTransitions = 3,
	NewSessionId = function() return "bounded-session" end,
	OnDiagnostic = function(_, diagnostic) table.insert(overflowDiagnostics, diagnostic) end,
})
local overflowPlayer = {}
bounded:BeginSession(overflowPlayer)
for revision = 1, 5 do
	local currentSnapshot = Protocol.Clone(snapshot)
	currentSnapshot.ContentVersion = revision
	local raw = Protocol.Clone(questCompleted)
	raw.CauseTimestamp = 30 + revision
	bounded:Publish(overflowPlayer, currentSnapshot, { raw })
end
local overflowReady = bounded:Ready(overflowPlayer, Protocol.ReadyRequest())
local overflowMetrics = bounded:GetMetrics()
check(
	"overflow keeps newest deterministic suffix and latest snapshot",
	#overflowReady.Transitions == 3
		and overflowReady.Transitions[1].Revision == 3
		and overflowReady.Transitions[3].Revision == 5
		and overflowReady.Snapshot.ContentVersion == 5
)
check(
	"overflow surfaces bounded diagnostics without touching authority",
	overflowMetrics.OverflowEvents == 2
		and overflowMetrics.DroppedTransitions == 2
		and #overflowDiagnostics == 2
		and state.RewardReceipts[rewardEffect.ReceiptId] == true
)

print(("\n%d failure(s)"):format(failures))
if failures > 0 then
	error(("Stage C quest protocol has %d failure(s)"):format(failures))
end
