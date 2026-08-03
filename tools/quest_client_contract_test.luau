--!nocheck
-- Executable Stage A fixtures for the future pure quest client reducer and ordered
-- presentation queue. Run through tools/quest_client_contract_test.py.

local Harness = assert(loadstring(HARNESS_SOURCE))()

local failures = 0
local function check(label, condition, detail)
	if condition then
		print(("  ok   %s"):format(label))
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and (" -- " .. tostring(detail)) or ""))
	end
end

local function joined(values)
	return table.concat(values, " | ")
end

local function traceEquals(queue, expected)
	return joined(queue.Trace) == joined(expected)
end

local function settle(queue)
	while not queue:isIdle() do
		if queue.Waiting then
			queue:resolve("completed")
		else
			queue:pump()
		end
	end
end

local fixtures = {}

fixtures.step_and_quest_strikethrough_ordering = function()
	local queue = Harness.Queue.new({ Motion = "Standard", CurrentCopy = "old", ActiveGuide = "old-guide" })
	queue:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "old-step",
			OutgoingCopy = "old",
			OutgoingGuide = "old-guide",
			NextCopy = "new",
			NextGuide = "new-guide",
			Release = { Kind = "Immediate" },
		},
	})
	check(
		"step stops its GuideFrame before rendering and striking",
		traceEquals(queue, {
			"guide:stop:old-guide",
			"copy:outgoing:old",
			"strike:start:step:old-step",
		}),
		joined(queue.Trace)
	)
	queue:resolve("completed")
	check(
		"step reveals copy before starting its next GuideFrame",
		traceEquals(queue, {
			"guide:stop:old-guide",
			"copy:outgoing:old",
			"strike:start:step:old-step",
			"strike:completed:step:old-step",
			"strike:complete:step:old-step",
			"release:immediate",
			"copy:next:new",
			"guide:start:new-guide",
		}),
		joined(queue.Trace)
	)

	queue.Trace = {}
	queue:enqueue({
		{
			Kind = "QuestCompleted",
			QuestId = "quest-a",
			OutgoingCopy = "final",
			OutgoingGuide = "new-guide",
			Lesson = "lesson",
		},
		{
			Kind = "RewardGranted",
			QuestId = "quest-a",
			RewardSlotId = "quest_reward",
			Amount = 10,
		},
	})
	queue:resolve("completed")
	check(
		"quest strike precedes its lesson and completion hold",
		joined(queue.Trace):find("strike:complete:quest:quest%-a | lesson:quest%-a | hold:start:quest%-a") ~= nil,
		joined(queue.Trace)
	)
	queue:resolve("completed")
	check("quest reward completion releases its hold", queue:isIdle() and queue.State.CompletionHold == nil)
end

fixtures.guideframe_stop_start_ordering = function()
	local queue = Harness.Queue.new({ Motion = "Reduced", ActiveGuide = "cookie-frame" })
	queue:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "heal",
			OutgoingCopy = "heal",
			OutgoingGuide = "cookie-frame",
			NextCopy = "dialogue",
			NextGuide = "dialogue-frame",
		},
	})
	check(
		"Reduced Motion preserves GuideFrame stop/copy/start order",
		traceEquals(queue, {
			"guide:stop:cookie-frame",
			"copy:outgoing:heal",
			"strike:snap:step:heal",
			"strike:complete:step:heal",
			"release:immediate",
			"copy:next:dialogue",
			"guide:start:dialogue-frame",
		}),
		joined(queue.Trace)
	)
end

fixtures.mid_step_milestone_replacement = function()
	local queue = Harness.Queue.new({ Motion = "Standard", ActiveGuide = "cookie" })
	queue:enqueue({
		{
			Kind = "StepMilestoneReached",
			MilestoneId = "first-helper-affordable",
			OutgoingCopy = "Save 15 cookies. (15/15)",
			OutgoingGuide = "cookie",
			NextCopy = "Buy and place a Noob Clicker.",
			NextGuide = "mixer-row",
			Release = { Kind = "TimingProfile", Profile = "TutorialReadableBeat" },
		},
	})
	queue:resolve("completed")
	check("milestone waits after striking the outgoing copy", queue.Waiting and queue.Waiting.Kind == "Timer")
	queue:resolve("completed")
	check(
		"milestone replaces copy before the new guide",
		queue.State.CurrentCopy == "Buy and place a Noob Clicker." and queue.State.ActiveGuide == "mixer-row",
		joined(queue.Trace)
	)
end

