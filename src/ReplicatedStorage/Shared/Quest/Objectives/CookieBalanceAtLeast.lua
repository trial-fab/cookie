local Util = require(script.Parent.Util)

local Objective = {
	Kind = "CookieBalanceAtLeast",
	ProgressMode = "Canonical",
	-- Building purchases publish their committed placement after the pending
	-- deduction; re-evaluate live balance copy at that resolution boundary.
	ActiveTriggers = { "CookieBalanceChanged", "UpgradePurchased", "BuildingPlaced" },
	CaptureTriggers = {},
	LiveProgress = { Source = "CookieBalance", Phases = { "Saving" } },
	Phases = { "Saving", "Affordable", "Owned" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { Amount = true, UpgradeId = true })
	if not ok then
		return false, problem
	end
	local amount = params.Amount
	if amount ~= nil and not Util.integer(amount, 1, 1000000000000000) then
		return false, "invalid Amount"
	end
	if params.UpgradeId ~= nil and not Util.id(params.UpgradeId) then
		return false, "invalid UpgradeId"
	end
	return amount ~= nil or params.UpgradeId ~= nil, "CookieBalanceAtLeast needs Amount or UpgradeId"
end

function Objective.NormalizeProgress(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or next(value) ~= nil then
		return nil, "canonical balance progress must be empty"
	end
	return {}
end

function Objective.Evaluate(params, facts)
	local owned = params.UpgradeId ~= nil and Util.count(facts, params.UpgradeId) > 0
	local costs = type(facts) == "table" and facts.UpgradeCosts
	local target = params.Amount or type(costs) == "table" and costs[params.UpgradeId]
	if not Util.integer(target, 1, 1000000000000000) then
		target = params.Amount or 1
	end
	local balance = tonumber(type(facts) == "table" and facts.CookieBalance) or 0
	if not Util.finite(balance) or balance < 0 then
		balance = 0
	end
	local current = math.min(balance, target)
	local affordable = balance >= target
	return {
		Satisfied = owned or affordable,
		Current = current,
		Target = target,
		Phase = owned and "Owned" or affordable and "Affordable" or "Saving",
		Tokens = { Current = current, Target = target, UpgradeId = params.UpgradeId },
	}
end

return table.freeze(Objective)
