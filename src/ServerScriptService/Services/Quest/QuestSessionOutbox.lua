-- Bounded, in-memory delivery state for one live player session. It is not
-- persisted and has no acknowledgement/resend machinery: RemoteEvents are treated
-- as reliable and ordered inside a live session.

local QuestSessionOutbox = {}
QuestSessionOutbox.__index = QuestSessionOutbox

local DEFAULT_MAX_TRANSITIONS = 128

local function copyMetrics(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

function QuestSessionOutbox.new(config)
	assert(type(config) == "table" and type(config.Protocol) == "table", "QuestSessionOutbox needs Protocol")
	assert(type(config.NewSessionId) == "function", "QuestSessionOutbox needs NewSessionId")
	local maximum = math.floor(tonumber(config.MaxTransitions) or DEFAULT_MAX_TRANSITIONS)
	assert(maximum >= 1 and maximum <= 256, "QuestSessionOutbox has invalid bound")
	return setmetatable({
		Protocol = config.Protocol,
		NewSessionId = config.NewSessionId,
		SendEnvelope = config.SendEnvelope,
		OnDiagnostic = config.OnDiagnostic,
		MaxTransitions = maximum,
		ByPlayer = setmetatable({}, { __mode = "k" }),
		Metrics = {
			SessionsStarted = 0,
			ReadyBatchesSent = 0,
			DuplicateReadyCalls = 0,
			OverflowEvents = 0,
			DroppedTransitions = 0,
			PlainRepublishes = 0,
		},
	}, QuestSessionOutbox)
end

function QuestSessionOutbox:_diagnose(player, kind, fields)
	local diagnostic = fields or {}
	diagnostic.Kind = kind
	if self.OnDiagnostic then
		self.OnDiagnostic(player, diagnostic)
	end
end

function QuestSessionOutbox:BeginSession(player)
	local sessionId = self.NewSessionId(player)
	assert(type(sessionId) == "string" and sessionId ~= "", "NewSessionId returned an invalid identity")
	self.ByPlayer[player] = {
		SessionId = sessionId,
		Revision = 0,
		LatestSnapshot = nil,
		Pending = {},
		Ready = false,
		ReadyBatchSent = false,
	}
	self.Metrics.SessionsStarted += 1
	return sessionId
end

function QuestSessionOutbox:_send(player, envelope)
	if self.SendEnvelope then
		self.SendEnvelope(player, envelope)
	end
	return envelope
end

function QuestSessionOutbox:_appendBounded(player, session, transitions)
	for _, transition in ipairs(transitions) do
		table.insert(session.Pending, transition)
	end
	local overflow = #session.Pending - self.MaxTransitions
	if overflow <= 0 then
		return
	end
	-- Deterministic overflow policy: retain the newest bounded suffix. The latest
	-- snapshot is independent and is never discarded. Presentation loss cannot
	-- affect grants because effects commit before this boundary.
	for _ = 1, overflow do
		table.remove(session.Pending, 1)
	end
	self.Metrics.OverflowEvents += 1
	self.Metrics.DroppedTransitions += overflow
	self:_diagnose(player, "OutboxOverflow", {
		DroppedTransitions = overflow,
		RetainedTransitions = #session.Pending,
		SessionId = session.SessionId,
		Revision = session.Revision,
	})
end

function QuestSessionOutbox:_sendReadyBatch(player, session)
	local envelope, problem = self.Protocol.MakeEnvelope(
		session.SessionId,
		session.Revision,
		session.LatestSnapshot,
		session.Pending
	)
	if not envelope then
		return nil, problem
	end
	table.clear(session.Pending)
	session.ReadyBatchSent = true
	self.Metrics.ReadyBatchesSent += 1
	return self:_send(player, envelope)
end

function QuestSessionOutbox:Publish(player, snapshot, transitions)
	local session = self.ByPlayer[player]
	if not session then
		return nil, "player has no quest protocol session"
	end
	local snapshotOk, snapshotProblem = self.Protocol.ValidateSnapshot(snapshot)
	if not snapshotOk then
		return nil, snapshotProblem
	end
	transitions = transitions or {}
	if type(transitions) ~= "table" or #transitions > 256 then
		return nil, "transition batch is invalid or unbounded"
	end
	local transitionCount = 0
	for key in pairs(transitions) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "transition batch must be a dense array"
		end
		transitionCount += 1
	end
	if transitionCount ~= #transitions then
		return nil, "transition batch must be a dense array"
	end
	local nextRevision = session.Revision + 1
	local stamped = {}
	for ordinal, transition in ipairs(transitions) do
		local value, problem = self.Protocol.StampTransition(session.SessionId, nextRevision, ordinal, transition)
		if not value then
			return nil, problem
		end
		table.insert(stamped, value)
	end
	session.Revision = nextRevision
	session.LatestSnapshot = self.Protocol.Clone(snapshot)
	if #stamped == 0 then
		self.Metrics.PlainRepublishes += 1
	end
	if not session.Ready or not session.ReadyBatchSent then
		self:_appendBounded(player, session, stamped)
		if session.Ready and not session.ReadyBatchSent then
			return self:_sendReadyBatch(player, session)
		end
		return nil, "waiting for Ready"
	end
	local envelope, problem = self.Protocol.MakeEnvelope(
		session.SessionId,
		session.Revision,
		session.LatestSnapshot,
		stamped
	)
	if not envelope then
		return nil, problem
	end
	return self:_send(player, envelope)
end

function QuestSessionOutbox:Ready(player, request)
	local ok, problem = self.Protocol.ValidateReady(request)
	if not ok then
		return nil, problem
	end
	local session = self.ByPlayer[player]
	if not session then
		return nil, "player has no quest protocol session"
	end
	if session.Ready then
		self.Metrics.DuplicateReadyCalls += 1
		self:_diagnose(player, "DuplicateReady", {
			SessionId = session.SessionId,
			Revision = session.Revision,
		})
		return nil, if session.ReadyBatchSent then "Ready batch already sent" else "Ready already received"
	end
	session.Ready = true
	if not session.LatestSnapshot or session.Revision < 1 then
		return nil, "waiting for snapshot"
	end
	return self:_sendReadyBatch(player, session)
end

function QuestSessionOutbox:ClearPlayer(player)
	self.ByPlayer[player] = nil
end

function QuestSessionOutbox:GetSession(player)
	local session = self.ByPlayer[player]
	if not session then
		return nil
	end
	return {
		SessionId = session.SessionId,
		Revision = session.Revision,
		PendingCount = #session.Pending,
		Ready = session.Ready,
		ReadyBatchSent = session.ReadyBatchSent,
	}
end

function QuestSessionOutbox:GetMetrics()
	return copyMetrics(self.Metrics)
end

return QuestSessionOutbox