fixtures.completion_holds_and_presentation_signals = function()
	local queue = Harness.Queue.new({ Motion = "Standard", ActiveGuide = "dialogue" })
	queue:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "unlock-mixer",
			OutgoingCopy = "Finish talking.",
			OutgoingGuide = "dialogue",
			NextCopy = "Buy a helper.",
			NextGuide = "mixer",
			Release = { Kind = "PresentationSignal", Name = "MixerUnlockPresented" },
		},
	})
	queue:resolve("completed")
	check(
		"next copy remains held for its presentation signal",
		queue.Waiting and queue.Waiting.Kind == "Signal" and queue.State.CurrentCopy == "Finish talking."
	)
	queue:signal("MixerUnlockPresented")
	check(
		"presentation signal releases copy and guide together",
		queue:isIdle() and queue.State.CurrentCopy == "Buy a helper." and queue.State.ActiveGuide == "mixer"
	)

	local already = Harness.Queue.new({ Motion = "Reduced" })
	already:signal("MixerUnlockPresented")
	already:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "unlock-mixer",
			OutgoingCopy = "Finish talking.",
			NextCopy = "Buy a helper.",
			Release = {
				Kind = "PresentationSignal",
				Name = "MixerUnlockPresented",
				Fallback = { Kind = "TimingProfile", Profile = "TutorialReadableBeat" },
			},
		},
	})
	check(
		"an already-finished signal uses its declared readable fallback",
		already.Waiting and already.Waiting.Kind == "Timer",
		joined(already.Trace)
	)
	already:resolve("completed")
end

fixtures.reward_sequencing_and_cascade_completions = function()
	local queue = Harness.Queue.new({ Motion = "Standard" })
	queue:enqueue({
		{ Kind = "QuestCompleted", QuestId = "q1", OutgoingCopy = "q1 final", Lesson = "q1 lesson" },
		{ Kind = "RewardGranted", QuestId = "q1", RewardSlotId = "gems", Amount = 10 },
		{ Kind = "QuestCompleted", QuestId = "q2", OutgoingCopy = "q2 final", Lesson = "q2 lesson" },
		{ Kind = "RewardGranted", QuestId = "q2", RewardSlotId = "gems", Amount = 5 },
	})
	queue:resolve("completed")
	check(
		"first cascade completion holds on its reward",
		queue.Waiting and queue.Waiting.Kind == "Reward" and queue.State.CompletionHold == "q1"
	)
	queue:resolve("completed")
	check(
		"second cascade strike starts only after q1 reward releases",
		queue.Waiting
			and queue.Waiting.Kind == "Strike"
			and queue.Waiting.Key == "quest:q2"
			and queue.State.CompletionHold == nil,
		joined(queue.Trace)
	)
	queue:resolve("completed")
	queue:resolve("completed")
	check(
		"cascade rewards present sequentially",
		queue:isIdle() and joined(queue.State.PresentedRewards) == "q1/gems | q2/gems",
		joined(queue.State.PresentedRewards)
	)
end

fixtures.missing_targets_cancellation_and_timeout_release = function()
	local missing = Harness.Queue.new({ Motion = "Standard", ActiveGuide = "old" })
	missing:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "missing-strike",
			OutgoingCopy = "old",
			OutgoingGuide = "old",
			NextCopy = "new",
			NextGuide = "missing-guide",
			StrikeTarget = false,
			NextGuideTarget = false,
		},
	})
	check(
		"missing strike and guide targets do not strand the queue",
		missing:isIdle() and missing.State.CurrentCopy == "new" and missing.State.ActiveGuide == nil,
		joined(missing.Trace)
	)

	local cancelled = Harness.Queue.new({ Motion = "Standard" })
	cancelled:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "cancelled-strike",
			OutgoingCopy = "old",
			NextCopy = "new",
		},
	})
	cancelled:cancel()
	check("cancelled strike releases the queue", cancelled:isIdle() and cancelled.State.CurrentCopy == "new")

	local timed = Harness.Queue.new({ Motion = "Standard" })
	timed:enqueue({
		{
			Kind = "StepCompleted",
			StepId = "signal-timeout",
			OutgoingCopy = "old",
			NextCopy = "new",
			Release = { Kind = "PresentationSignal", Name = "NeverFires" },
		},
	})
	timed:resolve("completed")
	timed:timeout()
	check("signal timeout releases the queue", timed:isIdle() and timed.State.CurrentCopy == "new")

	local reward = Harness.Queue.new({ Motion = "Standard" })
	reward:enqueue({
		{ Kind = "QuestCompleted", QuestId = "fallback", OutgoingCopy = "done", StrikeTarget = false },
		{
			Kind = "RewardGranted",
			QuestId = "fallback",
			RewardSlotId = "gems",
			Amount = 10,
			RewardTarget = false,
		},
	})
	check(
		"missing reward target falls back and releases completion",
		reward:isIdle() and reward.State.CompletionHold == nil and reward.State.CompletionSignals.fallback == true,
		joined(reward.Trace)
	)
end

