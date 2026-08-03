-- Registration-driven domain router with per-player interests and serialized turns.

local QuestEventRouter = {}
QuestEventRouter.__index = QuestEventRouter

local FULL_REASONS = {
	Setup = true,
	Reset = true,
	ContentVersionChanged = true,
	DeveloperCheck = true,
}

local function append(target, source)
	for _, value in ipairs(source or {}) do
		table.insert(target, value)
	end
end

function QuestEventRouter.new(config)
	assert(type(config) == "table", "QuestEventRouter config required")
	for _, key in ipairs({
		"Content",
		"DomainEvents",
		"Engine",
		"LoadContext",
		"SaveContext",
		"BuildFacts",
		"EffectRunner",
	}) do
		assert(config[key] ~= nil, "QuestEventRouter missing " .. key)
	end
	return setmetatable({
		Content = config.Content,
		DomainEvents = config.DomainEvents,
		Engine = config.Engine,
		LoadContext = config.LoadContext,
		SaveContext = config.SaveContext,
		BuildFacts = config.BuildFacts,
		EffectRunner = config.EffectRunner,
		InterestByPlayer = setmetatable({}, { __mode = "k" }),
		SessionByPlayer = setmetatable({}, { __mode = "k" }),
		QueueByPlayer = setmetatable({}, { __mode = "k" }),
		Measurements = {
			DomainNotifications = 0,
			FullReconciliations = 0,
			EarlyInterestRejections = 0,
			ContextLoads = 0,
			SerializedTurns = 0,
			UncommittedRejections = 0,
		},
	}, QuestEventRouter)
end

function QuestEventRouter:_settleEffects(player, context, state, session, facts, cause, transitions, effects)
	local failedReward = false
	local maxPasses = #self.Content.Definitions * 2 + 4
	local nextTransitions, nextEffects
	for _ = 1, maxPasses do
		local followups = {}
		for _, effect in ipairs(effects) do
			local succeeded
			state, session, nextTransitions, nextEffects, succeeded =
				self.EffectRunner:Execute(player, self.Content, state, session, effect, cause)
			append(transitions, nextTransitions)
			append(followups, nextEffects)
			if effect.Kind == "RewardGrant" and not succeeded then
				failedReward = true
			end
		end
		if failedReward then
			return state, session, facts
		end
		context.State = state
		facts = self.BuildFacts(player, context, cause)
		state, session, nextTransitions, nextEffects = self.Engine.reduce(
			self.Content,
			state,
			facts,
			{ Kind = "FullReconcile", Timestamp = cause.Timestamp },
			session
		)
		append(transitions, nextTransitions)
		append(followups, nextEffects)
		if #followups == 0 then
			return state, session, facts
		end
		effects = followups
	end
	error("QuestEventRouter: effect cascade exceeded its bound", 2)
end

function QuestEventRouter:_runTurn(player, cause, reason)
	self.Measurements.ContextLoads += 1
	self.Measurements.SerializedTurns += 1
	local context = self.LoadContext(player, reason)
	if type(context) ~= "table" or type(context.State) ~= "table" then
		return false
	end
	local facts = self.BuildFacts(player, context, cause)
	if type(facts) ~= "table" then
		return false
	end
	local session = self.SessionByPlayer[player] or {}
	local state, nextSession, transitions, effects, interests =
		self.Engine.reduce(self.Content, context.State, facts, cause, session)
	state, nextSession, facts = self:_settleEffects(
		player,
		context,
		state,
		nextSession,
		facts,
		cause,
		transitions,
		effects
	)
	interests = self.Engine.Interests(self.Content, state, facts)
	context.State = state
	self.SaveContext(player, context, transitions, reason)
	self.EffectRunner:UpdateClock(player, self.Content, state)
	self.SessionByPlayer[player] = nextSession
	self.InterestByPlayer[player] = interests
	return true
end

function QuestEventRouter:_enqueue(player, item)
	local queue = self.QueueByPlayer[player]
	if not queue then
		queue = { Items = {}, Draining = false }
		self.QueueByPlayer[player] = queue
	end
	table.insert(queue.Items, item)
	if queue.Draining then
		return true
	end
	queue.Draining = true
	local allSucceeded = true
	while #queue.Items > 0 do
		local nextItem = table.remove(queue.Items, 1)
		if not self:_runTurn(player, nextItem.Cause, nextItem.Reason) then
			allSucceeded = false
		end
	end
	queue.Draining = false
	return allSucceeded
end

function QuestEventRouter:NotifyDomain(player, kind, payload, timestamp)
	local event, problem = self.DomainEvents.Validate(kind, payload, timestamp)
	if not event then
		return false, problem
	end
	self.Measurements.DomainNotifications += 1
	if not self.DomainEvents.IsCommitted(event) then
		self.Measurements.UncommittedRejections += 1
		return false, "uncommitted transaction state"
	end
	local interests = self.InterestByPlayer[player]
	if not interests or interests[kind] ~= true or self.Content.TriggerIndex[kind] == nil then
		self.Measurements.EarlyInterestRejections += 1
		return false, "uninterested"
	end
	return self:_enqueue(player, { Cause = event, Reason = "Incremental" })
end

function QuestEventRouter:Reconcile(player, reason, timestamp)
	if not FULL_REASONS[reason] then
		return false, "invalid full reconciliation reason"
	end
	if type(timestamp) ~= "number" or timestamp ~= timestamp or timestamp == math.huge or timestamp == -math.huge then
		return false, "invalid reconciliation timestamp"
	end
	self.Measurements.FullReconciliations += 1
	return self:_enqueue(player, {
		Cause = { Kind = "FullReconcile", Timestamp = timestamp },
		Reason = reason,
	})
end

function QuestEventRouter:SetupPlayer(player, timestamp)
	return self:Reconcile(player, "Setup", timestamp)
end

function QuestEventRouter:ResetPlayer(player, timestamp)
	return self:Reconcile(player, "Reset", timestamp)
end

function QuestEventRouter:ContentVersionChanged(player, timestamp)
	return self:Reconcile(player, "ContentVersionChanged", timestamp)
end

function QuestEventRouter:DeveloperCheck(player, timestamp)
	return self:Reconcile(player, "DeveloperCheck", timestamp)
end

function QuestEventRouter:ClearPlayer(player)
	self.InterestByPlayer[player] = nil
	self.SessionByPlayer[player] = nil
	self.QueueByPlayer[player] = nil
	self.EffectRunner:ClearPlayer(player)
end

function QuestEventRouter:GetMeasurements()
	local result = {}
	for key, value in pairs(self.Measurements) do
		result[key] = value
	end
	return result
end

return QuestEventRouter
