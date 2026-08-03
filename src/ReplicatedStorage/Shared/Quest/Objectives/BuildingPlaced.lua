local Util = require(script.Parent.Util)

local Objective = {
	Kind = "BuildingPlaced",
	ProgressMode = "Canonical",
	ActiveTriggers = { "BuildingPlaced", "BuildingCountChanged", "CookieBalanceChanged" },
	CaptureTriggers = { "BuildingPlaced", "BuildingCountChanged" },
	LiveProgress = { Source = "CookieBalance", Phases = { "Saving" } },
	ProgressBarPhases = { "Saving" },
	Phases = { "Saving", "Affordable", "WaitingForPlacement", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { UpgradeId = true, ShowAffordability = true })
	if not ok then
		return false, problem
	end
	return Util.id(params.UpgradeId) and (params.ShowAffordability == nil or type(params.ShowAffordability) == "boolean"),
		"BuildingPlaced requires an UpgradeId and optional affordability flag"
end

function Objective.Capture(params, progress, cause)
	if cause.Payload.UpgradeId == params.UpgradeId and cause.Payload.Count > 0 then
		return { Captured = true }
	end
	return progress or {}
end

function Objective.Evaluate(params, facts, progress)
	local satisfied = Util.count(facts, params.UpgradeId) > 0 or progress.Captured == true
	local costs = type(facts) == "table" and facts.UpgradeCosts
	local target = type(costs) == "table" and tonumber(costs[params.UpgradeId]) or nil
	local balance = tonumber(type(facts) == "table" and facts.CookieBalance) or 0
	local affordability = params.ShowAffordability == true and target and target > 0
	local affordable = affordability and balance >= target
	local phase = satisfied and "Satisfied"
		or affordability and affordable and "Affordable"
		or affordability and "Saving"
		or "WaitingForPlacement"
	return {
		Satisfied = satisfied,
		Current = affordability and math.min(math.max(0, balance), target) or satisfied and 1 or 0,
		Target = affordability and target or 1,
		-- The bar tracks the cookies collected, so a full count reads as a full bar; the
		-- copy flipping to "Place a {Name}" is what says the saving is done and an action
		-- remains. This used to cap at 0.75 so a full bar could not imply a finished step,
		-- which read as the placement silently owning the last quarter of the bar.
		-- Still explicit rather than left to Current/Target: once satisfied, Current is the
		-- balance AFTER paying, so the fallback would collapse the finished bar to nearly 0.
		ProgressFraction = satisfied and 1
			or affordability and math.clamp(balance / target, 0, 1)
			or 0,
		Phase = phase,
		Tokens = {
			UpgradeId = params.UpgradeId,
			Current = affordability and math.min(math.max(0, balance), target) or satisfied and 1 or 0,
			Target = affordability and target or 1,
		},
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