fixtures.standard_and_reduced_motion_final_state = function()
	local transitions = {
		{
			Kind = "StepMilestoneReached",
			MilestoneId = "affordable",
			OutgoingCopy = "save",
			NextCopy = "buy",
			NextGuide = "store-row",
		},
		{
			Kind = "QuestCompleted",
			QuestId = "quest",
			OutgoingCopy = "buy",
			OutgoingGuide = "store-row",
			Lesson = "lesson",
		},
		{ Kind = "RewardGranted", QuestId = "quest", RewardSlotId = "gems", Amount = 10 },
	}
	local standard = Harness.Queue.new({ Motion = "Standard" })
	standard:enqueue(transitions)
	settle(standard)
	local reduced = Harness.Queue.new({ Motion = "Reduced" })
	reduced:enqueue(transitions)
	settle(reduced)
	local a = standard:logicalState()
	local b = reduced:logicalState()
	check(
		"Standard and Reduced Motion end on the same copy/guide/hold",
		a.CurrentCopy == b.CurrentCopy and a.ActiveGuide == b.ActiveGuide and a.CompletionHold == b.CompletionHold
	)
	check(
		"Standard and Reduced Motion fire the same completion signal",
		a.CompletionSignals.quest == true and b.CompletionSignals.quest == true
	)
	check(
		"Standard and Reduced Motion settle the same reward",
		joined(a.PresentedRewards) == joined(b.PresentedRewards)
	)
end

fixtures.reducer_and_measurement_counters = function()
	local reducer = Harness.Reducer.new()
	local accepted = reducer:apply({
		SessionId = "session-a",
		Revision = 1,
		Snapshot = { SelectedQuestId = "q1" },
		Transitions = { { Id = "session-a:1:1", Kind = "StepCompleted" } },
	})
	check("reducer accepts a current revision", #accepted == 1 and reducer.Snapshot.SelectedQuestId == "q1")
	check("reducer rejects a duplicate revision", #reducer:apply({
		SessionId = "session-a",
		Revision = 1,
		Snapshot = { SelectedQuestId = "wrong" },
		Transitions = {},
	}) == 0 and reducer.Snapshot.SelectedQuestId == "q1")
	check("new session accepts its own revision space", #reducer:apply({
		SessionId = "session-b",
		Revision = 1,
		Snapshot = { SelectedQuestId = "q2" },
		Transitions = { { Id = "session-b:1:1", Kind = "StepCompleted" } },
	}) == 1 and reducer.Snapshot.SelectedQuestId == "q2")

	local measurements = Harness.Measurements.new()
	measurements:notifyDomain(false)
	measurements:notifyDomain(true)
	measurements:fullReconciliation()
	local counters = measurements:snapshot()
	check("domain notification counter increments", counters.DomainNotifications == 2)
	check("full reconciliation counter increments", counters.FullReconciliations == 1)
	check(
		"early interest rejection exits before context load",
		counters.EarlyInterestRejections == 1 and counters.ContextLoads == 2
	)
end

local stageCCache = {}
local function stageC(name)
	if stageCCache[name] then
		return stageCCache[name]
	end
	local chunk = assert(loadstring(assert(STAGE_C_SOURCES[name], "missing Stage C source " .. name)))
	setfenv(chunk, setmetatable({ warn = function() end }, { __index = getfenv() }))
	local result = chunk()
	stageCCache[name] = result
	return result
end

local Protocol = stageC("QuestProtocol")
local ProductionReducer = stageC("QuestProgressReducer")
local ProductionSignals = stageC("QuestProgressPresentationSignals")
local ProductionPolicies = stageC("QuestProgressPresentationPolicies")
local ProductionQueue = stageC("QuestProgressPresentationQueue")
local ProductionVisualAdapters = stageC("QuestProgressPresentationVisualAdapters")
local ProductionCoordinator = stageC("QuestProgressPresentationCoordinator")
local ProductionController = stageC("QuestProgressV2Controller")

fixtures.production_visual_adapter_preserves_guide_owner = function()
	local owner = { Starts = 0, Stops = 0 }
	function owner:Start(context, done)
		self.Starts += 1
		check("guide start receives its stateful owner", self == owner and context.Marker == "start")
		done("completed")
		return function() end
	end
	function owner:Stop(context, done)
		self.Stops += 1
		check("guide stop receives its stateful owner", self == owner and context.Marker == "stop")
		done("completed")
	end
	local visual = ProductionVisualAdapters.new({ Guides = owner })
	local startOutcome, stopOutcome
	visual.StartGuide({ Marker = "start" }, function(outcome) startOutcome = outcome end)
	visual.StopGuide({ Marker = "stop" }, function(outcome) stopOutcome = outcome end)
	check(
		"visual bridge completes stateful guide methods",
		owner.Starts == 1 and owner.Stops == 1 and startOutcome == "completed" and stopOutcome == "completed",
		("starts=%s stops=%s start=%s stop=%s"):format(
			tostring(owner.Starts),
			tostring(owner.Stops),
			tostring(startOutcome),
			tostring(stopOutcome)
		)
	)
