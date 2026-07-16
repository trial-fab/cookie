-- DevTuning: the only gameplay-facing read/observe API for live developer tuning.
-- Flip Enabled to false for the release gate; callers then receive registry defaults only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegistryLoader = require(script.Parent.RegistryLoader)
local Value = require(script.Parent.Value)

local DevTuning = {
	Enabled = true,
	ConfigurationName = "DevTuningConfiguration",
}

local function getDefinition(dottedId)
	if type(dottedId) ~= "string" then
		error("DevTuning key must be a dotted string", 3)
	end

	local definition = RegistryLoader.load().byId[dottedId]
	if not definition then
		error(("Unknown DevTuning key %q"):format(dottedId), 3)
	end
	return definition
end

local function getConfiguration()
	local configuration = ReplicatedStorage:FindFirstChild(DevTuning.ConfigurationName)
	if configuration and configuration:IsA("Configuration") then
		return configuration
	end
	return nil
end

local function makeObservationHandle()
	local handle = {
		Connected = true,
		_connections = {},
	}

	function handle:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected = false
		for _, connection in ipairs(self._connections) do
			connection:Disconnect()
		end
		table.clear(self._connections)
	end

	return handle
end

function DevTuning.getCatalog()
	return RegistryLoader.load()
end

function DevTuning.get(dottedId)
	local definition = getDefinition(dottedId)
	local configuration = DevTuning.Enabled and getConfiguration() or nil
	local liveValue = nil
	if configuration then
		liveValue = configuration:GetAttribute(dottedId)
	end
	return Value.resolve(DevTuning.Enabled, definition, liveValue)
end

function DevTuning.observe(dottedId, callback)
	local definition = getDefinition(dottedId)
	if type(callback) ~= "function" then
		error("DevTuning.observe callback must be a function", 2)
	end

	local handle = makeObservationHandle()
	if not DevTuning.Enabled then
		callback(definition.default)
		handle:Disconnect()
		return handle
	end

	local connectedConfiguration
	local function notify()
		if handle.Connected then
			callback(DevTuning.get(dottedId))
		end
	end
	local function connectConfiguration(configuration)
		if connectedConfiguration or not configuration:IsA("Configuration") then
			return false
		end
		connectedConfiguration = configuration
		table.insert(handle._connections, configuration:GetAttributeChangedSignal(dottedId):Connect(notify))
		return true
	end

	local configuration = getConfiguration()
	if configuration then
		connectConfiguration(configuration)
		notify()
	else
		callback(definition.default)
		table.insert(
			handle._connections,
			ReplicatedStorage.ChildAdded:Connect(function(child)
				if child.Name == DevTuning.ConfigurationName and connectConfiguration(child) then
					notify()
				end
			end)
		)
	end

	return handle
end

return DevTuning
