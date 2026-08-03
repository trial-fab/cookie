-- Impure effect boundary. Reward receipt reservation and its non-yielding mutation
-- happen in one serialized player turn; analytics clocks and service calls stay here.

local QuestEffectRunner = {}
QuestEffectRunner.__index = QuestEffectRunner

function QuestEffectRunner.new(config)
	assert(type(config) == "table" and type(config.Engine) == "table", "QuestEffectRunner needs Engine")
	assert(type(config.ExecuteReward) == "function", "QuestEffectRunner needs ExecuteReward")
	assert(type(config.ExecuteAnalytics) == "function", "QuestEffectRunner needs ExecuteAnalytics")
	return setmetatable({
		Engine = config.Engine,
		ExecuteReward = config.ExecuteReward,
		ExecuteAnalytics = config.ExecuteAnalytics,
		Clock = config.Clock or os.clock,
		Enabled = config.Enabled == true,
		StepStartedAt = setmetatable({}, { __mode = "k" }),
	}, QuestEffectRunner)
end

function QuestEffectRunner:SetEnabled(enabled)
	self.Enabled = enabled == true
end

function QuestEffectRunner:Execute(player, content, state, session, effect, cause)
	if effect.Kind == "RewardGrant" then
		if state.RewardReceipts[effect.ReceiptId] == true then
			return self.Engine.applyEffectResult(content, state, session, effect, true, cause)
		end
		if not self.Enabled then
			return state, session, {}, {}, false
		end
		-- `Applying` is deliberately transient and never accepted by persistence
		-- normalization. No yield is permitted between reservation, grant, and result.
		state.RewardReceipts[effect.ReceiptId] = "Applying"
		local ok, granted = pcall(self.ExecuteReward, player, content, effect)
		if not ok or granted ~= true then
			state.RewardReceipts[effect.ReceiptId] = nil
			local nextState, nextSession, transitions, effects =
				self.Engine.applyEffectResult(content, state, session, effect, false, cause)
			return nextState, nextSession, transitions, effects, false
		end
		state.RewardReceipts[effect.ReceiptId] = nil
		local nextState, nextSession, transitions, effects =
			self.Engine.applyEffectResult(content, state, session, effect, true, cause)
		return nextState, nextSession, transitions, effects, true
	elseif effect.Kind == "Analytics" then
		if state.AnalyticsReceipts[effect.EffectId] ~= true and self.Enabled then
			local timer = self.StepStartedAt[player]
			local elapsed = timer
					and timer.InstanceId == effect.InstanceId
					and timer.StepId == effect.StepId
					and math.max(0, self.Clock() - timer.StartedAt)
				or 0
			pcall(self.ExecuteAnalytics, player, effect, elapsed)
		end
		local nextState, nextSession, transitions, effects =
			self.Engine.applyEffectResult(content, state, session, effect, true, cause)
		return nextState, nextSession, transitions, effects, true
	end
	error("QuestEffectRunner: unsupported effect " .. tostring(effect.Kind), 2)
end

function QuestEffectRunner:UpdateClock(player, content, state)
	local selected = state.SelectedInstanceId and state.Instances[state.SelectedInstanceId]
	local definition = selected and content.DefinitionsById[selected.DefinitionId]
	local step = definition and definition.Steps[selected.StepIndex]
	if not step then
		self.StepStartedAt[player] = nil
		return
	end
	local timer = self.StepStartedAt[player]
	if not timer or timer.InstanceId ~= selected.InstanceId or timer.StepId ~= step.Id then
		self.StepStartedAt[player] = {
			InstanceId = selected.InstanceId,
			StepId = step.Id,
			StartedAt = self.Clock(),
		}
	end
end

function QuestEffectRunner:ClearPlayer(player)
	self.StepStartedAt[player] = nil
end

return QuestEffectRunner
