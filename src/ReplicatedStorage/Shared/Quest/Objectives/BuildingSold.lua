local Util = require(script.Parent.Util)

local Objective = {
	Kind = "BuildingSold",
	ProgressMode = "CapturedFact",
	ActiveTriggers = { "BuildingSold" },
	CaptureTriggers = { "BuildingSold" },
	Phases = { "WaitingForSale", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { UpgradeId = true })
	if not ok then
		return false, problem
	end
	return params.UpgradeId == "Any" or Util.id(params.UpgradeId), "BuildingSold requires Any or an UpgradeId"
end

function Objective.Capture(params, progress, cause)
	if params.UpgradeId == "Any" or params.UpgradeId == cause.Payload.UpgradeId then
		return { Captured = true }
	end
	return progress or {}
end

function Objective.Evaluate(_, _, progress)
	local satisfied = progress.Captured == true
	return {
		Satisfied = satisfied,
		Current = satisfied and 1 or 0,
		Target = 1,
		Phase = satisfied and "Satisfied" or "WaitingForSale",
		Tokens = {},
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
