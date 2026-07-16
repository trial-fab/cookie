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

	configuration:SetAttribute(dottedId, canonicalValue)
	return { success = true, value = canonicalValue, reason = nil }
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
