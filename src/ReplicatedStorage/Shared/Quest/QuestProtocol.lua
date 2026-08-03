-- Protocol v2 is the only wire contract for the universal quest replacement.
-- This module is pure: server code builds sanitized snapshots and stamped envelopes;
-- client code validates the same closed shapes before reducing them.

local QuestProtocol = {}

QuestProtocol.Version = 2

local LIMITS = {
	Arcs = 32,
	Instances = 128,
	RewardsPerInstance = 8,
	TransitionsPerEnvelope = 256,
	ProjectionDepth = 6,
	ProjectionEntries = 64,
}

local SUPPORTED_TRANSITIONS = {
	QuestUnlocked = true,
	StepMilestoneReached = true,
	StepCompleted = true,
	QuestCompleted = true,
	ArcCompleted = true,
	RewardGranted = true,
}

-- Reserved names are deliberately recognized and rejected. They cannot appear to
-- partially work before the post-launch lifecycle runtime exists.
local RESERVED_TRANSITIONS = {
	QuestExpired = true,
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
	return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function identifier(value: any, maximum: number?): boolean
	if type(value) ~= "string" then
		return false
	end
	return #value > 0
		and #value <= (maximum or 160)
		and string.match(value, "^[%w_:%-%.]+$") ~= nil
end

local function shortString(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= 256
end

local function exactKeys(value, allowed, label)
	if type(value) ~= "table" then
		return false, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, label .. " has unknown field " .. tostring(key)
		end
	end
	return true
end

local function denseArray(value, maximum, label)
	if type(value) ~= "table" then
		return false, label .. " must be an array"
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false, label .. " must be a dense array"
		end
		count += 1
	end
	if count ~= #value or count > maximum then
		return false, label .. " is outside its size bound"
	end
	return true
end

local function cloneProjection(value, depth, budget)
	depth = depth or 0
	budget = budget or { Count = 0 }
	local valueType = type(value)
	if valueType == "nil" or valueType == "boolean" then
		return value
	end
	if valueType == "number" then
		if not finite(value) then
			return nil, "projection contains a non-finite number"
		end
		return value
	end
	if valueType == "string" then
		if #value > 256 then
			return nil, "projection string is too long"
		end
		return value
	end
	if valueType ~= "table" or depth >= LIMITS.ProjectionDepth then
		return nil, "projection contains an unsupported or deeply nested value"
	end
	local result = {}
	for key, child in pairs(value) do
		budget.Count += 1
		if budget.Count > LIMITS.ProjectionEntries then
			return nil, "projection is outside its size bound"
		end
		if type(key) ~= "string" and (type(key) ~= "number" or key % 1 ~= 0 or key < 1) then
			return nil, "projection contains an invalid key"
		end
		if type(key) == "string" then
			local lowered = string.lower(key)
			if lowered == "key"
				or lowered == "text"
				or lowered == "copy"
				or lowered == "title"
				or string.find(lowered, "receipt", 1, true)
				or string.find(lowered, "prose", 1, true)
				or string.find(lowered, "description", 1, true)
				or string.find(lowered, "fallback", 1, true)
				or string.find(lowered, "localized", 1, true)
			then
				return nil, "projection contains a private or prose field"
			end
		end
		local cloned, problem = cloneProjection(child, depth + 1, budget)
		if problem then
			return nil, problem
		end
		result[key] = cloned
	end
	return result
end

local function deepClone(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in pairs(value) do
		result[deepClone(key)] = deepClone(child)
	end
	return result
end

local function objectiveProjection(content, definition, step, state, facts, forceSatisfied)
	local byInstance = state.ObjectiveProgress[definition.InstanceId]
	local progress = type(byInstance) == "table" and byInstance[step.Id] or {}
	local result, rank = content.Objectives.Evaluate(step.Objective, facts or {}, progress or {})
	if not result then
		return nil, rank
	end
	local instance = state.Instances[definition.InstanceId]
	local highWater = instance and instance.PhaseRanks and instance.PhaseRanks[step.Id]
	if highWater and highWater > rank then
		local objective = content.Objectives.Get(step.Objective.Kind)
		result.Phase = objective.Phases[highWater]
	end
	if forceSatisfied then
		result.Satisfied = true
	end
	return cloneProjection(result)
end

local function rewardProjection(content, reward)
	if type(content.Rewards.Project) ~= "function" then
		return nil, "reward registry has no public projection boundary"
	end
	local projected, problem = content.Rewards.Project(reward)
	if not projected then
		return nil, problem
	end
	return cloneProjection(projected)
end

function QuestProtocol.BuildSnapshot(content, state, facts)
	if type(content) ~= "table" or type(state) ~= "table" or type(facts) ~= "table" then
		return nil, "snapshot construction needs content, state, and facts"
	end
	local snapshot = {
		QuestStateSchemaVersion = state.SchemaVersion,
		ContentVersion = state.ContentVersion,
		SelectedInstanceId = state.SelectedInstanceId,
		HideCompleted = state.HideCompleted == true,
		Arcs = {},
		Instances = {},
	}
	for _, arc in ipairs(content.Arcs) do
		local instanceIds = {}
		local completedCount = 0
		for _, definitionId in ipairs(arc.QuestIds) do
			local definition = content.DefinitionsById[definitionId]
			local instance = definition and state.Instances[definition.InstanceId]
			if instance then
				table.insert(instanceIds, instance.InstanceId)
				if instance.Completed then
					completedCount += 1
				end
			end
		end
		table.insert(snapshot.Arcs, {
			ArcId = arc.Id,
			Completed = state.CompletedArcIds[arc.Id] == true,
			CompletedQuestCount = completedCount,
			DisplayQuestCount = arc.DisplayQuestCount,
			InstanceIds = instanceIds,
		})
	end
	for _, definition in ipairs(content.Definitions) do
		local instance = state.Instances[definition.InstanceId]
		if instance then
			local stepIndex = math.min(instance.StepIndex, #definition.Steps)
			local step = definition.Steps[stepIndex]
			local projection, problem = objectiveProjection(
				content,
				definition,
				step,
				state,
				facts,
				instance.Completed or instance.StepIndex > stepIndex
			)
			if not projection then
				return nil, "objective projection failed: " .. tostring(problem)
			end
			local rewards = {}
			for _, reward in ipairs(definition.Rewards) do
				local public, rewardProblem = rewardProjection(content, reward)
				if not public then
					return nil, "reward projection failed: " .. tostring(rewardProblem)
				end
				table.insert(rewards, {
					RewardSlotId = reward.SlotId,
					RewardKind = reward.Kind,
					Granted = state.RewardReceipts[reward.ReceiptId] == true,
					Projection = public,
				})
			end
			table.insert(snapshot.Instances, {
				DefinitionId = definition.Id,
				DefinitionVersion = definition.Version,
				InstanceId = definition.InstanceId,
				QuestId = definition.Id,
				ArcId = definition.ArcId,
				LifecycleKind = definition.Lifecycle.Kind,
				Selected = state.SelectedInstanceId == definition.InstanceId,
				Completed = instance.Completed == true,
				RewardPending = instance.RewardPending == true,
				StepIndex = stepIndex,
				StepCount = #definition.Steps,
				CurrentStep = {
					StepId = step.Id,
					StepIndex = stepIndex,
					Projection = projection,
				},
				Rewards = rewards,
			})
		end
	end
	local ok, problem = QuestProtocol.ValidateSnapshot(snapshot)
	if not ok then
		return nil, problem
	end
	return snapshot
end

local function validateProjection(value, label)
	local cloned, problem = cloneProjection(value)
	if not cloned then
		return false, label .. ": " .. tostring(problem)
	end
	return true
end

local function validateObjectiveProjection(value, label)
	local ok, problem = exactKeys(value, {
		Satisfied = true,
		Current = true,
		Target = true,
		ProgressFraction = true,
		Phase = true,
		Tokens = true,
	}, label)
	if not ok then
		return false, problem
	end
	if type(value.Satisfied) ~= "boolean" or not shortString(value.Phase)
		or value.Current ~= nil and not finite(value.Current)
		or value.Target ~= nil and not finite(value.Target)
		or value.ProgressFraction ~= nil
			and (not finite(value.ProgressFraction) or value.ProgressFraction < 0 or value.ProgressFraction > 1)
		or type(value.Tokens) ~= "table"
	then
		return false, label .. " has invalid objective fields"
	end
	local tokenCount = 0
	for key, token in pairs(value.Tokens) do
		tokenCount += 1
		if tokenCount > 16 or not identifier(key, 96)
			or not ({ string = true, number = true, boolean = true })[type(token)]
			or type(token) == "number" and not finite(token)
			or type(token) == "string" and #token > 256
		then
			return false, label .. " has invalid tokens"
		end
	end
	return validateProjection(value, label)
end

function QuestProtocol.ValidateSnapshot(snapshot)
	local ok, problem = exactKeys(snapshot, {
		QuestStateSchemaVersion = true,
		ContentVersion = true,
		SelectedInstanceId = true,
		HideCompleted = true,
		Arcs = true,
		Instances = true,
	}, "snapshot")
	if not ok then
		return false, problem
	end
	if not integer(snapshot.QuestStateSchemaVersion, 1, 1000000)
		or not integer(snapshot.ContentVersion, 1, 1000000)
		or snapshot.SelectedInstanceId ~= nil and not identifier(snapshot.SelectedInstanceId)
		or type(snapshot.HideCompleted) ~= "boolean"
	then
		return false, "snapshot has invalid header fields"
	end
	ok, problem = denseArray(snapshot.Arcs, LIMITS.Arcs, "snapshot arcs")
	if not ok then
		return false, problem
	end
	ok, problem = denseArray(snapshot.Instances, LIMITS.Instances, "snapshot instances")
	if not ok then
		return false, problem
	end
	local knownInstances = {}
	local arcByInstance = {}
	local selectedCount = 0
	local selectedIdentity
	for _, arc in ipairs(snapshot.Arcs) do
		ok, problem = exactKeys(arc, {
			ArcId = true,
			Completed = true,
			CompletedQuestCount = true,
			DisplayQuestCount = true,
			InstanceIds = true,
		}, "snapshot arc")
		if not ok then
			return false, problem
		end
		ok, problem = denseArray(arc.InstanceIds, LIMITS.Instances, "arc instance IDs")
		if not ok or not identifier(arc.ArcId) or type(arc.Completed) ~= "boolean"
			or not integer(arc.CompletedQuestCount, 0, LIMITS.Instances)
			or not integer(arc.DisplayQuestCount, 0, LIMITS.Instances)
		then
			return false, problem or "snapshot arc has invalid fields"
		end
		for _, instanceIdentity in ipairs(arc.InstanceIds) do
			if not identifier(instanceIdentity) or arcByInstance[instanceIdentity] then
				return false, "snapshot arc has an invalid instance ID"
			end
			arcByInstance[instanceIdentity] = arc.ArcId
		end
	end
	for _, instance in ipairs(snapshot.Instances) do
		ok, problem = exactKeys(instance, {
			DefinitionId = true,
			DefinitionVersion = true,
			InstanceId = true,
			QuestId = true,
			ArcId = true,
			LifecycleKind = true,
			Selected = true,
			Completed = true,
			RewardPending = true,
			StepIndex = true,
			StepCount = true,
			CurrentStep = true,
			Rewards = true,
		}, "snapshot instance")
		if not ok then
			return false, problem
		end
		if not identifier(instance.DefinitionId) or not integer(instance.DefinitionVersion, 1, 1000000)
			or not identifier(instance.InstanceId) or instance.QuestId ~= instance.DefinitionId
			or not identifier(instance.ArcId) or instance.LifecycleKind ~= "OneTime"
			or type(instance.Selected) ~= "boolean" or type(instance.Completed) ~= "boolean"
			or type(instance.RewardPending) ~= "boolean"
			or not integer(instance.StepCount, 1, 32)
			or not integer(instance.StepIndex, 1, instance.StepCount)
		then
			return false, "snapshot instance has invalid identity or progression"
		end
		if knownInstances[instance.InstanceId] then
			return false, "snapshot repeats an instance"
		end
		knownInstances[instance.InstanceId] = true
		if arcByInstance[instance.InstanceId] ~= instance.ArcId then
			return false, "snapshot instance/arc membership disagrees"
		end
		if instance.Selected then
			selectedCount += 1
			selectedIdentity = instance.InstanceId
		end
		ok, problem = exactKeys(instance.CurrentStep, { StepId = true, StepIndex = true, Projection = true }, "current step")
		if not ok or not identifier(instance.CurrentStep.StepId)
			or instance.CurrentStep.StepIndex ~= instance.StepIndex
		then
			return false, problem or "snapshot current step is invalid"
		end
		ok, problem = validateObjectiveProjection(instance.CurrentStep.Projection, "current step projection")
		if not ok then
			return false, problem
		end
		ok, problem = denseArray(instance.Rewards, LIMITS.RewardsPerInstance, "snapshot rewards")
		if not ok then
			return false, problem
		end
		local slots = {}
		for _, reward in ipairs(instance.Rewards) do
			ok, problem = exactKeys(reward, {
				RewardSlotId = true,
				RewardKind = true,
				Granted = true,
				Projection = true,
			}, "snapshot reward")
			if not ok or not identifier(reward.RewardSlotId) or slots[reward.RewardSlotId]
				or not shortString(reward.RewardKind) or type(reward.Granted) ~= "boolean"
			then
				return false, problem or "snapshot reward is invalid"
			end
			slots[reward.RewardSlotId] = true
			ok, problem = validateProjection(reward.Projection, "reward projection")
			if not ok then
				return false, problem
			end
		end
	end
	if snapshot.SelectedInstanceId ~= nil and not knownInstances[snapshot.SelectedInstanceId] then
		return false, "snapshot selection names an unknown instance"
	end
	for instanceIdentity in pairs(arcByInstance) do
		if not knownInstances[instanceIdentity] then
			return false, "snapshot arc names an unknown instance"
		end
	end
	if selectedCount > 1 or snapshot.SelectedInstanceId ~= selectedIdentity then
		return false, "snapshot selection fields disagree"
	end
	return true
end

local TRANSITION_FIELDS = {
	Id = true,
	SessionId = true,
	Revision = true,
	Ordinal = true,
	Kind = true,
	DefinitionId = true,
	DefinitionVersion = true,
	InstanceId = true,
	QuestId = true,
	ArcId = true,
	StepId = true,
	StepIndex = true,
	MilestoneId = true,
	RewardSlotId = true,
	RewardKind = true,
	RewardSlotIds = true,
	CauseTimestamp = true,
	Projection = true,
	PresentationPolicy = true,
	PassivePolicy = true,
	PresentationMode = true,
}

function QuestProtocol.ValidateTransition(transition, expectedSessionId)
	local ok, problem = exactKeys(transition, TRANSITION_FIELDS, "transition")
	if not ok then
		return false, problem
	end
	if RESERVED_TRANSITIONS[transition.Kind] then
		return false, "unsupported reserved transition " .. transition.Kind
	end
	if not SUPPORTED_TRANSITIONS[transition.Kind] then
		return false, "unknown transition " .. tostring(transition.Kind)
	end
	if not identifier(transition.Id, 320) or not identifier(transition.SessionId, 160)
		or expectedSessionId and transition.SessionId ~= expectedSessionId
		or not integer(transition.Revision, 1, 9007199254740991)
		or not integer(transition.Ordinal, 1, LIMITS.TransitionsPerEnvelope)
		or not identifier(transition.DefinitionId)
		or not integer(transition.DefinitionVersion, 1, 1000000)
		or not identifier(transition.InstanceId)
		or transition.QuestId ~= transition.DefinitionId
		or not identifier(transition.ArcId)
		or not finite(transition.CauseTimestamp) or transition.CauseTimestamp < 0
	then
		return false, "transition has invalid stable identity"
	end
	local expectedId = ("%s:%d:%d"):format(transition.SessionId, transition.Revision, transition.Ordinal)
	if transition.Id ~= expectedId then
		return false, "transition ID does not match session/revision/ordinal"
	end
	if transition.StepId ~= nil and not identifier(transition.StepId) then
		return false, "transition has invalid step ID"
	end
	if transition.StepIndex ~= nil and not integer(transition.StepIndex, 1, 32) then
		return false, "transition has invalid step index"
	end
	if transition.MilestoneId ~= nil and not identifier(transition.MilestoneId) then
		return false, "transition has invalid milestone ID"
	end
	if transition.RewardSlotId ~= nil and not identifier(transition.RewardSlotId) then
		return false, "transition has invalid reward slot ID"
	end
	if transition.RewardKind ~= nil and not shortString(transition.RewardKind) then
		return false, "transition has invalid reward kind"
	end
	if transition.PresentationPolicy ~= nil and not identifier(transition.PresentationPolicy) then
		return false, "transition has invalid presentation policy"
	end
	if transition.PassivePolicy ~= nil and not identifier(transition.PassivePolicy) then
		return false, "transition has invalid passive policy"
	end
	if transition.PresentationMode ~= "Tracked" and transition.PresentationMode ~= "Passive" then
		return false, "transition has invalid presentation mode"
	end
	if transition.RewardSlotIds ~= nil then
		ok, problem = denseArray(transition.RewardSlotIds, LIMITS.RewardsPerInstance, "reward slot IDs")
		if not ok then
			return false, problem
		end
		local seen = {}
		for _, slotId in ipairs(transition.RewardSlotIds) do
			if not identifier(slotId) or seen[slotId] then
				return false, "transition has invalid reward slot list"
			end
			seen[slotId] = true
		end
	end
	if transition.Projection ~= nil then
		ok, problem = validateProjection(transition.Projection, "transition projection")
		if not ok then
			return false, problem
		end
	end
	if transition.Kind == "QuestUnlocked" or transition.Kind == "StepMilestoneReached"
		or transition.Kind == "StepCompleted" or transition.Kind == "QuestCompleted"
	then
		ok, problem = validateObjectiveProjection(transition.Projection, "objective transition projection")
		if not ok then
			return false, problem
		end
	elseif transition.Kind == "ArcCompleted" then
		ok, problem = exactKeys(transition.Projection, {
			CompletedQuestCount = true,
			DisplayQuestCount = true,
		}, "arc transition projection")
		if not ok or not integer(transition.Projection.CompletedQuestCount, 0, 128)
			or not integer(transition.Projection.DisplayQuestCount, 0, 128)
		then
			return false, problem or "arc transition projection is invalid"
		end
	end
	if transition.Kind == "QuestUnlocked" and (not transition.StepId or not transition.Projection) then
		return false, "QuestUnlocked needs current step projection"
	elseif transition.Kind == "StepMilestoneReached"
		and (not transition.StepId or not transition.MilestoneId or not transition.Projection)
	then
		return false, "StepMilestoneReached needs step, milestone, and projection"
	elseif transition.Kind == "StepCompleted"
		and (not transition.StepId or not transition.StepIndex or not transition.Projection)
	then
		return false, "StepCompleted needs step and event-time projection"
	elseif transition.Kind == "QuestCompleted"
		and (transition.RewardSlotIds == nil or not transition.StepId or not transition.StepIndex or not transition.Projection)
	then
		return false, "QuestCompleted needs its final step projection and reward slot identities"
	elseif transition.Kind == "ArcCompleted" and not transition.ArcId then
		return false, "ArcCompleted needs an arc ID"
	elseif transition.Kind == "RewardGranted"
		and (not transition.RewardSlotId or not transition.RewardKind or not transition.Projection)
	then
		return false, "RewardGranted needs reward correlation and projection"
	end
	return true
end

function QuestProtocol.StampTransition(sessionId, revision, ordinal, transition)
	if not identifier(sessionId, 160) or not integer(revision, 1, 9007199254740991)
		or not integer(ordinal, 1, LIMITS.TransitionsPerEnvelope) or type(transition) ~= "table"
	then
		return nil, "invalid transition stamp"
	end
	local stamped = {}
	for key, value in pairs(transition) do
		if not TRANSITION_FIELDS[key] or key == "Id" or key == "SessionId" or key == "Revision" or key == "Ordinal" then
			return nil, "unstamped transition has invalid field " .. tostring(key)
		end
		local cloned, problem = cloneProjection(value)
		if problem then
			return nil, problem
		end
		stamped[key] = cloned
	end
	stamped.SessionId = sessionId
	stamped.Revision = revision
	stamped.Ordinal = ordinal
	stamped.Id = ("%s:%d:%d"):format(sessionId, revision, ordinal)
	local ok, problem = QuestProtocol.ValidateTransition(stamped, sessionId)
	if not ok then
		return nil, problem
	end
	return stamped
end

function QuestProtocol.MakeEnvelope(sessionId, revision, snapshot, transitions)
	if not identifier(sessionId, 160) or not integer(revision, 1, 9007199254740991) then
		return nil, "invalid envelope identity"
	end
	local ok, problem = QuestProtocol.ValidateSnapshot(snapshot)
	if not ok then
		return nil, problem
	end
	ok, problem = denseArray(transitions or {}, LIMITS.TransitionsPerEnvelope, "envelope transitions")
	if not ok then
		return nil, problem
	end
	local copied = {}
	local seenOrdinals = {}
	for index, transition in ipairs(transitions or {}) do
		ok, problem = QuestProtocol.ValidateTransition(transition, sessionId)
		local ordinalIdentity = tostring(transition.Revision) .. ":" .. tostring(transition.Ordinal)
		if not ok or transition.Revision > revision or seenOrdinals[ordinalIdentity] then
			return nil, problem or "envelope repeats a transition ordinal"
		end
		seenOrdinals[ordinalIdentity] = true
		copied[index] = deepClone(transition)
	end
	return {
		ProtocolVersion = QuestProtocol.Version,
		SessionId = sessionId,
		Revision = revision,
		Snapshot = deepClone(snapshot),
		Transitions = copied,
	}
end

function QuestProtocol.ValidateEnvelope(envelope)
	local ok, problem = exactKeys(envelope, {
		ProtocolVersion = true,
		SessionId = true,
		Revision = true,
		Snapshot = true,
		Transitions = true,
	}, "envelope")
	if not ok then
		return false, problem
	end
	if envelope.ProtocolVersion ~= QuestProtocol.Version then
		return false, "unsupported protocol version " .. tostring(envelope.ProtocolVersion)
	end
	if not identifier(envelope.SessionId, 160) or not integer(envelope.Revision, 1, 9007199254740991) then
		return false, "envelope has invalid identity"
	end
	ok, problem = QuestProtocol.ValidateSnapshot(envelope.Snapshot)
	if not ok then
		return false, problem
	end
	ok, problem = denseArray(envelope.Transitions, LIMITS.TransitionsPerEnvelope, "envelope transitions")
	if not ok then
		return false, problem
	end
	local ids = {}
	for _, transition in ipairs(envelope.Transitions) do
		ok, problem = QuestProtocol.ValidateTransition(transition, envelope.SessionId)
		if not ok or transition.Revision > envelope.Revision or ids[transition.Id] then
			return false, problem or "envelope repeats a transition ID"
		end
		ids[transition.Id] = true
	end
	return true
end

function QuestProtocol.ReadyRequest()
	return { ProtocolVersion = QuestProtocol.Version, Kind = "Ready" }
end

function QuestProtocol.ValidateReady(request)
	local ok, problem = exactKeys(request, { ProtocolVersion = true, Kind = true }, "ready request")
	if not ok then
		return false, problem
	end
	return request.ProtocolVersion == QuestProtocol.Version and request.Kind == "Ready", "unsupported ready request"
end

function QuestProtocol.IsSupportedTransition(kind)
	return SUPPORTED_TRANSITIONS[kind] == true
end

function QuestProtocol.IsReservedTransition(kind)
	return RESERVED_TRANSITIONS[kind] == true
end

function QuestProtocol.Clone(value)
	return deepClone(value)
end

return table.freeze(QuestProtocol)
