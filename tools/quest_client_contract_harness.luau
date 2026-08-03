--!nocheck
-- Pure Stage A contract harness for the future quest client reducer and ordered
-- presentation queue. This module deliberately has no Roblox globals, services, UI
-- instances, tasks, or clocks. Tests drive every asynchronous completion explicitly.

local Harness = {}

local function copyArray(source)
	local result = {}
	for index, value in ipairs(source or {}) do
		result[index] = value
	end
	return result
end

local function copyDictionary(source)
	local result = {}
	for key, value in pairs(source or {}) do
		result[key] = value
	end
	return result
end

local Reducer = {}
Reducer.__index = Reducer

function Reducer.new()
	return setmetatable({
		SessionId = nil,
		Revision = 0,
		Snapshot = nil,
		SeenTransitions = {},
	}, Reducer)
end

function Reducer:apply(envelope)
	assert(type(envelope) == "table", "envelope must be a table")
	assert(type(envelope.SessionId) == "string", "envelope needs a SessionId")
	assert(type(envelope.Revision) == "number", "envelope needs a Revision")

	if self.SessionId == envelope.SessionId and envelope.Revision <= self.Revision then
		return {}
	end
	if self.SessionId ~= envelope.SessionId then
		self.SessionId = envelope.SessionId
		self.Revision = 0
		self.SeenTransitions = {}
	end

	self.Revision = envelope.Revision
	self.Snapshot = envelope.Snapshot
	local accepted = {}
	for _, transition in ipairs(envelope.Transitions or {}) do
		local id = transition.Id
		assert(type(id) == "string" and id ~= "", "transition needs a stable Id")
		if not self.SeenTransitions[id] then
			self.SeenTransitions[id] = true
			table.insert(accepted, transition)
		end
	end
	return accepted
end

Harness.Reducer = Reducer

local Queue = {}
Queue.__index = Queue

local function action(kind, fields)
	local result = fields or {}
	result.Kind = kind
	return result
end

local function releaseActions(release)
	release = release or { Kind = "Immediate" }
	return { action("Release", { Release = release }) }
end

local function expandTransition(transition)
	local kind = transition.Kind
	if kind == "StepCompleted" then
		local actions = {
			action("StopGuide", { Guide = transition.OutgoingGuide }),
			action("RenderCopy", { Copy = transition.OutgoingCopy, Phase = "outgoing" }),
			action("Strike", { Key = "step:" .. transition.StepId, Target = transition.StrikeTarget }),
		}
		for _, nextAction in ipairs(releaseActions(transition.Release)) do
			table.insert(actions, nextAction)
		end
		table.insert(actions, action("RenderCopy", { Copy = transition.NextCopy, Phase = "next" }))
		table.insert(
			actions,
			action("StartGuide", {
				Guide = transition.NextGuide,
				Target = transition.NextGuideTarget,
			})
		)
		return actions
	elseif kind == "StepMilestoneReached" then
		local actions = {
			action("StopGuide", { Guide = transition.OutgoingGuide }),
			action("RenderCopy", { Copy = transition.OutgoingCopy, Phase = "milestone-outgoing" }),
		}
		if transition.Policy ~= "ReplaceWithoutStrike" then
			table.insert(
				actions,
				action("Strike", {
					Key = "milestone:" .. transition.MilestoneId,
					Target = transition.StrikeTarget,
				})
			)
		end
		for _, nextAction in ipairs(releaseActions(transition.Release)) do
			table.insert(actions, nextAction)
		end
		table.insert(actions, action("RenderCopy", { Copy = transition.NextCopy, Phase = "milestone-next" }))
		table.insert(
			actions,
			action("StartGuide", {
				Guide = transition.NextGuide,
				Target = transition.NextGuideTarget,
			})
		)
		return actions
	elseif kind == "QuestCompleted" then
		return {
			action("StopGuide", { Guide = transition.OutgoingGuide }),
			action("RenderCopy", { Copy = transition.OutgoingCopy, Phase = "quest-outgoing" }),
			action("Strike", { Key = "quest:" .. transition.QuestId, Target = transition.StrikeTarget }),
			action("ShowLesson", { QuestId = transition.QuestId, Lesson = transition.Lesson }),
			action("BeginCompletionHold", { QuestId = transition.QuestId }),
		}
	elseif kind == "RewardGranted" then
		return {
			action("PresentReward", {
				QuestId = transition.QuestId,
				RewardSlotId = transition.RewardSlotId,
				Amount = transition.Amount,
				Target = transition.RewardTarget,
			}),
			action("CompletionSignal", { QuestId = transition.QuestId }),
			action("EndCompletionHold", { QuestId = transition.QuestId }),
		}
	end
	error("unsupported transition kind: " .. tostring(kind))
