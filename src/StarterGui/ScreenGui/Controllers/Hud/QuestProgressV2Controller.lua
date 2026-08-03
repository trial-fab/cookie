-- Inactive protocol-v2 client bootstrap factory. Stage E supplies the real
-- transport and calls Start; Stage C does not require or register any remotes.

local QuestProgressV2Controller = {}
QuestProgressV2Controller.__index = QuestProgressV2Controller

function QuestProgressV2Controller.new(config)
	assert(type(config) == "table", "QuestProgressV2Controller config required")
	assert(type(config.Protocol) == "table" and type(config.Coordinator) == "table", "protocol/coordinator required")
	assert(type(config.BindEnvelope) == "function" and type(config.SendReady) == "function", "transport required")
	return setmetatable({
		Protocol = config.Protocol,
		Coordinator = config.Coordinator,
		BindEnvelope = config.BindEnvelope,
		SendReady = config.SendReady,
		Connection = nil,
		Started = false,
	}, QuestProgressV2Controller)
end

function QuestProgressV2Controller:Start()
	if self.Started then
		return false
	end
	self.Started = true
	-- Listener binding must happen before Ready to close the setup race.
	self.Connection = self.BindEnvelope(function(envelope)
		self.Coordinator:HandleEnvelope(envelope)
	end)
	self.SendReady(self.Protocol.ReadyRequest())
	return true
end

function QuestProgressV2Controller:Stop()
	if self.Connection then
		if type(self.Connection) == "function" then
			self.Connection()
		elseif type(self.Connection.Disconnect) == "function" then
			self.Connection:Disconnect()
		end
	end
	self.Connection = nil
	self.Started = false
end

return QuestProgressV2Controller
