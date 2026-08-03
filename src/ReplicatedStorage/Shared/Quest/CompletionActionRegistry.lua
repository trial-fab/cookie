-- Closed, declarative vocabulary for small client-only actions that run after
-- an authoritative quest completion transition. Actions never mutate quest or
-- economy authority.

local Registry = {}

local MODES = { Build = true, Sell = true }

local function exactKeys(value, allowed, label)
	if type(value) ~= "table" then return false, label .. " must be a table" end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, label .. " has unknown field " .. tostring(key)
		end
	end
	return true
end

function Registry.Validate(value)
	local ok, problem = exactKeys(value, { Kind = true, Params = true }, "completion action")
	if not ok then return false, problem end
	if value.Kind ~= "SetStoreMode" then return false, "unknown completion action" end
	ok, problem = exactKeys(value.Params, { Mode = true }, "SetStoreMode params")
	if not ok then return false, problem end
	return MODES[value.Params.Mode] == true, "SetStoreMode needs Build or Sell"
end

return table.freeze(Registry)
