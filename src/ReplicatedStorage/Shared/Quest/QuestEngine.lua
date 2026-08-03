-- Pure universal quest reducer. All clocks, services, remotes, and side effects live
-- outside this module; callers inject canonical facts and deterministic timestamps.

local QuestSchema = require(script.Parent.QuestSchema)

local QuestEngine = {}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in pairs(value) do
		result[key] = clone(child)
	end
	return result
end

local function transition(kind, definition, step, cause, fields)
	local value = fields or {}
	value.Kind = kind
	value.DefinitionId = definition.Id
	value.DefinitionVersion = definition.Version
	value.InstanceId = definition.InstanceId
	value.QuestId = definition.Id
	value.ArcId = definition.ArcId
	value.StepId = step and step.Id or nil
	value.CauseTimestamp = cause.Timestamp
	value.PassivePolicy = definition.Presentation and definition.Presentation.Passive or "TrackedOnly"
	return value
end

local function stepPresentationPolicy(definition, step)
	return step.Presentation and step.Presentation.StepCompletion
		or definition.Presentation and definition.Presentation.StepCompletion
		or "StandardConcise"
end

local function milestonePresentationPolicy(definition, step, phase)
	for _, milestone in ipairs(step.Presentation and step.Presentation.Milestones or {}) do
		if milestone.Phase == phase then return milestone.Policy end
	end
	return stepPresentationPolicy(definition, step)
end

local function questPresentationPolicy(definition)
	return definition.Presentation and definition.Presentation.QuestCompletion or "StandardCompletion"
end

local function rewardSlotIds(definition)
	local result = {}
	for _, reward in ipairs(definition.Rewards) do
		table.insert(result, reward.SlotId)
	end
	return result
end

local function instanceFor(definition)
	return {
		DefinitionId = definition.Id,
		DefinitionVersion = definition.Version,
		InstanceId = definition.InstanceId,
		StepIndex = 1,
		Completed = false,
		RewardPending = false,
		PhaseRanks = {},
	}
end

local function progressFor(state, definition, step)
	local byStep = state.ObjectiveProgress[definition.InstanceId]
	if not byStep then
		byStep = {}
		state.ObjectiveProgress[definition.InstanceId] = byStep
	end
	local progress = byStep[step.Id]
	if not progress then
		progress = {}
		byStep[step.Id] = progress
	end
	return progress
end

local function completedDefinitions(content, state)
	local result = {}
	for _, definition in ipairs(content.Definitions) do
		local instance = state.Instances[definition.InstanceId]
		if instance and instance.Completed then
			result[definition.Id] = true
		end
	end
	return result
end

local function unlocked(definition, completed)
	for _, dependency in ipairs(definition.RequiresDefinitionIds or {}) do
		if not completed[dependency] then
			return false
		end
	end
	return true
end

local function rewardsGranted(definition, state)
	for _, reward in ipairs(definition.Rewards) do
		if state.RewardReceipts[reward.ReceiptId] ~= true then
			return false
		end
	end
	return true
end

local function addEffect(effects, emitted, effect)
	if not emitted[effect.EffectId] then
		emitted[effect.EffectId] = true
		table.insert(effects, effect)
	end
end

local function flushRewardTransitions(session, questInstanceId, transitions)
	local pendingRewards = session.PendingRewardTransitions or {}
	local stillPending = {}
	for _, pending in ipairs(pendingRewards) do
		if pending.InstanceId == questInstanceId then
			table.insert(transitions, pending)
		else
			table.insert(stillPending, pending)
		end
	end
	session.PendingRewardTransitions = #stillPending > 0 and stillPending or nil
end

local function evaluate(content, definition, instance, step, facts, state)
	local result, phaseRank = content.Objectives.Evaluate(step.Objective, facts, progressFor(state, definition, step))
	if not result then
		error("QuestEngine: objective evaluation failed: " .. tostring(phaseRank), 3)
	end
	local highWater = instance.PhaseRanks[step.Id]
	if highWater and highWater > phaseRank then
		local module = content.Objectives.Get(step.Objective.Kind)
		result = clone(result)
		result.Phase = module.Phases[highWater]
		phaseRank = highWater
	end
	return result, phaseRank
end

