-- Pure logical reducer for protocol-v2 quest envelopes. It applies snapshots and
-- explicit transitions only; no completion or milestone is inferred from diffs.

local QuestProgressReducer = {}
QuestProgressReducer.__index = QuestProgressReducer

function QuestProgressReducer.new(config)
	assert(type(config) == "table" and type(config.Protocol) == "table", "QuestProgressReducer needs Protocol")
	return setmetatable({
		Protocol = config.Protocol,
		OnDiagnostic = config.OnDiagnostic,
		SessionId = nil,
		Revision = 0,
		Snapshot = nil,
		SeenTransitions = {},
		RetiredSessions = {},
		RetiredSessionOrder = {},
		Diagnostics = {},
	}, QuestProgressReducer)
end

function QuestProgressReducer:_diagnose(kind, fields)
	local diagnostic = fields or {}
	diagnostic.Kind = kind
	table.insert(self.Diagnostics, diagnostic)
	if self.OnDiagnostic then
		self.OnDiagnostic(diagnostic)
	end
	return diagnostic
end

function QuestProgressReducer:Apply(envelope)
	local ok, problem = self.Protocol.ValidateEnvelope(envelope)
	if not ok then
		return {
			Accepted = false,
			SnapshotChanged = false,
			Transitions = {},
			Diagnostic = self:_diagnose("EnvelopeRejected", { Problem = problem }),
		}
	end

	local sessionChanged = self.SessionId ~= envelope.SessionId
	if sessionChanged and self.RetiredSessions[envelope.SessionId] then
		return {
			Accepted = false,
			SnapshotChanged = false,
			Transitions = {},
			Diagnostic = self:_diagnose("RetiredSessionEnvelope", { SessionId = envelope.SessionId }),
		}
	end
	if not sessionChanged and envelope.Revision <= self.Revision then
		return {
			Accepted = false,
			SnapshotChanged = false,
			Transitions = {},
			Diagnostic = self:_diagnose("DuplicateOrStaleEnvelope", {
				SessionId = envelope.SessionId,
				Revision = envelope.Revision,
				AcceptedRevision = self.Revision,
			}),
		}
	end

	if sessionChanged then
		if self.SessionId then
			self.RetiredSessions[self.SessionId] = true
			table.insert(self.RetiredSessionOrder, self.SessionId)
			if #self.RetiredSessionOrder > 8 then
				local expired = table.remove(self.RetiredSessionOrder, 1)
				self.RetiredSessions[expired] = nil
			end
		end
		self.SessionId = envelope.SessionId
		self.Revision = 0
		self.SeenTransitions = {}
	end

	local previousRevision = self.Revision
	local revisionGap = not sessionChanged and previousRevision > 0 and envelope.Revision > previousRevision + 1
	self.Revision = envelope.Revision
	self.Snapshot = self.Protocol.Clone(envelope.Snapshot)
	if revisionGap then
		-- Snapshot convergence is safe; ceremony ordering is not. Skip this batch,
		-- surface the gap, and continue from the received revision. There is no resend.
		for _, transition in ipairs(envelope.Transitions) do
			self.SeenTransitions[transition.Id] = true
		end
		return {
			Accepted = true,
			SessionChanged = false,
			SnapshotChanged = true,
			Snapshot = self.Snapshot,
			Transitions = {},
			Diagnostic = self:_diagnose("RevisionGap", {
				SessionId = envelope.SessionId,
				Revision = envelope.Revision,
				ExpectedRevision = previousRevision + 1,
			}),
		}
	end

	local accepted = {}
	for _, transition in ipairs(envelope.Transitions) do
		if not self.SeenTransitions[transition.Id] then
			self.SeenTransitions[transition.Id] = true
			table.insert(accepted, self.Protocol.Clone(transition))
		end
	end
	return {
		Accepted = true,
		SessionChanged = sessionChanged,
		SnapshotChanged = true,
		Snapshot = self.Snapshot,
		Transitions = accepted,
	}
end

function QuestProgressReducer:GetState()
	return {
		SessionId = self.SessionId,
		Revision = self.Revision,
		Snapshot = self.Snapshot and self.Protocol.Clone(self.Snapshot) or nil,
	}
end

return QuestProgressReducer
