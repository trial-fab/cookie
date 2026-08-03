-- In-process observation publisher for genuine UI affordances. Stage D registers
-- sources and vocabulary only; Stage E may bind the single protocol-v2 sender.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiObservations = require(ReplicatedStorage.Shared.Quest.UiObservations)

local QuestProgressObservationBus = {}
local listeners = {}

function QuestProgressObservationBus.Publish(observation)
	if not UiObservations.IsAllowed(observation) then
		return false, "observation is not allowlisted"
	end
	local delivered = false
	for listener in pairs(listeners) do
		delivered = true
		listener(observation)
	end
	return delivered
end

function QuestProgressObservationBus.Bind(listener)
	assert(type(listener) == "function", "observation listener must be a function")
	listeners[listener] = true
	local connected = true
	return function()
		if connected then
			connected = false
			listeners[listener] = nil
		end
	end
end

return QuestProgressObservationBus
