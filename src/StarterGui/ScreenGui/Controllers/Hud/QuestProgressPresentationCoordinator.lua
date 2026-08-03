-- Pure composition boundary between protocol reduction and ordered presentation.

local QuestProgressPresentationCoordinator = {}
QuestProgressPresentationCoordinator.__index = QuestProgressPresentationCoordinator

function QuestProgressPresentationCoordinator.new(config)
	assert(type(config) == "table", "QuestProgressPresentationCoordinator config required")
	assert(type(config.Reducer) == "table" and type(config.Queue) == "table", "reducer and queue required")
	return setmetatable({
		Reducer = config.Reducer,
		Queue = config.Queue,
		ApplySnapshot = config.ApplySnapshot,
		ApplyCompletionAction = config.ApplyCompletionAction,
		ShouldSuppressPresentation = config.ShouldSuppressPresentation,
	}, QuestProgressPresentationCoordinator)
end

function QuestProgressPresentationCoordinator:HandleEnvelope(envelope)
	local result = self.Reducer:Apply(envelope)
	if not result.Accepted then
		return result
	end
	if result.SessionChanged and type(self.Queue.Reset) == "function" then
		self.Queue:Reset(result.Snapshot)
	else
		self.Queue:SetSnapshot(result.Snapshot)
	end
	if self.ApplySnapshot then
		self.ApplySnapshot(result.Snapshot, {
			SessionChanged = result.SessionChanged == true,
			Revision = envelope.Revision,
			TransitionCount = #result.Transitions,
		})
	end
	-- Declarative client state actions follow accepted authoritative transitions,
	-- not the optional/timed visual queue. This keeps them reliable during passive
	-- presentation, reward holds, and replay suppression.
	if self.ApplyCompletionAction then
		for _, transition in ipairs(result.Transitions) do
			self.ApplyCompletionAction(transition, result.Snapshot)
		end
	end
	-- An empty list is a plain snapshot. No presentation event is synthesized.
	if not self.ShouldSuppressPresentation or self.ShouldSuppressPresentation() ~= true then
		self.Queue:Enqueue(result.Transitions)
	end
	return result
end

function QuestProgressPresentationCoordinator:HandleLocalPresentation(event)
	return self.Queue:EnqueueLocal(event)
end

return QuestProgressPresentationCoordinator
