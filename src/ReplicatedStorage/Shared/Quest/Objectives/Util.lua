local Util = {}

function Util.finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Util.integer(value, minimum, maximum)
	return Util.finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

function Util.id(value)
	return type(value) == "string" and #value > 0 and #value <= 96
end

function Util.exactKeys(value, allowed)
	if type(value) ~= "table" then
		return false, "parameters must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, "unknown parameter " .. tostring(key)
		end
	end
	return true
end

function Util.count(facts, upgradeId)
	local counts = type(facts) == "table" and facts.UpgradeCounts
	local value = type(counts) == "table" and counts[upgradeId]
	return Util.integer(value, 0, 1000000000) and value or 0
end

function Util.boolProgress(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or (value.Captured ~= nil and type(value.Captured) ~= "boolean") then
		return nil, "captured progress must contain only a boolean Captured field"
	end
	for key in pairs(value) do
		if key ~= "Captured" then
			return nil, "unknown captured progress field"
		end
	end
	return value.Captured and { Captured = true } or {}
end

return table.freeze(Util)