end

local function snapshot(current, selectedId)
	selectedId = selectedId or "onetime:fixture_q:v1"
	return {
		QuestStateSchemaVersion = 1,
		ContentVersion = 1,
		SelectedInstanceId = selectedId,
		HideCompleted = false,
		Arcs = {
			{
				ArcId = "fixture_arc",
				Completed = false,
				CompletedQuestCount = 0,
				DisplayQuestCount = 2,
				InstanceIds = { selectedId },
			},
		},
		Instances = {
			{
				DefinitionId = "fixture_q",
				DefinitionVersion = 1,
				InstanceId = selectedId,
				QuestId = "fixture_q",
				ArcId = "fixture_arc",
				LifecycleKind = "OneTime",
				Selected = true,
				Completed = false,
				RewardPending = false,
				StepIndex = 1,
				StepCount = 2,
				CurrentStep = {
					StepId = "fixture_current",
					StepIndex = 1,
					Projection = {
						Satisfied = false,
						Current = current or 0,
						Target = 2,
						Phase = "Collecting",
						Tokens = { Current = current or 0, Target = 2 },
					},
				},
				Rewards = {},
			},
		},
	}
end

local function rawTransition(kind, fields)
	local value = fields or {}
	value.Kind = kind
	value.DefinitionId = value.DefinitionId or "fixture_q"
	value.DefinitionVersion = value.DefinitionVersion or 1
	value.InstanceId = value.InstanceId or "onetime:fixture_q:v1"
	value.QuestId = value.QuestId or value.DefinitionId
	value.ArcId = value.ArcId or "fixture_arc"
	value.CauseTimestamp = value.CauseTimestamp or 1
	value.PassivePolicy = value.PassivePolicy or "PassiveToast"
	value.PresentationMode = value.PresentationMode or "Tracked"
	return value
end

local function protocolEnvelope(sessionId, revision, nextSnapshot, rawTransitions)
	local stamped = {}
	for ordinal, transition in ipairs(rawTransitions or {}) do
		stamped[ordinal] = assert(Protocol.StampTransition(sessionId, revision, ordinal, transition))
	end
	return assert(Protocol.MakeEnvelope(sessionId, revision, nextSnapshot, stamped))
end

local ManualScheduler = {}
ManualScheduler.__index = ManualScheduler
function ManualScheduler.new()
	return setmetatable({ Timers = {}, Sequence = 0 }, ManualScheduler)
end
function ManualScheduler:After(seconds, callback)
	self.Sequence += 1
	local timer = { Seconds = seconds, Callback = callback, Active = true, Sequence = self.Sequence }
	table.insert(self.Timers, timer)
	return function() timer.Active = false end
end
function ManualScheduler:FireNext()
	local selected
	for _, timer in ipairs(self.Timers) do
		if timer.Active and (not selected or timer.Sequence < selected.Sequence) then
			selected = timer
		end
	end
	if not selected then
		return false
	end
	selected.Active = false
	selected.Callback()
	return true
end
function ManualScheduler:Drain(queue)
	local bound = 100
	while not queue:IsIdle() and bound > 0 do
		bound -= 1
		assert(self:FireNext(), "queue is waiting without a scheduled completion")
	end
	assert(bound > 0, "manual scheduler failed to settle")
end

local function policies()
	return ProductionPolicies.new({
		TimingProfiles = { FixtureBeat = { DurationSeconds = 0.5 } },
		Policies = {
			FixtureImmediateStrike = {
				Family = "Step",
				Strike = true,
				Release = { Kind = "Immediate" },
			},
			FixtureSignal = {
				Family = "Step",
				Strike = true,
				Release = {
					Kind = "PresentationSignal",
					Name = "FixturePresentationFinished",
					Fallback = { Kind = "TimingProfile", Profile = "FixtureBeat" },
				},
			},
			FixtureManualReserved = {
				Family = "Step",
				Strike = false,
				Release = { Kind = "ManualAcknowledge", Acknowledgement = "FixtureAcknowledgement" },
			},
		},
	})
end

