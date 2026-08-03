local Util = require(script.Parent.Util)
local UiObservations = require(script.Parent.Parent.UiObservations)

local Objective = {
	Kind = "ClientUiObservation",
	ProgressMode = "ClientObservation",
	ActiveTriggers = { "UiObservation" },
	CaptureTriggers = { "UiObservation" },
	Phases = { "WaitingForObservation", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { Observation = true, ImpliedByUpgradeId = true })
	if not ok then
		return false, problem
	end
	if not UiObservations.IsAllowed(params.Observation) then
		return false, "observation is not allowlisted"
	end
	if params.ImpliedByUpgradeId ~= nil and not Util.id(params.ImpliedByUpgradeId) then
		return false, "invalid implied upgrade"
	end
	return true
end

function Objective.Capture(params, progress, cause)
	if cause.Payload.Observation == params.Observation then
		return { Captured = true }
	end
	return progress or {}
end

function Objective.Evaluate(params, facts, progress)
	local satisfied = progress.Captured == true
		or params.ImpliedByUpgradeId ~= nil and Util.count(facts, params.ImpliedByUpgradeId) > 0
	return {
		Satisfied = satisfied,
		Current = satisfied and 1 or 0,
		Target = 1,
		Phase = satisfied and "Satisfied" or "WaitingForObservation",
		Tokens = {},
	}
end

Objective.NormalizeProgress = Util.boolProgress
Objective.Observations = UiObservations
return table.freeze(Objective)
