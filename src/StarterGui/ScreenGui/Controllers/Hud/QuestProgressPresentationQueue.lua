-- Pure ordered presentation coordinator. Roblox visuals are injected adapters;
-- asynchronous work completes through callbacks plus centralized safety timeouts.

local QuestProgressPresentationQueue = {}
QuestProgressPresentationQueue.__index = QuestProgressPresentationQueue

local function copyDictionary(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = value
	end
	return result
end

local function selectedStep(snapshot)
	if type(snapshot) ~= "table" then
		return nil, nil
	end
	for _, instance in ipairs(snapshot.Instances or {}) do
		if instance.Selected == true or instance.InstanceId == snapshot.SelectedInstanceId then
			return instance, instance.CurrentStep
		end
	end
	return nil, nil
end

local function rewardKey(transition)
	return tostring(transition.InstanceId) .. "/" .. tostring(transition.RewardSlotId)
end

function QuestProgressPresentationQueue.new(config)
	assert(type(config) == "table", "QuestProgressPresentationQueue config required")
	assert(type(config.Policies) == "table", "presentation policy registry required")
	assert(type(config.Signals) == "table", "presentation signal registry required")
	assert(type(config.Scheduler) == "table" and type(config.Scheduler.After) == "function", "scheduler required")
	assert(config.Motion == nil or config.Motion == "Standard" or config.Motion == "Reduced", "invalid motion mode")
	return setmetatable({
		Policies = config.Policies,
		Signals = config.Signals,
		Scheduler = config.Scheduler,
		Adapters = config.Adapters or {},
		Motion = config.Motion or "Standard",
		OnDiagnostic = config.OnDiagnostic,
		Snapshot = nil,
		Items = {},
		Actions = {},
		Waiting = nil,
		Destroyed = false,
		Diagnostics = {},
		Trace = {},
		Completion = {},
		SeenLocal = {},
		SeenLocalOrder = {},
		State = {
			CurrentProjection = nil,
			ActiveGuide = nil,
			Struck = {},
			PresentedRewards = {},
			PassivePresentations = {},
			CompletionSignals = {},
			AuthorityMutations = 0,
		},
	}, QuestProgressPresentationQueue)
end

function QuestProgressPresentationQueue:_record(value)
	table.insert(self.Trace, value)
end

function QuestProgressPresentationQueue:_diagnose(kind, fields)
	local diagnostic = fields or {}
	diagnostic.Kind = kind
	table.insert(self.Diagnostics, diagnostic)
	if self.OnDiagnostic then
		self.OnDiagnostic(diagnostic)
	end
	return diagnostic
end

function QuestProgressPresentationQueue:SetSnapshot(snapshot)
	self.Snapshot = snapshot
end

function QuestProgressPresentationQueue:SetMotion(motion)
	assert(motion == "Standard" or motion == "Reduced", "invalid motion mode")
	self.Motion = motion
end

function QuestProgressPresentationQueue:Reset(snapshot)
	local waiting = self.Waiting
	self.Waiting = nil
	if waiting then
		waiting.Active = false
		if waiting.CancelTimeout then waiting.CancelTimeout() end
		if waiting.Cancel then pcall(waiting.Cancel, "session-reset") end
	end
	for _, completion in pairs(self.Completion) do
		if completion.CancelTimeout then completion.CancelTimeout() end
	end
	table.clear(self.Items)
	table.clear(self.Actions)
	table.clear(self.Completion)
	table.clear(self.SeenLocal)
	table.clear(self.SeenLocalOrder)
	self.Snapshot = snapshot
	self.State.CurrentProjection = nil
	self.State.ActiveGuide = nil
	table.clear(self.State.Struck)
	table.clear(self.State.PresentedRewards)
	table.clear(self.State.PassivePresentations)
	table.clear(self.State.CompletionSignals)
end

function QuestProgressPresentationQueue:_prepend(actions)
	for index = #actions, 1, -1 do
		table.insert(self.Actions, 1, actions[index])
	end
end

function QuestProgressPresentationQueue:_adapter(name, context, timeoutKind, onCompleted)
	local callback = self.Adapters[name]
	if type(callback) ~= "function" then
		self:_diagnose("MissingAdapter", { Adapter = name })
		onCompleted("unavailable")
		return
	end

	local token = { Active = true, Cancel = nil, CancelTimeout = nil, Name = name }
	self.Waiting = token
	local function finish(outcome)
		if not token.Active then
			return
		end
		token.Active = false
		if token.CancelTimeout then
			token.CancelTimeout()
		end
		if self.Waiting == token then
			self.Waiting = nil
		end
		onCompleted(outcome or "completed")
		self:_pump()
	end
	token.Finish = finish
	local timeoutSeconds = self.Policies:GetSafetyTimeout(timeoutKind)
	if timeoutSeconds and timeoutSeconds > 0 then
		token.CancelTimeout = self.Scheduler:After(timeoutSeconds, function()
			self:_diagnose("PresentationTimeout", { Adapter = name, Seconds = timeoutSeconds })
			if token.Cancel then
				pcall(token.Cancel, "timeout")
			end
			finish("timeout")
		end)
	end
	local ok, cancelOrProblem = pcall(callback, context, finish)
	if not ok then
		self:_diagnose("AdapterFailure", { Adapter = name, Problem = tostring(cancelOrProblem) })
		finish("failed")
	elseif type(cancelOrProblem) == "function" then
		token.Cancel = cancelOrProblem
	elseif cancelOrProblem == false then
		finish("unavailable")
	end
end

function QuestProgressPresentationQueue:_syncAdapter(name, context)
	local callback = self.Adapters[name]
	if type(callback) ~= "function" then
		self:_diagnose("MissingAdapter", { Adapter = name })
		return false
	end
	local ok, problem = pcall(callback, context)
	if not ok then
		self:_diagnose("AdapterFailure", { Adapter = name, Problem = tostring(problem) })
		return false
	end
	return true
end

function QuestProgressPresentationQueue:_release(release, transition)
	local ok, problem = self.Policies:ValidateRelease(release)
	if not ok then
		self:_diagnose("InvalidReleasePolicy", { Problem = problem })
		return
	end
	if release.Kind == "Immediate" then
		self:_record("release:immediate")
		return
	elseif release.Kind == "TimingProfile" then
		local timing = self.Policies:GetTiming(release.Profile)
		self:_record("release:timing:" .. release.Profile)
		if self.Motion == "Reduced" or timing.DurationSeconds <= 0 then
			return
		end
		local token = { Active = true, Name = "TimingProfile" }
		self.Waiting = token
		token.CancelTimeout = self.Scheduler:After(timing.DurationSeconds, function()
			if not token.Active then
				return
			end
			token.Active = false
			if self.Waiting == token then
				self.Waiting = nil
			end
			self:_pump()
		end)
		return
	elseif release.Kind == "ManualAcknowledge" then
		-- Validated for future content, but intentionally unsupported as tutorial
		-- runtime. Safe release prevents an accidental declaration from deadlocking.
		self:_diagnose("ManualAcknowledgeUnsupported", { Name = release.Acknowledgement })
		return
	end

	self:_record("release:signal:" .. release.Name)
	local token = { Active = true, Name = release.Name }
	self.Waiting = token
	local function finish(status)
		if not token.Active then
			return
		end
		token.Active = false
		if token.CancelTimeout then
			token.CancelTimeout()
		end
		if token.Cancel then
			token.Cancel()
		end
		if self.Waiting == token then
			self.Waiting = nil
		end
		if status == "already-completed" and release.Fallback then
			self:_prepend({ { Kind = "Release", Release = release.Fallback, Transition = transition } })
		elseif status ~= "completed" and status ~= "already-completed" then
			self:_diagnose("PresentationSignalReleasedSafely", { Name = release.Name, Outcome = status })
		end
		self:_pump()
	end
	token.Finish = finish
	local timeout = self.Policies:GetSafetyTimeout("PresentationSignal")
	if timeout and timeout > 0 then
		token.CancelTimeout = self.Scheduler:After(timeout, function()
			finish("timeout")
		end)
	end
	token.Cancel = self.Signals:Wait(release.Name, finish)
end

function QuestProgressPresentationQueue:_currentContext(transition)
	local instance, step = selectedStep(self.Snapshot)
	return {
		Motion = self.Motion,
		Snapshot = self.Snapshot,
		Transition = transition,
		Instance = instance,
		Step = step,
	}
end

function QuestProgressPresentationQueue:_run(action)
	local transition = action.Transition
	local context = self:_currentContext(transition)
	if action.Kind == "StopGuide" then
		self:_record("guide:stop")
		self:_adapter("StopGuide", context, "Guide", function()
			self.State.ActiveGuide = nil
		end)
	elseif action.Kind == "RenderEvent" then
		self.State.CurrentProjection = transition.Projection
		self:_record("copy:event:" .. tostring(transition.Kind))
		self:_syncAdapter("RenderEvent", context)
	elseif action.Kind == "Strike" then
		local key = transition.Id or transition.LocalId
		self:_record("strike:start:" .. tostring(key))
		self:_adapter("Strike", context, "Strike", function(outcome)
			self.State.Struck[key] = true
			self:_record("strike:" .. tostring(outcome) .. ":" .. tostring(key))
		end)
	elseif action.Kind == "Release" then
		self:_release(action.Release, transition)
	elseif action.Kind == "RenderCurrent" then
		local _, step = selectedStep(self.Snapshot)
		self.State.CurrentProjection = step and step.Projection or nil
		self:_record("copy:current")
		self:_syncAdapter("RenderCurrent", context)
	elseif action.Kind == "StartGuide" then
		self:_record("guide:start")
		self:_adapter("StartGuide", context, "Guide", function(outcome)
			local instance, step = selectedStep(self.Snapshot)
			self.State.ActiveGuide = outcome == "completed" and instance and (instance.InstanceId .. "/" .. step.StepId) or nil
		end)
	elseif action.Kind == "BeginCompletion" then
		local remaining = {}
		for _, slotId in ipairs(transition.RewardSlotIds or {}) do
			remaining[slotId] = true
		end
		local completion = { Remaining = remaining, Transition = transition }
		self.Completion[transition.InstanceId] = completion
		local timeout = self.Policies:GetSafetyTimeout("Reward")
		if timeout and timeout > 0 then
			completion.CancelTimeout = self.Scheduler:After(timeout, function()
				if self.Completion[transition.InstanceId] ~= completion then
					return
				end
				self.Completion[transition.InstanceId] = nil
				self.State.CompletionSignals[transition.InstanceId] = true
				self:_diagnose("CompletionTimeout", { InstanceId = transition.InstanceId, Seconds = timeout })
				self:_record("completion:timeout:" .. transition.InstanceId)
				self:_syncAdapter("EndCompletion", self:_currentContext(transition))
				self:_pump()
			end)
		end
		self:_record("completion:begin:" .. transition.InstanceId)
		self:_syncAdapter("BeginCompletion", context)
	elseif action.Kind == "EndCompletion" then
		local completion = self.Completion[transition.InstanceId]
		if completion and completion.CancelTimeout then
			completion.CancelTimeout()
		end
		self.Completion[transition.InstanceId] = nil
		self.State.CompletionSignals[transition.InstanceId] = true
		self:_record("completion:end:" .. transition.InstanceId)
		self:_syncAdapter("EndCompletion", context)
	elseif action.Kind == "PresentReward" then
		local key = rewardKey(transition)
		local amount = tonumber(transition.Projection and transition.Projection.Amount)
		if amount == 0 then
			table.insert(self.State.PresentedRewards, key)
			self:_record("reward:zero:" .. key)
			return
		end
		self:_record("reward:start:" .. key)
		self:_adapter("PresentReward", context, "Reward", function(outcome)
			table.insert(self.State.PresentedRewards, key)
			self:_record("reward:" .. tostring(outcome) .. ":" .. key)
		end)
	elseif action.Kind == "PresentPassive" then
		self:_record("passive:" .. tostring(transition.InstanceId))
		self:_adapter("PresentPassive", context, "Passive", function()
			table.insert(self.State.PassivePresentations, transition.Id or transition.LocalId)
		end)
	end
end

function QuestProgressPresentationQueue:_actionsFor(transition, localOnly)
	local presentationMode = transition.PresentationMode or "Tracked"
	if not localOnly and presentationMode == "Passive" then
		local passive = transition.PassivePolicy or "TrackedOnly"
		if passive == "TrackedOnly" or passive == "Silent" then
			return {}
		end
		local policy = self.Policies:Get(passive, "Passive")
		if not policy or policy.Silent then
			return {}
		end
		return { { Kind = "PresentPassive", Transition = transition } }
	end

	if transition.Kind == "QuestUnlocked" then
		return {
			{ Kind = "RenderCurrent", Transition = transition },
			{ Kind = "StartGuide", Transition = transition },
		}
	elseif transition.Kind == "StepCompleted" or transition.Kind == "StepMilestoneReached"
		or transition.Kind == "LocalPresentationMilestone"
	then
		local name = transition.PresentationPolicy or "StandardConcise"
		local policy = self.Policies:Get(name, "Step")
		if not policy then
			self:_diagnose("UnknownPresentationPolicy", { Name = name })
			policy = assert(self.Policies:Get("StandardConcise", "Step"))
		end
		local actions = {
			{ Kind = "StopGuide", Transition = transition },
			{ Kind = "RenderEvent", Transition = transition },
		}
		if policy.Strike then
			table.insert(actions, { Kind = "Strike", Transition = transition })
		end
		table.insert(actions, { Kind = "Release", Release = policy.Release, Transition = transition })
		table.insert(actions, { Kind = "RenderCurrent", Transition = transition })
		table.insert(actions, { Kind = "StartGuide", Transition = transition })
		return actions
	elseif transition.Kind == "QuestCompleted" then
		local name = transition.PresentationPolicy or "StandardCompletion"
		local policy = self.Policies:Get(name, "Quest")
		if not policy then
			self:_diagnose("UnknownPresentationPolicy", { Name = name })
			policy = assert(self.Policies:Get("StandardCompletion", "Quest"))
		end
		local actions = {
			{ Kind = "StopGuide", Transition = transition },
			{ Kind = "RenderEvent", Transition = transition },
		}
		if policy.Strike then
			table.insert(actions, { Kind = "Strike", Transition = transition })
		end
		table.insert(actions, { Kind = "Release", Release = policy.Release, Transition = transition })
		table.insert(actions, { Kind = "BeginCompletion", Transition = transition })
		if #(transition.RewardSlotIds or {}) == 0 then
			table.insert(actions, { Kind = "EndCompletion", Transition = transition })
			local successor = selectedStep(self.Snapshot)
			if successor then
				table.insert(actions, { Kind = "RenderCurrent", Transition = transition })
				table.insert(actions, { Kind = "StartGuide", Transition = transition })
			end
		end
		return actions
	elseif transition.Kind == "RewardGranted" then
		local actions = { { Kind = "PresentReward", Transition = transition } }
		local completion = self.Completion[transition.InstanceId]
		if completion and completion.Remaining[transition.RewardSlotId] then
			completion.Remaining[transition.RewardSlotId] = nil
			if next(completion.Remaining) == nil then
				table.insert(actions, { Kind = "EndCompletion", Transition = transition })
				local successor = selectedStep(self.Snapshot)
				if successor then
					table.insert(actions, { Kind = "RenderCurrent", Transition = transition })
					table.insert(actions, { Kind = "StartGuide", Transition = transition })
				end
			end
		end
		return actions
	elseif transition.Kind == "ArcCompleted" then
		return { { Kind = "PresentPassive", Transition = transition } }
	end
	return {}
end

function QuestProgressPresentationQueue:_pump()
	if self.Destroyed or self.Waiting then
		return self.Waiting
	end
	while not self.Waiting do
		if #self.Actions == 0 then
			local item = table.remove(self.Items, 1)
			if not item then
				return nil
			end
			self.Actions = self:_actionsFor(item.Transition, item.LocalOnly)
		end
		local action = table.remove(self.Actions, 1)
		if action then
			self:_run(action)
		end
	end
	return self.Waiting
end

function QuestProgressPresentationQueue:Enqueue(transitions)
	for _, transition in ipairs(transitions or {}) do
		table.insert(self.Items, { Transition = transition, LocalOnly = false })
	end
	return self:_pump()
end

function QuestProgressPresentationQueue:EnqueueLocal(event)
	if type(event) ~= "table" or event.Kind ~= "LocalPresentationMilestone"
		or event.PresentationOnly ~= true or type(event.LocalId) ~= "string" or event.LocalId == ""
		or type(event.InstanceId) ~= "string" or event.InstanceId == ""
		or type(event.DefinitionId) ~= "string" or event.DefinitionId == ""
		or type(event.StepId) ~= "string" or event.StepId == ""
		or type(event.StepIndex) ~= "number" or event.StepIndex % 1 ~= 0 or event.StepIndex < 1
		or type(event.Projection) ~= "table"
	then
		return false, "invalid local presentation-only milestone"
	end
	if self.SeenLocal[event.LocalId] then
		return false, "duplicate local presentation milestone"
	end
	self.SeenLocal[event.LocalId] = true
	table.insert(self.SeenLocalOrder, event.LocalId)
	if #self.SeenLocalOrder > 128 then
		local expired = table.remove(self.SeenLocalOrder, 1)
		self.SeenLocal[expired] = nil
	end
	local safe = {
		Kind = event.Kind,
		LocalId = event.LocalId,
		InstanceId = event.InstanceId,
		DefinitionId = event.DefinitionId,
		StepId = event.StepId,
		StepIndex = event.StepIndex,
		Projection = event.Projection,
		PresentationPolicy = event.PresentationPolicy or "StandardConcise",
		PresentationOnly = true,
	}
	table.insert(self.Items, { Transition = safe, LocalOnly = true })
	self:_pump()
	return true
end

function QuestProgressPresentationQueue:CancelCurrent(reason)
	local waiting = self.Waiting
	if not waiting then
		return false
	end
	self:_diagnose("PresentationCancelled", { Name = waiting.Name, Reason = reason or "cancelled" })
	if waiting.Cancel then
		pcall(waiting.Cancel, reason or "cancelled")
	end
	if waiting.Finish then
		waiting.Finish(reason or "cancelled")
	else
		if waiting.CancelTimeout then
			waiting.CancelTimeout()
		end
		waiting.Active = false
		self.Waiting = nil
		self:_pump()
	end
	return true
end

function QuestProgressPresentationQueue:IsIdle()
	return not self.Waiting and #self.Actions == 0 and #self.Items == 0 and next(self.Completion) == nil
end

function QuestProgressPresentationQueue:LogicalState()
	return {
		CurrentProjection = self.State.CurrentProjection,
		ActiveGuide = self.State.ActiveGuide,
		Struck = copyDictionary(self.State.Struck),
		PresentedRewards = { table.unpack(self.State.PresentedRewards) },
		PassivePresentations = { table.unpack(self.State.PassivePresentations) },
		CompletionSignals = copyDictionary(self.State.CompletionSignals),
		AuthorityMutations = self.State.AuthorityMutations,
	}
end

function QuestProgressPresentationQueue:Destroy()
	self.Destroyed = true
	local waiting = self.Waiting
	if waiting then
		if waiting.Cancel then
			pcall(waiting.Cancel, "destroyed")
		end
		if waiting.CancelTimeout then
			waiting.CancelTimeout()
		end
	end
	self.Waiting = nil
	table.clear(self.Actions)
	table.clear(self.Items)
	for _, completion in pairs(self.Completion) do
		if completion.CancelTimeout then
			completion.CancelTimeout()
		end
	end
	table.clear(self.Completion)
end

return QuestProgressPresentationQueue