local function adapters(options)
	options = options or {}
	local trace, pending = {}, {}
	local result = {
		StopGuide = function(_, done)
			table.insert(trace, "guide:stop")
			if options.StopMissing then return false end
			done("completed")
		end,
		RenderEvent = function(context)
			table.insert(trace, "copy:event:" .. tostring(context.Transition.Projection and context.Transition.Projection.Current))
		end,
		Strike = function(context, done)
			table.insert(trace, "strike:start")
			if options.StrikeThrows then error("destroyed strike target") end
			if options.StrikeMissing then return false end
			if options.StrikePending then
				pending.Strike = done
				return function(reason)
					table.insert(trace, "strike:cancel:" .. tostring(reason))
				end
			end
			done("completed")
		end,
		RenderCurrent = function(context)
			local current = context.Step and context.Step.Projection.Current
			table.insert(trace, "copy:current:" .. tostring(current))
		end,
		StartGuide = function(_, done)
			table.insert(trace, "guide:start")
			if options.GuideThrows then error("destroyed guide target") end
			if options.GuideMissing then return false end
			if options.GuidePending then
				pending.Guide = done
				return function(reason) table.insert(trace, "guide:cancel:" .. tostring(reason)) end
			end
			done("completed")
		end,
		BeginCompletion = function(context)
			table.insert(trace, "completion:begin:" .. context.Transition.InstanceId)
		end,
		EndCompletion = function(context)
			table.insert(trace, "completion:end:" .. context.Transition.InstanceId)
		end,
		PresentReward = function(context, done)
			local key = context.Transition.InstanceId .. "/" .. context.Transition.RewardSlotId
			table.insert(trace, "reward:start:" .. key)
			if options.RewardThrows then error("destroyed reward target") end
			if options.RewardMissing then return false end
			if options.RewardPending then
				pending.Reward = done
				return function(reason) table.insert(trace, "reward:cancel:" .. tostring(reason)) end
			end
			done("completed")
		end,
		PresentPassive = function(context, done)
			table.insert(trace, "passive:" .. tostring(context.Transition.InstanceId))
			done("completed")
		end,
	}
	return result, trace, pending
end

local function productionQueue(motion, adapterOptions, signalBoundary)
	local scheduler = ManualScheduler.new()
	local visual, trace, pending = adapters(adapterOptions)
	local queue = ProductionQueue.new({
		Policies = policies(),
		Signals = signalBoundary or ProductionSignals.new(),
		Scheduler = scheduler,
		Adapters = visual,
		Motion = motion or "Standard",
	})
	queue:SetSnapshot(snapshot(0))
	return queue, scheduler, trace, pending
end

