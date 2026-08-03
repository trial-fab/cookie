local Gems = require(script.Parent.Gems)
local GooSkin = require(script.Parent.GooSkin)

local Registry = {}
local MODULES = { Gems, GooSkin }
local byKind = {}

for _, module in ipairs(MODULES) do
	assert(type(module.Kind) == "string" and module.Kind ~= "" and not byKind[module.Kind], "duplicate reward kind")
	assert(
		type(module.Validate) == "function"
			and type(module.Execute) == "function"
			and type(module.Project) == "function",
		"incomplete reward kind"
	)
	byKind[module.Kind] = module
end

function Registry.Get(kind)
	return byKind[kind]
end

function Registry.ValidateReward(reward)
	if type(reward) ~= "table" then
		return false, "reward must be a table"
	end
	for key in pairs(reward) do
		if key ~= "SlotId" and key ~= "Kind" and key ~= "Params" then
			return false, "unknown reward field " .. tostring(key)
		end
	end
	local module = byKind[reward.Kind]
	if not module then
		return false, "unknown reward kind " .. tostring(reward.Kind)
	end
	return module.Validate(reward.Params)
end

function Registry.All()
	return MODULES
end

function Registry.Project(reward)
	if type(reward) ~= "table" then
		return nil, "reward must be a table"
	end
	local module = byKind[reward.Kind]
	if not module then
		return nil, "unknown reward kind"
	end
	local ok, problem = module.Validate(reward.Params)
	if not ok then
		return nil, problem
	end
	local projection = module.Project(reward.Params)
	if type(projection) ~= "table" then
		return nil, "reward projection must be a table"
	end
	return projection
end

return table.freeze(Registry)
