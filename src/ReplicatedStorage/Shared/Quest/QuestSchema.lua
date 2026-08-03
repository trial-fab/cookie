local PresentationPolicySchema = require(script.Parent.PresentationPolicySchema)
local QuestCopy = require(script.Parent.QuestCopy)

local QuestSchema = {}

QuestSchema.StateSchemaVersion = 1

local LIMITS = {
	Arcs = 32,
	Definitions = 128,
	StepsPerDefinition = 32,
	RewardsPerDefinition = 8,
	DependenciesPerDefinition = 32,
	StateInstances = 128,
	StateReceipts = 2048,
}

local LIFECYCLES = {
	OneTime = true,
	Repeatable = true,
	Daily = true,
	Weekly = true,
	Seasonal = true,
	Event = true,
}

local function fail(message, level)
	error("QuestSchema: " .. message, (level or 1) + 1)
end

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
	return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function stableId(value)
	return type(value) == "string"
		and #value > 0
		and #value <= 64
		and string.match(value, "^[a-z][a-z0-9_%-]*$") ~= nil
		and not string.find(value, "preview", 1, true)
		and not string.find(value, "example", 1, true)
end

local function instanceId(value)
	return type(value) == "string" and #value > 0 and #value <= 160 and string.match(value, "^[%w_:%-%.]+$") ~= nil
end

local function receiptId(value)
	return type(value) == "string" and #value > 0 and #value <= 320 and string.match(value, "^[%w_:%-%.]+$") ~= nil
end

local function exactKeys(value, allowed, label)
	if type(value) ~= "table" then
		fail(label .. " must be a table", 2)
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			fail(label .. " has unknown field " .. tostring(key), 2)
		end
	end
end

local function array(value, maximum, label, allowEmpty)
	if type(value) ~= "table" then
		fail(label .. " must be an array", 2)
	end
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			fail(label .. " must be a dense array", 2)
		end
		count += 1
	end
	if count ~= #value then
		fail(label .. " must be a dense array", 2)
	end
	if count > maximum or (not allowEmpty and count < 1) then
		fail(label .. " is outside its size bound", 2)
	end
	return count
end

local function clone(value, depth)
	depth = depth or 0
	if type(value) ~= "table" then
		return value
	end
	if depth > 12 then
		fail("table nesting is unbounded", 2)
	end
	local result = {}
	for key, child in pairs(value) do
		result[clone(key, depth + 1)] = clone(child, depth + 1)
	end
	return result
end

function QuestSchema.DeriveOneTimeInstanceId(definitionId, definitionVersion)
	if not stableId(definitionId) or not integer(definitionVersion, 1, 1000000) then
		fail("cannot derive invalid instance identity", 2)
	end
	return ("onetime:%s:v%d"):format(definitionId, definitionVersion)
end

function QuestSchema.DeriveRewardReceiptId(definitionId, definitionVersion, questInstanceId, slotId)
	if
		not stableId(definitionId)
		or not integer(definitionVersion, 1, 1000000)
		or not instanceId(questInstanceId)
		or not stableId(slotId)
	then
		fail("cannot derive invalid reward receipt identity", 2)
	end
	return ("reward:v1:%s:v%d:%s:%s"):format(definitionId, definitionVersion, questInstanceId, slotId)
end

function QuestSchema.StepAnalyticsId(questInstanceId, stepId)
	return ("analytics:step:%s:%s"):format(questInstanceId, stepId)
end

function QuestSchema.QuestAnalyticsId(questInstanceId)
	return "analytics:quest:" .. questInstanceId
end

function QuestSchema.RewardAnalyticsId(receiptId)
	return "analytics:reward:" .. receiptId
end

local function validateLocalized(value, label)
	if value == nil then
		return
	end
	exactKeys(value, { Key = true, Fallback = true }, label)
	if
		type(value.Key) ~= "string"
		or #value.Key == 0
		or #value.Key > 160
		or type(value.Fallback) ~= "string"
		or #value.Fallback == 0
		or #value.Fallback > 500
	then
		fail(label .. " has invalid localization", 2)
	end
end

