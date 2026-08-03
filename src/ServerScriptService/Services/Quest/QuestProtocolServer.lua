-- Inactive Stage C server coordinator. Stage E supplies the transport and wires
-- BeginSession -> setup reconciliation -> Ready remote atomically.

local QuestProtocolServer = {}
QuestProtocolServer.__index = QuestProtocolServer

function QuestProtocolServer.new(config)
	assert(type(config) == "table", "QuestProtocolServer config required")
	assert(type(config.Protocol) == "table" and type(config.Outbox) == "table", "protocol/outbox required")
	assert(type(config.Content) == "table", "content required")
	return setmetatable({
		Protocol = config.Protocol,
		Outbox = config.Outbox,
		Content = config.Content,
	}, QuestProtocolServer)
end

function QuestProtocolServer:BeginSession(player)
	return self.Outbox:BeginSession(player)
end

function QuestProtocolServer:Publish(player, state, facts, transitions)
	local snapshot, problem = self.Protocol.BuildSnapshot(self.Content, state, facts)
	if not snapshot then
		return nil, problem
	end
	return self.Outbox:Publish(player, snapshot, transitions or {})
end

function QuestProtocolServer:Ready(player, request)
	return self.Outbox:Ready(player, request)
end

function QuestProtocolServer:ClearPlayer(player)
	self.Outbox:ClearPlayer(player)
end

function QuestProtocolServer:GetMetrics()
	return self.Outbox:GetMetrics()
end

return QuestProtocolServer