fixtures.stage_c_protocol_reducer = function()
	local reducer = ProductionReducer.new({ Protocol = Protocol })
	local step = rawTransition("StepCompleted", {
		StepId = "fixture_outgoing",
		StepIndex = 1,
		Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
		PresentationPolicy = "StandardConcise",
	})
	local first = protocolEnvelope("client-session-a", 1, snapshot(0), { step })
	local accepted = reducer:Apply(first)
	check("production reducer accepts protocol-v2 transition", accepted.Accepted and #accepted.Transitions == 1)

	local v1 = Protocol.Clone(first)
	v1.ProtocolVersion = 1
	local rejected = reducer:Apply(v1)
	check("production reducer rejects unsupported protocol versions", not rejected.Accepted)

	local duplicate = reducer:Apply(first)
	check(
		"production reducer ignores duplicate envelope without replacing snapshot",
		not duplicate.Accepted and reducer.Snapshot.Instances[1].CurrentStep.Projection.Current == 0
	)
	local plain = reducer:Apply(protocolEnvelope("client-session-a", 2, snapshot(1), {}))
	check(
		"plain snapshot applies without inventing transitions",
		plain.Accepted and #plain.Transitions == 0 and reducer.Snapshot.Instances[1].CurrentStep.Projection.Current == 1
	)
	local stale = reducer:Apply(first)
	check("stale envelope is harmless", not stale.Accepted and reducer.Revision == 2)

	local replayOldTransition = assert(Protocol.MakeEnvelope("client-session-a", 3, snapshot(1), first.Transitions))
	local replay = reducer:Apply(replayOldTransition)
	check("stable transition identity enqueues at most once", replay.Accepted and #replay.Transitions == 0)

	local changed = reducer:Apply(protocolEnvelope("client-session-b", 1, snapshot(0), { step }))
	check(
		"new session has a distinct revision/deduplication space",
		changed.Accepted and changed.SessionChanged and #changed.Transitions == 1
	)
	local retired = reducer:Apply(protocolEnvelope("client-session-a", 4, snapshot(1), {}))
	check(
		"envelope from a retired session cannot switch reducer backward",
		not retired.Accepted and reducer.SessionId == "client-session-b" and reducer.Revision == 1
	)
	local gapEnvelope = protocolEnvelope("client-session-b", 3, snapshot(2), { step })
	local gap = reducer:Apply(gapEnvelope)
	check(
		"revision gap applies latest snapshot, drops ceremony, and diagnoses without resend",
		gap.Accepted
			and #gap.Transitions == 0
			and gap.Diagnostic.Kind == "RevisionGap"
			and reducer.Snapshot.Instances[1].CurrentStep.Projection.Current == 2
	)
	local gapReplay = reducer:Apply(assert(Protocol.MakeEnvelope("client-session-b", 4, snapshot(2), gapEnvelope.Transitions)))
	check("revision-gap batch is never replayed as loss recovery", gapReplay.Accepted and #gapReplay.Transitions == 0)
end

fixtures.stage_c_ready_bootstrap_and_plain_publish = function()
	local order, received, readyCalls = {}, 0, 0
	local controller = ProductionController.new({
		Protocol = Protocol,
		Coordinator = {
			HandleEnvelope = function() received += 1 end,
		},
		BindEnvelope = function(callback)
			table.insert(order, "bind")
			callback(protocolEnvelope("bootstrap-session", 1, snapshot(0), {}))
			return function() table.insert(order, "disconnect") end
		end,
		SendReady = function(request)
			readyCalls += 1
			table.insert(order, "ready")
			check("client sends only validated protocol-v2 Ready", Protocol.ValidateReady(request))
		end,
	})
	check("inactive controller factory binds before Ready", controller:Start() and joined(order) == "bind | ready")
	check("duplicate Start does not duplicate Ready", not controller:Start() and readyCalls == 1 and received == 1)
	controller:Stop()

	local queue, _, trace = productionQueue("Reduced")
	local snapshots = 0
	local coordinator = ProductionCoordinator.new({
		Reducer = ProductionReducer.new({ Protocol = Protocol }),
		Queue = queue,
		ApplySnapshot = function() snapshots += 1 end,
	})
	coordinator:HandleEnvelope(protocolEnvelope("plain-session", 1, snapshot(0), {}))
	check("plain coordinator republish invokes no ceremony adapter", snapshots == 1 and #trace == 0 and queue:IsIdle())
end

fixtures.stage_c_event_time_strike_and_guides = function()
	local queue, _, trace, pending = productionQueue("Standard", { StrikePending = true })
	queue:Enqueue({
		rawTransition("StepCompleted", {
			Id = "local-fixture:1",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	check(
		"guide stops before event-time copy and strike",
		joined(trace) == "guide:stop | copy:event:2 | strike:start",
		joined(trace)
	)
	pending.Strike("completed")
	check(
		"strike completion reveals latest canonical copy before starting guide",
		joined(trace) == "guide:stop | copy:event:2 | strike:start | copy:current:0 | guide:start",
		joined(trace)
	)
	check(
		"event-time 2/2 is rendered despite latest canonical 0/2",
		queue:IsIdle() and queue.State.Struck["local-fixture:1"] == true
	)
end

fixtures.stage_c_named_signals_and_reserved_manual = function()
	local signals = ProductionSignals.new()
	local queue, scheduler = productionQueue("Standard", nil, signals)
	queue:Enqueue({
		rawTransition("StepCompleted", {
			Id = "signal:1",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureSignal",
		}),
	})
	check("named presentation signal holds the queue", queue.Waiting and queue.Waiting.Name == "FixturePresentationFinished")
	signals:Complete("FixturePresentationFinished")
	check("named presentation signal completion releases the queue", queue:IsIdle())

	local alreadySignals = ProductionSignals.new()
	alreadySignals:Complete("FixturePresentationFinished")
	local already, alreadyScheduler = productionQueue("Standard", nil, alreadySignals)
	already:Enqueue({
		rawTransition("StepCompleted", {
			Id = "signal:already",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureSignal",
		}),
	})
	check("already-completed signal falls back to declared timing profile", already.Waiting and already.Waiting.Name == "TimingProfile")
	alreadyScheduler:FireNext()
	check("already-completed signal fallback cannot strand the queue", already:IsIdle())

	local unavailableSignals = ProductionSignals.new()
	local unavailable = productionQueue("Standard", nil, unavailableSignals)
	unavailable:Enqueue({
		rawTransition("StepCompleted", {
			Id = "signal:unavailable",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureSignal",
		}),
	})
	unavailableSignals:UnavailableSignal("FixturePresentationFinished", "destroyed")
	check("unavailable feature signal releases safely", unavailable:IsIdle())

	local timedSignal, timedSignalScheduler = productionQueue("Standard", nil, ProductionSignals.new())
	timedSignal:Enqueue({
		rawTransition("StepCompleted", {
			Id = "signal:timeout",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureSignal",
		}),
	})
	timedSignalScheduler:FireNext()
	check("missing tween/presentation signal releases on safety timeout", timedSignal:IsIdle())

	local manual = productionQueue("Reduced")
	manual:Enqueue({
		rawTransition("StepCompleted", {
			Id = "manual:reserved",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureManualReserved",
		}),
	})
	check(
		"ManualAcknowledge validates as reserved but is not tutorial runtime",
		manual:IsIdle() and manual.Diagnostics[#manual.Diagnostics].Kind == "ManualAcknowledgeUnsupported"
	)
end

fixtures.stage_c_missing_cancelled_and_timeout_targets = function()
	local missing = productionQueue("Standard", { StrikeMissing = true, GuideMissing = true })
	missing:Enqueue({
		rawTransition("StepCompleted", {
			Id = "missing:targets",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	check("missing strike/guide targets cannot strand queue", missing:IsIdle())

	local destroyed = productionQueue("Standard", { StrikeThrows = true })
	destroyed:Enqueue({
		rawTransition("StepCompleted", {
			Id = "destroyed:target",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	check("destroyed visual target failure cannot strand queue", destroyed:IsIdle())

	local cancelled = productionQueue("Standard", { StrikePending = true })
	cancelled:Enqueue({
		rawTransition("StepCompleted", {
			Id = "cancelled:strike",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	cancelled:CancelCurrent("target-destroyed")
	check("cancelled visual completion releases queue", cancelled:IsIdle() and cancelled.State.Struck["cancelled:strike"])

	local timed, scheduler = productionQueue("Standard", { StrikePending = true })
	timed:Enqueue({
		rawTransition("StepCompleted", {
			Id = "timeout:strike",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	scheduler:FireNext()
	check("bounded safety timeout releases stalled visual", timed:IsIdle() and timed.State.Struck["timeout:strike"])

	local guideCancelled = productionQueue("Standard", { GuidePending = true })
	guideCancelled:Enqueue({
		rawTransition("StepCompleted", {
			Id = "cancelled:guide",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	guideCancelled:CancelCurrent("guide-destroyed")
	check("cancelled guide target cannot strand queue", guideCancelled:IsIdle())

	local guideTimed, guideScheduler = productionQueue("Standard", { GuidePending = true })
	guideTimed:Enqueue({
		rawTransition("StepCompleted", {
			Id = "timeout:guide",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
		}),
	})
	guideScheduler:FireNext()
	check("stalled guide target releases on safety timeout", guideTimed:IsIdle())
end

local function completion(instanceId, slotId)
	return rawTransition("QuestCompleted", {
		Id = instanceId .. ":complete",
		DefinitionId = string.gsub(instanceId, "^onetime:", ""),
		QuestId = string.gsub(instanceId, "^onetime:", ""),
		InstanceId = instanceId,
		RewardSlotIds = { slotId },
		PresentationPolicy = "TutorialCompletion",
	})
end

local function reward(instanceId, slotId, amount)
	return rawTransition("RewardGranted", {
		Id = instanceId .. ":reward:" .. slotId,
		DefinitionId = string.gsub(instanceId, "^onetime:", ""),
		QuestId = string.gsub(instanceId, "^onetime:", ""),
		InstanceId = instanceId,
		RewardSlotId = slotId,
		RewardKind = "Gems",
		Projection = { Amount = amount },
	})
end

fixtures.stage_c_reward_correlation_and_cascades = function()
	local queue, _, trace, pending = productionQueue("Standard", { RewardPending = true })
	queue:Enqueue({
		completion("onetime:q1", "q1_gems"),
		reward("onetime:q1", "q1_gems", 10),
		completion("onetime:q2", "q2_gems"),
		reward("onetime:q2", "q2_gems", 0),
	})
	check("first correlated reward holds cascade presentation", pending.Reward ~= nil and not queue:IsIdle())
	pending.Reward("completed")
	check(
		"cascade rewards are sequential and zero-value skips flight",
		queue:IsIdle()
			and joined(queue.State.PresentedRewards) == "onetime:q1/q1_gems | onetime:q2/q2_gems"
			and queue.State.CompletionSignals["onetime:q1"]
			and queue.State.CompletionSignals["onetime:q2"],
		joined(trace)
	)
	local q1End, q2Begin
	for index, item in ipairs(trace) do
		if item == "completion:end:onetime:q1" then q1End = index end
		if item == "completion:begin:onetime:q2" then q2Begin = index end
	end
	check("second completion begins only after first correlated reward ends", q1End and q2Begin and q1End < q2Begin)

	local missing = productionQueue("Standard", { RewardMissing = true })
	missing:Enqueue({ completion("onetime:missing", "gems"), reward("onetime:missing", "gems", 5) })
	check(
		"missing reward destination uses safe adapter fallback without stalling",
		missing:IsIdle() and missing.State.CompletionSignals["onetime:missing"]
	)

	local cancelled = productionQueue("Standard", { RewardPending = true })
	cancelled:Enqueue({ completion("onetime:cancelled_reward", "gems"), reward("onetime:cancelled_reward", "gems", 5) })
	cancelled:CancelCurrent("reward-target-destroyed")
	check(
		"cancelled reward target releases correlated completion",
		cancelled:IsIdle() and cancelled.State.CompletionSignals["onetime:cancelled_reward"]
	)

	local destroyed = productionQueue("Standard", { RewardThrows = true })
	destroyed:Enqueue({ completion("onetime:destroyed_reward", "gems"), reward("onetime:destroyed_reward", "gems", 5) })
	check(
		"destroyed reward target failure cannot strand completion",
		destroyed:IsIdle() and destroyed.State.CompletionSignals["onetime:destroyed_reward"]
	)

	local missingTransition, missingTransitionScheduler = productionQueue("Standard")
	missingTransition:Enqueue({ completion("onetime:dropped_reward_transition", "gems") })
	check("missing correlated reward transition leaves only a bounded hold", not missingTransition:IsIdle())
	missingTransitionScheduler:FireNext()
	check(
		"bounded completion hold releases after outbox/presentation loss",
		missingTransition:IsIdle() and missingTransition.State.CompletionSignals["onetime:dropped_reward_transition"]
	)
end

fixtures.stage_c_local_and_passive_presentation = function()
	local queue, _, trace = productionQueue("Reduced")
	local beforeAuthority = queue.State.AuthorityMutations
	local accepted = queue:EnqueueLocal({
		Kind = "LocalPresentationMilestone",
		PresentationOnly = true,
		LocalId = "rubble:5",
		InstanceId = "onetime:local_q:v1",
		DefinitionId = "local_q",
		StepId = "rubble",
		StepIndex = 1,
		Projection = { Current = 5, Target = 5, Phase = "LocalComplete" },
		PresentationPolicy = "FixtureImmediateStrike",
	})
	check(
		"explicit rubble milestone enters queue but remains non-authoritative",
		accepted and queue:IsIdle() and queue.State.AuthorityMutations == beforeAuthority
			and joined(trace):find("copy:event:5", 1, true) ~= nil
	)
	local traceCount = #trace
	local duplicate = queue:EnqueueLocal({
		Kind = "LocalPresentationMilestone",
		PresentationOnly = true,
		LocalId = "rubble:5",
		InstanceId = "onetime:local_q:v1",
		DefinitionId = "local_q",
		StepId = "rubble",
		StepIndex = 1,
		Projection = { Current = 5, Target = 5, Phase = "LocalComplete" },
	})
	check("bounded local milestone identity animates at most once", not duplicate and #trace == traceCount)

	local passiveQueue, _, passiveTrace = productionQueue("Reduced")
	local selectedBefore = passiveQueue.Snapshot.SelectedInstanceId
	passiveQueue:Enqueue({
		rawTransition("StepCompleted", {
			Id = "passive:untracked",
			InstanceId = "onetime:background_q:v1",
			DefinitionId = "background_q",
			QuestId = "background_q",
			StepId = "background_step",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 1, Target = 1, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "FixtureImmediateStrike",
			PresentationMode = "Passive",
			PassivePolicy = "PassiveToast",
		}),
	})
	check(
		"untracked one-time progress uses passive surface without hijacking selected card",
		passiveQueue:IsIdle()
			and passiveQueue.Snapshot.SelectedInstanceId == selectedBefore
			and joined(passiveTrace) == "passive:onetime:background_q:v1"
	)
end

fixtures.stage_c_standard_reduced_logical_equivalence = function()
	local transitions = {
		rawTransition("StepCompleted", {
			Id = "motion:step",
			StepId = "fixture_outgoing",
			StepIndex = 1,
			Projection = { Satisfied = true, Current = 2, Target = 2, Phase = "Satisfied", Tokens = {} },
			PresentationPolicy = "TutorialStrikeThenReveal",
		}),
		completion("onetime:motion", "motion_gems"),
		reward("onetime:motion", "motion_gems", 5),
	}
	local standard, standardScheduler = productionQueue("Standard")
	standard:Enqueue(transitions)
	standardScheduler:Drain(standard)
	local reduced, reducedScheduler = productionQueue("Reduced")
	reduced:Enqueue(transitions)
	reducedScheduler:Drain(reduced)
	local a, b = standard:LogicalState(), reduced:LogicalState()
	check(
		"Standard and Reduced Motion reach identical logical final state",
		a.CurrentProjection.Current == b.CurrentProjection.Current
			and a.ActiveGuide == b.ActiveGuide
			and joined(a.PresentedRewards) == joined(b.PresentedRewards)
			and a.CompletionSignals["onetime:motion"] == b.CompletionSignals["onetime:motion"]
			and a.Struck["motion:step"] == b.Struck["motion:step"]
	)
end

for name, fixture in pairs(fixtures) do
	print("\n" .. name)
	fixture()
end

print(("\n%d failure(s)"):format(failures))
if failures > 0 then
	os.exit(1)
end
