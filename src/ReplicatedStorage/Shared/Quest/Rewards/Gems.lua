local Gems = { Kind = "Gems" }

function Gems.Validate(params)
	if type(params) ~= "table" then
		return false, "Gems parameters must be a table"
	end
	for key in pairs(params) do
		if key ~= "Amount" then
			return false, "unknown Gems parameter"
		end
	end
	local amount = params.Amount
	return type(amount) == "number" and amount == amount and amount % 1 == 0 and amount >= 0 and amount <= 1000000,
		"Gems Amount must be a bounded non-negative integer"
end

-- The adapter owns the Roblox service. Receipt reservation is performed by the effect
-- runner before this non-yielding call.
function Gems.Execute(adapter, player, params, effect)
	return adapter.AddGems(player, params.Amount, effect)
end

-- Public protocol projection. Internal receipt identity never crosses this boundary.
function Gems.Project(params)
	return { Amount = params.Amount }
end

return table.freeze(Gems)