local function captureEvent(content, state, cause)
	if cause.Kind == "FullReconcile" then
		return
	end
	for _, entry in ipairs(content.TriggerIndex[cause.Kind] or {}) do
		if entry.Captures then
			local definition = content.DefinitionsById[entry.DefinitionId]
			local instance = state.Instances[definition.InstanceId]
			if not instance or not instance.Completed then
				local step = definition.StepById[entry.StepId]
				local current = progressFor(state, definition, step)
				local captured = content.Objectives.Capture(step.Objective, current, cause)
				local normalized, problem = content.Objectives.NormalizeProgress(step.Objective, captured)
				if not normalized then
					error("QuestEngine: capture returned invalid progress: " .. tostring(problem), 3)
				end
				state.ObjectiveProgress[definition.InstanceId][step.Id] = normalized
			end
		end
	end
end

local function totalSettlementBound(content)
	local total = #content.Definitions + 1
	for _, definition in ipairs(content.Definitions) do
		total += #definition.Steps + #definition.Rewards
	end
	return total
end

local function settle(content, state, facts, cause, session, transitions, effects)
	local emitted = {}
	local bound = totalSettlementBound(content)
	for _ = 1, bound do
		local changed = false
		local completed = completedDefinitions(content, state)
		for _, definition in ipairs(content.Definitions) do
			local instance = state.Instances[definition.InstanceId]
			if not instance and unlocked(definition, completed) then
				instance = instanceFor(definition)
				state.Instances[definition.InstanceId] = instance
				if state.SelectedInstanceId == nil then
					state.SelectedInstanceId = definition.InstanceId
				end
				local firstStep = definition.Steps[1]
				local firstProjection = select(1, evaluate(content, definition, instance, firstStep, facts, state))
				table.insert(transitions, transition("QuestUnlocked", definition, firstStep, cause, {
					Projection = clone(firstProjection),
					StepIndex = 1,
					PresentationPolicy = stepPresentationPolicy(definition, firstStep),
					PresentationMode = state.SelectedInstanceId == definition.InstanceId and "Tracked" or "Passive",
				}))
				changed = true
			end
			if instance and not instance.Completed then
				while instance.StepIndex <= #definition.Steps do
					local step = definition.Steps[instance.StepIndex]
					local result, phaseRank = evaluate(content, definition, instance, step, facts, state)
					local previousPhase = instance.PhaseRanks[step.Id]
					if not previousPhase or phaseRank > previousPhase then
						instance.PhaseRanks[step.Id] = phaseRank
						if previousPhase and not result.Satisfied then
							local outgoingProjection = clone(result)
							local objectiveKind = content.Objectives.Get(step.Objective.Kind)
							outgoingProjection.Phase = objectiveKind.Phases[previousPhase]
							table.insert(
								transitions,
								transition("StepMilestoneReached", definition, step, cause, {
									MilestoneId = step.Id .. ":" .. result.Phase,
									Projection = outgoingProjection,
									PresentationPolicy = milestonePresentationPolicy(definition, step, result.Phase),
									PresentationMode = state.SelectedInstanceId == definition.InstanceId and "Tracked" or "Passive",
								})
							)
						end
					end
					if not result.Satisfied then
						break
					end
					-- The final objective is presented once by QuestCompleted, which
					-- carries the same event-time step identity/projection and then owns
					-- the reward hold. Emitting both transitions caused two competing
					-- strikes around the successor snapshot.
					if instance.StepIndex < #definition.Steps then
						table.insert(
							transitions,
							transition("StepCompleted", definition, step, cause, {
								Projection = clone(result),
								StepIndex = instance.StepIndex,
								PresentationPolicy = stepPresentationPolicy(definition, step),
								PresentationMode = state.SelectedInstanceId == definition.InstanceId and "Tracked" or "Passive",
							})
						)
					else
						-- Reward execution can settle on a later reducer turn, after a
						-- canonical fact (such as spendable currency) has changed. Keep
						-- the event-time final projection in ephemeral session state so
						-- QuestCompleted presents the objective that actually completed.
						session.PendingCompletionProjections = session.PendingCompletionProjections or {}
						session.PendingCompletionProjections[definition.InstanceId] = {
							Projection = clone(result),
							StepId = step.Id,
							StepIndex = instance.StepIndex,
						}
					end
					local analyticsId = QuestSchema.StepAnalyticsId(definition.InstanceId, step.Id)
					if not state.AnalyticsReceipts[analyticsId] then
						addEffect(effects, emitted, {
							Kind = "Analytics",
							AnalyticsKind = "StepCompleted",
							EffectId = analyticsId,
							DefinitionId = definition.Id,
							InstanceId = definition.InstanceId,
							StepId = step.Id,
							CauseTimestamp = cause.Timestamp,
						})
					end
					instance.StepIndex += 1
					changed = true
				end

				if instance.StepIndex > #definition.Steps and not instance.Completed then
					instance.RewardPending = not rewardsGranted(definition, state)
					for _, reward in ipairs(definition.Rewards) do
						if state.RewardReceipts[reward.ReceiptId] ~= true then
							addEffect(effects, emitted, {
								Kind = "RewardGrant",
								EffectId = reward.ReceiptId,
								ReceiptId = reward.ReceiptId,
								DefinitionId = definition.Id,
								DefinitionVersion = definition.Version,
								InstanceId = definition.InstanceId,
								RewardSlotId = reward.SlotId,
								RewardKind = reward.Kind,
								Params = clone(reward.Params),
								CauseTimestamp = cause.Timestamp,
							})
						end
					end
					if rewardsGranted(definition, state) then
						instance.RewardPending = false
						instance.Completed = true
						completed[definition.Id] = true
						local finalStep = definition.Steps[#definition.Steps]
						local pendingCompletion = session.PendingCompletionProjections
							and session.PendingCompletionProjections[definition.InstanceId]
						local finalProjection = pendingCompletion and pendingCompletion.Projection
							or select(1, evaluate(content, definition, instance, finalStep, facts, state))
						table.insert(transitions, transition("QuestCompleted", definition, finalStep, cause, {
							RewardSlotIds = rewardSlotIds(definition),
							StepIndex = pendingCompletion and pendingCompletion.StepIndex or #definition.Steps,
							Projection = clone(finalProjection),
							PresentationPolicy = questPresentationPolicy(definition),
							PresentationMode = state.SelectedInstanceId == definition.InstanceId and "Tracked" or "Passive",
						}))
						if session.PendingCompletionProjections then
							session.PendingCompletionProjections[definition.InstanceId] = nil
							if next(session.PendingCompletionProjections) == nil then
								session.PendingCompletionProjections = nil
							end
						end
						flushRewardTransitions(session, definition.InstanceId, transitions)
						local analyticsId = QuestSchema.QuestAnalyticsId(definition.InstanceId)
						if not state.AnalyticsReceipts[analyticsId] then
							addEffect(effects, emitted, {
								Kind = "Analytics",
								AnalyticsKind = "QuestCompleted",
								EffectId = analyticsId,
								DefinitionId = definition.Id,
								InstanceId = definition.InstanceId,
								CauseTimestamp = cause.Timestamp,
							})
						end
						if state.SelectedInstanceId == definition.InstanceId then
							state.SelectedInstanceId = nil
						end
						changed = true
					end
				end
			end
		end
		for _, arc in ipairs(content.Arcs) do
			if state.CompletedArcIds[arc.Id] ~= true then
				local arcComplete = true
				for _, definitionId in ipairs(arc.QuestIds) do
					local definition = content.DefinitionsById[definitionId]
					local instance = state.Instances[definition.InstanceId]
					if not instance or not instance.Completed then
						arcComplete = false
						break
					end
				end
				if arcComplete then
					state.CompletedArcIds[arc.Id] = true
					local completingDefinition = content.DefinitionsById[arc.QuestIds[#arc.QuestIds]]
					table.insert(transitions, transition("ArcCompleted", completingDefinition, nil, cause, {
						Projection = {
							CompletedQuestCount = #arc.QuestIds,
							DisplayQuestCount = arc.DisplayQuestCount,
						},
						PresentationMode = state.SelectedInstanceId == completingDefinition.InstanceId and "Tracked" or "Passive",
					}))
					changed = true
				end
			end
		end
		if not changed then
			return
		end
	end
	error("QuestEngine: bounded cascade failed to settle", 2)
end

function QuestEngine.Interests(content, state, facts)
	local interests = {}
	for _, definition in ipairs(content.Definitions) do
		local instance = state.Instances[definition.InstanceId]
		if not instance or not instance.Completed then
			local currentIndex = instance and instance.StepIndex or 1
			if instance and currentIndex <= #definition.Steps then
				local currentStep = definition.Steps[currentIndex]
				local module = content.Objectives.Get(currentStep.Objective.Kind)
				for _, trigger in ipairs(module.ActiveTriggers) do
					interests[trigger] = true
				end
			end
			for stepIndex = currentIndex, #definition.Steps do
				local step = definition.Steps[stepIndex]
				local module = content.Objectives.Get(step.Objective.Kind)
				if #module.CaptureTriggers > 0 then
					local byStep = state.ObjectiveProgress[definition.InstanceId]
					local progress = type(byStep) == "table" and byStep[step.Id] or {}
					local result = content.Objectives.Evaluate(step.Objective, facts or {}, progress)
					if not result or not result.Satisfied then
						for _, trigger in ipairs(module.CaptureTriggers) do
							interests[trigger] = true
						end
					end
				end
			end
		end
	end
	return interests
end

local function selectTracked(content, state)
	local selected = state.SelectedInstanceId and state.Instances[state.SelectedInstanceId]
	if selected and not selected.Completed then
		return
	end
	state.SelectedInstanceId = nil
	for _, definition in ipairs(content.Definitions) do
		local instance = state.Instances[definition.InstanceId]
		if instance and not instance.Completed then
			state.SelectedInstanceId = instance.InstanceId
			return
		end
	end
end

function QuestEngine.reduce(content, questState, facts, cause, sessionState)
	if
		type(content) ~= "table"
		or type(questState) ~= "table"
		or type(facts) ~= "table"
		or type(cause) ~= "table"
		or not finite(cause.Timestamp)
	then
		error("QuestEngine: invalid reduce input", 2)
	end
	local state = QuestSchema.CloneState(questState)
	local session = clone(sessionState or {})
	local transitions, effects = {}, {}
	captureEvent(content, state, cause)
	settle(content, state, facts, cause, session, transitions, effects)
	selectTracked(content, state)
	for _, emittedTransition in ipairs(transitions) do
		if emittedTransition.PresentationMode == nil then
			emittedTransition.PresentationMode = emittedTransition.InstanceId == state.SelectedInstanceId and "Tracked" or "Passive"
		end
	end
	return state, session, transitions, effects, QuestEngine.Interests(content, state, facts)
end

function QuestEngine.applyEffectResult(content, questState, sessionState, effect, succeeded, cause)
	if type(effect) ~= "table" or type(succeeded) ~= "boolean" or not finite(cause and cause.Timestamp) then
		error("QuestEngine: invalid effect result", 2)
	end
	local state = QuestSchema.CloneState(questState)
	local session = clone(sessionState or {})
	local transitions, effects = {}, {}
	if effect.Kind == "RewardGrant" then
		local definition = content.DefinitionsById[effect.DefinitionId]
		local reward = definition and definition.RewardBySlotId[effect.RewardSlotId]
		if not reward or reward.ReceiptId ~= effect.ReceiptId then
			error("QuestEngine: reward effect identity mismatch", 2)
		end
		if succeeded and state.RewardReceipts[effect.ReceiptId] ~= true then
			state.RewardReceipts[effect.ReceiptId] = true
			local publicProjection, projectionProblem = content.Rewards.Project(reward)
			if not publicProjection then
				error("QuestEngine: reward projection failed: " .. tostring(projectionProblem), 2)
			end
			local pending = transition("RewardGranted", definition, nil, cause, {
				RewardSlotId = reward.SlotId,
				RewardKind = reward.Kind,
				Projection = clone(publicProjection),
				PresentationMode = state.SelectedInstanceId == definition.InstanceId and "Tracked" or "Passive",
			})
			session.PendingRewardTransitions = session.PendingRewardTransitions or {}
			table.insert(session.PendingRewardTransitions, pending)
			local analyticsId = QuestSchema.RewardAnalyticsId(effect.ReceiptId)
			if not state.AnalyticsReceipts[analyticsId] then
				table.insert(effects, {
					Kind = "Analytics",
					AnalyticsKind = "RewardGranted",
					EffectId = analyticsId,
					DefinitionId = definition.Id,
					InstanceId = definition.InstanceId,
					RewardSlotId = reward.SlotId,
					Params = clone(reward.Params),
					CauseTimestamp = cause.Timestamp,
				})
			end
		end
	elseif effect.Kind == "Analytics" then
		if not content.AcceptedAnalyticsIds[effect.EffectId] then
			error("QuestEngine: analytics effect identity mismatch", 2)
		end
		-- Analytics is best effort at the impure boundary. Mark the stable effect ID after
		-- one execution attempt so a retryable reward can never replay completion analytics.
		state.AnalyticsReceipts[effect.EffectId] = true
	else
		error("QuestEngine: unknown effect kind", 2)
	end
	return state, session, transitions, effects, QuestEngine.Interests(content, state, {})
end

function QuestEngine.select(content, questState, instanceIdentity)
	local state = QuestSchema.CloneState(questState)
	local instance = state.Instances[instanceIdentity]
	if not instance or instance.Completed then
		return state, false
	end
	state.SelectedInstanceId = instanceIdentity
	return state, true
end

return table.freeze(QuestEngine)