end

function Queue.new(options)
	options = options or {}
	assert(options.Motion == nil or options.Motion == "Standard" or options.Motion == "Reduced", "invalid motion")
	return setmetatable({
		Motion = options.Motion or "Standard",
		Actions = {},
		Waiting = nil,
		Signals = {},
		Trace = {},
		State = {
			CurrentCopy = options.CurrentCopy,
			ActiveGuide = options.ActiveGuide,
			CompletionHold = nil,
			Struck = {},
			Lessons = {},
			PresentedRewards = {},
			CompletionSignals = {},
		},
	}, Queue)
end

function Queue:_record(value)
	table.insert(self.Trace, value)
end

function Queue:_prepend(actions)
	for index = #actions, 1, -1 do
		table.insert(self.Actions, 1, actions[index])
	end
end

function Queue:_runRelease(release)
	local kind = release.Kind or "Immediate"
	if kind == "Immediate" then
		self:_record("release:immediate")
	elseif kind == "TimingProfile" then
		self:_record("wait:timer:" .. tostring(release.Profile))
		self.Waiting = { Kind = "Timer", Name = release.Profile }
	elseif kind == "PresentationSignal" then
		local name = assert(release.Name, "PresentationSignal needs a Name")
		if self.Signals[name] then
			self:_record("signal:already:" .. name)
			if release.Fallback then
				self:_prepend({ action("Release", { Release = release.Fallback }) })
			end
		else
			self:_record("wait:signal:" .. name)
			self.Waiting = { Kind = "Signal", Name = name }
		end
	else
		error("unsupported release kind: " .. tostring(kind))
	end
end

function Queue:_run(nextAction)
	local kind = nextAction.Kind
	if kind == "StopGuide" then
		local guide = nextAction.Guide or self.State.ActiveGuide
		if guide then
			self:_record("guide:stop:" .. guide)
		end
		self.State.ActiveGuide = nil
	elseif kind == "RenderCopy" then
		self.State.CurrentCopy = nextAction.Copy
		self:_record("copy:" .. nextAction.Phase .. ":" .. tostring(nextAction.Copy))
	elseif kind == "Strike" then
		local key = nextAction.Key
		self.State.Struck[key] = true
		if nextAction.Target == false then
			self:_record("strike:missing:" .. key)
			self:_record("strike:complete:" .. key)
		elseif self.Motion == "Reduced" then
			self:_record("strike:snap:" .. key)
			self:_record("strike:complete:" .. key)
		else
			self:_record("strike:start:" .. key)
			self.Waiting = { Kind = "Strike", Key = key }
		end
	elseif kind == "Release" then
		self:_runRelease(nextAction.Release)
	elseif kind == "StartGuide" then
		if not nextAction.Guide then
			return
		end
		if nextAction.Target == false then
			self.State.ActiveGuide = nil
			self:_record("guide:missing:" .. nextAction.Guide)
		else
			self.State.ActiveGuide = nextAction.Guide
			self:_record("guide:start:" .. nextAction.Guide)
		end
	elseif kind == "ShowLesson" then
		self.State.Lessons[nextAction.QuestId] = nextAction.Lesson
		self:_record("lesson:" .. nextAction.QuestId)
	elseif kind == "BeginCompletionHold" then
		self.State.CompletionHold = nextAction.QuestId
		self:_record("hold:start:" .. nextAction.QuestId)
	elseif kind == "PresentReward" then
		local rewardKey = nextAction.QuestId .. "/" .. nextAction.RewardSlotId
		if nextAction.Amount == 0 then
			table.insert(self.State.PresentedRewards, rewardKey)
			self:_record("reward:zero:" .. rewardKey)
		elseif nextAction.Target == false then
			table.insert(self.State.PresentedRewards, rewardKey)
			self:_record("reward:fallback:" .. rewardKey)
		elseif self.Motion == "Reduced" then
			table.insert(self.State.PresentedRewards, rewardKey)
			self:_record("reward:snap:" .. rewardKey)
		else
			self:_record("reward:start:" .. rewardKey)
			self.Waiting = { Kind = "Reward", Key = rewardKey }
		end
	elseif kind == "CompletionSignal" then
		self.State.CompletionSignals[nextAction.QuestId] = true
		self:_record("completion:signal:" .. nextAction.QuestId)
	elseif kind == "EndCompletionHold" then
		assert(self.State.CompletionHold == nextAction.QuestId, "completion hold/reward correlation mismatch")
		self.State.CompletionHold = nil
		self:_record("hold:end:" .. nextAction.QuestId)
	else
		error("unsupported action kind: " .. tostring(kind))
	end
