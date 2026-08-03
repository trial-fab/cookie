local Util = require(script.Parent.Util)

local Objective = {
	Kind = "UpgradePurchased",
	ProgressMode = "Canonical",
	ActiveTriggers = { "UpgradePurchased" },
	CaptureTriggers = { "UpgradePurchased" },
	Phases = { "WaitingForPurchase", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { UpgradeId = true })
	if not ok then
		return false, problem
	end
	return Util.id(params.UpgradeId), "UpgradePurchased requires an UpgradeId"
end

function Objective.Capture(params, progress, cause)
	if cause.Payload.UpgradeId == params.UpgradeId and cause.Payload.Count > 0 then
		return { Captured = true }
	end
	return progress or {}
end

function Objective.Evaluate(params, facts, progress)
	local satisfied = Util.count(facts, params.UpgradeId) > 0 or progress.Captured == true
	return {
		Satisfied = satisfied,
		Current = satisfied and 1 or 0,
		Target = 1,
		Phase = satisfied and "Satisfied" or "WaitingForPurchase",
		Tokens = { UpgradeId = params.UpgradeId },
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
