local Util = require(script.Parent.Util)

local Objective = {
	Kind = "BuildingCountAtLeast",
	ProgressMode = "Canonical",
	Triggers = { "BuildingPlaced", "BuildingCountChanged", "BuildingSold" },
	CopyTriggers = {},
	CaptureBeforeActive = false,
	Phases = { "Collecting", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, {
		UpgradeId = true,
		Count = true,
		CountFromUpgradeId = true,
		ImpliedByUpgradeId = true,
	})
	if not ok then
		return false, problem
	end
	local hasLiteralCount = params.Count ~= nil
	local hasConfiguredCount = params.CountFromUpgradeId ~= nil
	local targetSourceValid = hasLiteralCount ~= hasConfiguredCount
		and (params.Count == nil or Util.integer(params.Count, 1, 1000000000))
		and (params.CountFromUpgradeId == nil or Util.id(params.CountFromUpgradeId))
	return Util.id(params.UpgradeId)
		and targetSourceValid
		and (params.ImpliedByUpgradeId == nil or Util.id(params.ImpliedByUpgradeId)),
		"BuildingCountAtLeast requires an UpgradeId, one count source, and optional implied upgrade"
end

function Objective.NormalizeProgress(value)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" or next(value) ~= nil then
		return nil, "canonical count progress must be empty"
	end
	return {}
end

function Objective.Evaluate(params, facts)
	local configuredTargets = type(facts) == "table" and facts.UpgradeUnlockCounts
	local target = params.Count
		or type(configuredTargets) == "table" and tonumber(configuredTargets[params.CountFromUpgradeId])
	if not Util.integer(target, 1, 1000000000) then target = 1 end
	local count = Util.count(facts, params.UpgradeId)
	local current = math.min(count, target)
	local implied = params.ImpliedByUpgradeId ~= nil and Util.count(facts, params.ImpliedByUpgradeId) > 0
	local satisfied = count >= target or implied
	return {
		Satisfied = satisfied,
		Current = implied and target or current,
		Target = target,
		Phase = satisfied and "Satisfied" or "Collecting",
		Tokens = {
			UpgradeId = params.UpgradeId,
			Current = implied and target or current,
			Target = target,
		},
	}
end

return table.freeze(Objective)