function QuestSchema.ValidateManifest(manifest, objectives, rewards)
	-- Compile a private mutable copy so content modules may safely return frozen data.
	manifest = clone(manifest)
	exactKeys(manifest, {
		ContentVersion = true,
		Arcs = true,
		Definitions = true,
		RetiredRewardReceipts = true,
	}, "manifest")
	if not integer(manifest.ContentVersion, 1, 1000000) then
		fail("invalid content version", 2)
	end
	array(manifest.Arcs, LIMITS.Arcs, "manifest arcs", true)
	array(manifest.Definitions, LIMITS.Definitions, "manifest definitions", true)
	array(manifest.RetiredRewardReceipts or {}, LIMITS.StateReceipts, "retired reward receipts", true)

	local arcsById = {}
	local arcOrder = {}
	local membership = {}
	for index, arc in ipairs(manifest.Arcs) do
		exactKeys(arc, { Id = true, Order = true, QuestIds = true, DisplayQuestCount = true, Title = true, Reward = true }, "arc")
		if not stableId(arc.Id) or arcsById[arc.Id] then
			fail("arc IDs must be unique and stable", 2)
		end
		if arc.Order ~= index then
			fail("arc order must be dense and authored", 2)
		end
		array(arc.QuestIds, LIMITS.Definitions, "arc quest IDs", false)
		if not integer(arc.DisplayQuestCount, #arc.QuestIds, LIMITS.Definitions) then
			fail("invalid display quest count", 2)
		end
		validateLocalized(arc.Title, "arc title")
		if arc.Reward ~= nil then
			exactKeys(arc.Reward, { DefinitionId = true, SlotId = true }, "arc reward")
			if not stableId(arc.Reward.DefinitionId) or not stableId(arc.Reward.SlotId) then
				fail("arc reward has invalid identity", 2)
			end
		end
		arcsById[arc.Id] = arc
		table.insert(arcOrder, arc)
		for questOrder, definitionId in ipairs(arc.QuestIds) do
			if not stableId(definitionId) or membership[definitionId] then
				fail("invalid or duplicate arc membership", 2)
			end
			membership[definitionId] = { ArcId = arc.Id, Order = questOrder }
		end
	end

	local definitionsById = {}
	local ordered = {}
	local stepIds = {}
	local rewardSlotIds = {}
	local rewardReceipts = {}
	local triggerIndex = {}
	local dependencyGraph = {}
	local acceptedAnalyticsIds = {}

	for index, definition in ipairs(manifest.Definitions) do
		exactKeys(definition, {
			Id = true,
			Version = true,
			ArcId = true,
			Order = true,
			Lifecycle = true,
			RequiresDefinitionIds = true,
			Steps = true,
			Rewards = true,
			Title = true,
			Lesson = true,
			Replay = true,
			Help = true,
			Presentation = true,
		}, "definition")
		if not stableId(definition.Id) or definitionsById[definition.Id] then
			fail("definition IDs must be unique and stable", 2)
		end
		if not integer(definition.Version, 1, 1000000) then
			fail("invalid definition version", 2)
		end
		if definition.Order ~= index then
			fail("definition order must be dense and authored", 2)
		end
		local member = membership[definition.Id]
		if not member or member.ArcId ~= definition.ArcId then
			fail("definition arc membership mismatch", 2)
		end
		exactKeys(definition.Lifecycle, { Kind = true }, "lifecycle")
		if not LIFECYCLES[definition.Lifecycle.Kind] then
			fail("unknown lifecycle kind", 2)
		end
		if definition.Lifecycle.Kind ~= "OneTime" then
			fail("unsupported launch lifecycle " .. definition.Lifecycle.Kind, 2)
		end
		array(definition.RequiresDefinitionIds or {}, LIMITS.DependenciesPerDefinition, "definition dependencies", true)
		array(definition.Steps, LIMITS.StepsPerDefinition, "definition steps", false)
		array(definition.Rewards, LIMITS.RewardsPerDefinition, "definition rewards", true)
		validateLocalized(definition.Title, "definition title")
		validateLocalized(definition.Lesson, "definition lesson")
		if definition.Help ~= nil then
			exactKeys(definition.Help, { Enabled = true }, "definition help")
			if type(definition.Help.Enabled) ~= "boolean" then
				fail("definition help has invalid Enabled", 2)
			end
		end
		if definition.Replay ~= nil then
			exactKeys(definition.Replay, {
				Enabled = true,
				Terminal = true,
				RewardLabel = true,
				RewardValue = true,
			}, "definition replay")
			if type(definition.Replay.Enabled) ~= "boolean" then
				fail("definition replay has invalid Enabled", 2)
			end
			if definition.Replay.Enabled then
				validateLocalized(definition.Replay.Terminal, "replay terminal")
				validateLocalized(definition.Replay.RewardLabel, "replay reward label")
				validateLocalized(definition.Replay.RewardValue, "replay reward value")
			end
		end
		local ok, problem = PresentationPolicySchema.Validate(definition.Presentation)
		if not ok then
			fail(definition.Id .. " " .. tostring(problem), 2)
		end

		definition.InstanceId = QuestSchema.DeriveOneTimeInstanceId(definition.Id, definition.Version)
		definition.StepById = {}
		for stepIndex, step in ipairs(definition.Steps) do
			exactKeys(step, {
				Id = true,
				Title = true,
				Objective = true,
				Copy = true,
				Presentation = true,
				LocalProgress = true,
			}, "step")
			if not stableId(step.Id) or stepIds[step.Id] then
				fail("step IDs must be globally unique and stable", 2)
			end
			stepIds[step.Id] = true
			local objectiveOk, objectiveProblem = objectives.ValidateObjective(step.Objective)
			if not objectiveOk then
				fail(("step %s: %s"):format(step.Id, tostring(objectiveProblem)), 2)
			end
			validateLocalized(step.Title, "step title")
			local objectiveModule = objectives.Get(step.Objective.Kind)
			local validPhases = {}
			for _, phase in ipairs(objectiveModule.Phases) do validPhases[phase] = true end
			if step.Copy ~= nil then
				local copyOk, copyProblem = QuestCopy.Validate(step.Copy, validPhases)
				if not copyOk then
					fail(("step %s: %s"):format(step.Id, tostring(copyProblem)), 2)
				end
			end
			ok, problem = PresentationPolicySchema.Validate(step.Presentation)
			if not ok then
				fail(step.Id .. " " .. tostring(problem), 2)
			end
			for _, milestone in ipairs(step.Presentation and step.Presentation.Milestones or {}) do
				if not validPhases[milestone.Phase] or milestone.Phase == "Satisfied" then
					fail(step.Id .. " milestone names an invalid objective phase", 2)
				end
			end
			if step.LocalProgress ~= nil then
				exactKeys(step.LocalProgress, {
					Id = true,
					Target = true,
					Card = true,
					Prompt = true,
					CompletionPolicy = true,
				}, "local progress")
				if not stableId(step.LocalProgress.Id)
					or not integer(step.LocalProgress.Target, 1, 1000000)
					or not PresentationPolicySchema.IsStepPolicy(step.LocalProgress.CompletionPolicy)
				then
					fail(step.Id .. " has invalid local progress", 2)
				end
				local localCopyOk, localCopyProblem = QuestCopy.Validate(step.LocalProgress.Prompt, {
					Collecting = true,
					Satisfied = true,
				})
				if not localCopyOk then
					fail(("step %s local prompt: %s"):format(step.Id, tostring(localCopyProblem)), 2)
				end
				localCopyOk, localCopyProblem = QuestCopy.Validate(step.LocalProgress.Card, {
					Collecting = true,
					Satisfied = true,
				})
				if not localCopyOk then
					fail(("step %s local card: %s"):format(step.Id, tostring(localCopyProblem)), 2)
				end
			end
			step.Index = stepIndex
			definition.StepById[step.Id] = step
			acceptedAnalyticsIds[QuestSchema.StepAnalyticsId(definition.InstanceId, step.Id)] = true
			local indexedTriggers = {}
			local captureTriggers = {}
			for _, trigger in ipairs(objectiveModule.ActiveTriggers) do
				indexedTriggers[trigger] = true
			end
			for _, trigger in ipairs(objectiveModule.CaptureTriggers) do
				indexedTriggers[trigger] = true
				captureTriggers[trigger] = true
			end
			for trigger in pairs(indexedTriggers) do
				local entries = triggerIndex[trigger]
				if not entries then
					entries = {}
					triggerIndex[trigger] = entries
				end
				table.insert(entries, {
					DefinitionId = definition.Id,
					InstanceId = definition.InstanceId,
					StepId = step.Id,
					StepIndex = stepIndex,
					ObjectiveKind = objectiveModule.Kind,
					Captures = captureTriggers[trigger] == true,
				})
			end
		end

		definition.RewardBySlotId = {}
		for _, reward in ipairs(definition.Rewards) do
			if not stableId(reward.SlotId) or rewardSlotIds[reward.SlotId] then
				fail("reward slot IDs must be globally unique and stable", 2)
			end
			rewardSlotIds[reward.SlotId] = true
			local rewardOk, rewardProblem = rewards.ValidateReward(reward)
			if not rewardOk then
				fail(("reward %s: %s"):format(reward.SlotId, tostring(rewardProblem)), 2)
			end
			local receipt = QuestSchema.DeriveRewardReceiptId(
				definition.Id,
				definition.Version,
				definition.InstanceId,
				reward.SlotId
			)
			if rewardReceipts[receipt] then
				fail("active reward receipt collision", 2)
			end
			reward.ReceiptId = receipt
			rewardReceipts[receipt] = true
			acceptedAnalyticsIds[QuestSchema.RewardAnalyticsId(receipt)] = true
			definition.RewardBySlotId[reward.SlotId] = reward
		end
		acceptedAnalyticsIds[QuestSchema.QuestAnalyticsId(definition.InstanceId)] = true
		definitionsById[definition.Id] = definition
		ordered[index] = definition
		dependencyGraph[definition.Id] = clone(definition.RequiresDefinitionIds or {})
	end

	for definitionId in pairs(membership) do
		if not definitionsById[definitionId] then
			fail("arc references missing definition " .. definitionId, 2)
		end
	end
	for _, arc in ipairs(arcOrder) do
		if arc.Reward then
			local definition = definitionsById[arc.Reward.DefinitionId]
			if not definition or definition.ArcId ~= arc.Id or not definition.RewardBySlotId[arc.Reward.SlotId] then
				fail("arc reward does not reference a reward in its arc", 2)
			end
		end
	end
	for definitionId, dependencies in pairs(dependencyGraph) do
		local seen = {}
		for _, dependencyId in ipairs(dependencies) do
			if not definitionsById[dependencyId] or dependencyId == definitionId or seen[dependencyId] then
				fail("invalid dependency for " .. definitionId, 2)
			end
			seen[dependencyId] = true
		end
	end
	local visiting, visited = {}, {}
	local function visit(id)
		if visiting[id] then
			fail("definition dependency cycle", 3)
		end
		if visited[id] then
			return
		end
		visiting[id] = true
		for _, dependency in ipairs(dependencyGraph[id]) do
			visit(dependency)
		end
		visiting[id] = nil
		visited[id] = true
	end
	for id in pairs(dependencyGraph) do
		visit(id)
	end
	for definitionId, dependencies in pairs(dependencyGraph) do
		for _, dependencyId in ipairs(dependencies) do
			if definitionsById[dependencyId].Order >= definitionsById[definitionId].Order then
				fail("dependencies must precede dependents", 2)
			end
		end
	end

	local retiredRewardReceipts = {}
	for _, receipt in ipairs(manifest.RetiredRewardReceipts or {}) do
		if not receiptId(receipt) or retiredRewardReceipts[receipt] or rewardReceipts[receipt] then
			fail("retired reward receipt is invalid or collides", 2)
		end
		retiredRewardReceipts[receipt] = true
	end

	return {
		ContentVersion = manifest.ContentVersion,
		Arcs = arcOrder,
		ArcsById = arcsById,
		Definitions = ordered,
		DefinitionsById = definitionsById,
		TriggerIndex = triggerIndex,
		RewardReceipts = rewardReceipts,
		RetiredRewardReceipts = retiredRewardReceipts,
		AcceptedAnalyticsIds = acceptedAnalyticsIds,
		Objectives = objectives,
		Rewards = rewards,
		Limits = LIMITS,
	}
end

function QuestSchema.NewState(content)
	return {
		SchemaVersion = QuestSchema.StateSchemaVersion,
		ContentVersion = content.ContentVersion,
		Instances = {},
		CompletedArcIds = {},
		ObjectiveProgress = {},
		RewardReceipts = {},
		AnalyticsReceipts = {},
		SelectedInstanceId = nil,
		HideCompleted = false,
	}
end

local function boolDictionary(source, allowed, maximum, label)
	if type(source) ~= "table" then
		fail(label .. " must be a table", 2)
	end
	local result, count = {}, 0
	for key, value in pairs(source) do
		count += 1
		if count > maximum or type(key) ~= "string" or value ~= true or not allowed[key] then
			fail(label .. " contains invalid or unbounded data", 2)
		end
		result[key] = true
	end
	return result
end

function QuestSchema.NormalizeState(raw, content)
	if raw == nil then
		return QuestSchema.NewState(content), false
	end
	if type(raw) ~= "table" then
		fail("quest state must be a table", 2)
	end
	exactKeys(raw, {
		SchemaVersion = true,
		ContentVersion = true,
		Instances = true,
		CompletedArcIds = true,
		ObjectiveProgress = true,
		RewardReceipts = true,
		AnalyticsReceipts = true,
		SelectedInstanceId = true,
		HideCompleted = true,
	}, "quest state")
	if raw.SchemaVersion ~= QuestSchema.StateSchemaVersion then
		fail("unknown quest-state schema version", 2)
	end
	if not integer(raw.ContentVersion, 1, 1000000) then
		fail("invalid state content version", 2)
	end
	if type(raw.Instances) ~= "table" or type(raw.ObjectiveProgress) ~= "table" then
		fail("invalid state maps", 2)
	end

	local result = QuestSchema.NewState(content)
	result.CompletedArcIds = boolDictionary(raw.CompletedArcIds, content.ArcsById, LIMITS.Arcs, "completed arcs")
	local instanceCount = 0
	for key, stored in pairs(raw.Instances) do
		instanceCount += 1
		if instanceCount > LIMITS.StateInstances or not instanceId(key) then
			fail("unbounded or invalid instances", 2)
		end
		exactKeys(stored, {
			DefinitionId = true,
			DefinitionVersion = true,
			InstanceId = true,
			StepIndex = true,
			Completed = true,
			RewardPending = true,
			PhaseRanks = true,
		}, "quest instance")
		local definition = content.DefinitionsById[stored.DefinitionId]
		if
			not definition
			or stored.DefinitionVersion ~= definition.Version
			or stored.InstanceId ~= key
			or key ~= definition.InstanceId
		then
			fail("unknown definition version or instance identity", 2)
		end
		if
			not integer(stored.StepIndex, 1, #definition.Steps + 1)
			or type(stored.Completed) ~= "boolean"
			or type(stored.RewardPending) ~= "boolean"
		then
			fail("invalid instance progression", 2)
		end
		if stored.Completed and (stored.StepIndex <= #definition.Steps or stored.RewardPending) then
			fail("inconsistent completed instance", 2)
		end
		local phaseRanks = {}
		if type(stored.PhaseRanks) ~= "table" then
			fail("invalid phase ranks", 2)
		end
		for stepId, rank in pairs(stored.PhaseRanks) do
			local step = definition.StepById[stepId]
			local objectiveModule = step and content.Objectives.Get(step.Objective.Kind)
			if not step or not integer(rank, 1, #objectiveModule.Phases) then
				fail("invalid stored objective phase", 2)
			end
			phaseRanks[stepId] = rank
		end
		result.Instances[key] = {
			DefinitionId = stored.DefinitionId,
			DefinitionVersion = stored.DefinitionVersion,
			InstanceId = key,
			StepIndex = stored.StepIndex,
			Completed = stored.Completed,
			RewardPending = stored.RewardPending,
			PhaseRanks = phaseRanks,
		}
	end

	local progressInstances = 0
	for questInstanceId, progressByStep in pairs(raw.ObjectiveProgress) do
		progressInstances += 1
		if
			progressInstances > LIMITS.StateInstances
			or not instanceId(questInstanceId)
			or type(progressByStep) ~= "table"
		then
			fail("invalid objective progress map", 2)
		end
		local definition
		for _, candidate in ipairs(content.Definitions) do
			if candidate.InstanceId == questInstanceId then
				definition = candidate
				break
			end
		end
		if not definition then
			fail("objective progress names an unknown instance", 2)
		end
		local normalizedByStep, stepCount = {}, 0
		for stepId, progress in pairs(progressByStep) do
			stepCount += 1
			local step = definition.StepById[stepId]
			if stepCount > #definition.Steps or not step then
				fail("objective progress names an unknown step", 2)
			end
			local normalized, problem = content.Objectives.NormalizeProgress(step.Objective, progress)
			if not normalized then
				fail(("invalid objective progress: %s"):format(tostring(problem)), 2)
			end
			normalizedByStep[stepId] = normalized
		end
		result.ObjectiveProgress[questInstanceId] = normalizedByStep
	end

	local acceptedRewards = clone(content.RewardReceipts)
	for receipt in pairs(content.RetiredRewardReceipts) do
		acceptedRewards[receipt] = true
	end
	result.RewardReceipts = boolDictionary(raw.RewardReceipts, acceptedRewards, LIMITS.StateReceipts, "reward receipts")
	result.AnalyticsReceipts =
		boolDictionary(raw.AnalyticsReceipts, content.AcceptedAnalyticsIds, LIMITS.StateReceipts, "analytics receipts")
	if raw.SelectedInstanceId ~= nil then
		if not instanceId(raw.SelectedInstanceId) or not result.Instances[raw.SelectedInstanceId] then
			fail("selected instance is invalid", 2)
		end
		result.SelectedInstanceId = raw.SelectedInstanceId
	end
	if type(raw.HideCompleted) ~= "boolean" then
		fail("HideCompleted must be boolean", 2)
	end
	result.HideCompleted = raw.HideCompleted
	result.ContentVersion = content.ContentVersion
	return result, raw.ContentVersion ~= content.ContentVersion
end

function QuestSchema.CloneState(state)
	return clone(state)
end

function QuestSchema.IsStableId(value)
	return stableId(value)
end

return table.freeze(QuestSchema)
