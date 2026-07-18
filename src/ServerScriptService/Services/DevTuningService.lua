-- DevTuningService: server-owned live-value mirror and authoritative apply path.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevTuningFolder = Shared:WaitForChild("DevTuning")
local DevTuning = require(DevTuningFolder:WaitForChild("DevTuning"))
local Net = require(Shared:WaitForChild("Net"))
local Policy = require(DevTuningFolder:WaitForChild("Policy"))
local Value = require(DevTuningFolder:WaitForChild("Value"))

local DevTuningService = {}

local ADMIN_USER_IDS = {
	[10748851] = true,
}

local configuration
local catalog
local applyObservers = {}

local function notifyApplyObservers(dottedId, player, value, previousValue)
	local observers = applyObservers[dottedId]
	if not observers then
		return
	end
	for callback in pairs(observers) do
		local ok, err = pcall(callback, player, value, previousValue)
		if not ok then
			warn(("DevTuning apply observer %q failed: %s"):format(dottedId, tostring(err)))
		end
	end
end

local function apply(player, dottedId, candidateValue)
	if not Policy.isAllowedUserId(player and player.UserId, ADMIN_USER_IDS) then
		return { success = false, value = nil, reason = "NotAuthorized" }
	end
	if type(dottedId) ~= "string" then
		return { success = false, value = nil, reason = "MalformedPayload" }
	end

	local definition = catalog.byId[dottedId]
	if not definition then
		return { success = false, value = nil, reason = "UnknownTunable" }
	end

	local valid, canonicalValue, reason = Value.canonicalize(definition, candidateValue)
	if not valid then
		return { success = false, value = nil, reason = reason }
	end

	local previousValue = configuration:GetAttribute(dottedId)
	configuration:SetAttribute(dottedId, canonicalValue)
	notifyApplyObservers(dottedId, player, canonicalValue, previousValue)
	return { success = true, value = canonicalValue, reason = nil }
end

-- Dev-only action hook for a feature that must react specifically on the authorized
-- player's plot. Ordinary gameplay tuning still reads through DevTuning.get/observe;
-- this preserves the applying-player context that replicated attributes do not carry.
function DevTuningService.ObserveApply(dottedId, callback)
	assert(type(dottedId) == "string", "DevTuningService.ObserveApply requires a dotted id")
	assert(type(callback) == "function", "DevTuningService.ObserveApply requires a callback")
	local observers = applyObservers[dottedId]
	if not observers then
		observers = {}
		applyObservers[dottedId] = observers
	end
	observers[callback] = true

	local connected = true
	return {
		Disconnect = function()
			if not connected then
				return
			end
			connected = false
			observers[callback] = nil
		end,
	}
end

function DevTuningService.Init()
	if not DevTuning.Enabled then
		return
	end

	catalog = DevTuning.getCatalog()
	local stale = ReplicatedStorage:FindFirstChild(DevTuning.ConfigurationName)
	if stale then
		stale:Destroy()
	end

	configuration = Instance.new("Configuration")
	configuration.Name = DevTuning.ConfigurationName
	for _, feature in ipairs(catalog.features) do
		for _, definition in ipairs(feature.tunables) do
			configuration:SetAttribute(definition.fullId, definition.default)
		end
	end
	configuration.Parent = ReplicatedStorage

	Net.onInvoke(Net.Names.DevTuningApply, apply)
	print("DevTuningService initialized")
end

return DevTuningService