end

function Queue:pump()
	while not self.Waiting and #self.Actions > 0 do
		local nextAction = table.remove(self.Actions, 1)
		self:_run(nextAction)
	end
	return self.Waiting
end

function Queue:enqueue(transitions)
	for _, transition in ipairs(transitions or {}) do
		for _, nextAction in ipairs(expandTransition(transition)) do
			table.insert(self.Actions, nextAction)
		end
	end
	return self:pump()
end

function Queue:resolve(outcome)
	local waiting = assert(self.Waiting, "queue is not waiting")
	outcome = outcome or "completed"
	self.Waiting = nil
	if waiting.Kind == "Strike" then
		self:_record("strike:" .. outcome .. ":" .. waiting.Key)
		self:_record("strike:complete:" .. waiting.Key)
	elseif waiting.Kind == "Reward" then
		table.insert(self.State.PresentedRewards, waiting.Key)
		self:_record("reward:" .. outcome .. ":" .. waiting.Key)
	elseif waiting.Kind == "Timer" then
		self:_record("timer:" .. outcome .. ":" .. tostring(waiting.Name))
	elseif waiting.Kind == "Signal" then
		self:_record("signal:" .. outcome .. ":" .. waiting.Name)
	end
	return self:pump()
end

function Queue:signal(name)
	self.Signals[name] = true
	if self.Waiting and self.Waiting.Kind == "Signal" and self.Waiting.Name == name then
		return self:resolve("completed")
	end
	return self.Waiting
end

function Queue:cancel()
	return self:resolve("cancelled")
end

function Queue:timeout()
	return self:resolve("timeout")
end

function Queue:isIdle()
	return self.Waiting == nil and #self.Actions == 0
end

function Queue:logicalState()
	return {
		CurrentCopy = self.State.CurrentCopy,
		ActiveGuide = self.State.ActiveGuide,
		CompletionHold = self.State.CompletionHold,
		Struck = copyDictionary(self.State.Struck),
		Lessons = copyDictionary(self.State.Lessons),
		PresentedRewards = copyArray(self.State.PresentedRewards),
		CompletionSignals = copyDictionary(self.State.CompletionSignals),
	}
end

Harness.Queue = Queue

local Measurements = {}
Measurements.__index = Measurements

function Measurements.new()
	return setmetatable({
		DomainNotifications = 0,
		FullReconciliations = 0,
		EarlyInterestRejections = 0,
		ContextLoads = 0,
	}, Measurements)
end

function Measurements:notifyDomain(interested)
	self.DomainNotifications += 1
	if not interested then
		self.EarlyInterestRejections += 1
		return false
	end
	self.ContextLoads += 1
	return true
end

function Measurements:fullReconciliation()
	self.FullReconciliations += 1
	self.ContextLoads += 1
end

function Measurements:snapshot()
	return {
		DomainNotifications = self.DomainNotifications,
		FullReconciliations = self.FullReconciliations,
		EarlyInterestRejections = self.EarlyInterestRejections,
		ContextLoads = self.ContextLoads,
	}
end

Harness.Measurements = Measurements

return Harness
