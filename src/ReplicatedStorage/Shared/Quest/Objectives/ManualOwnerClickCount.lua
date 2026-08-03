local Util = require(script.Parent.Util)

local Objective = {
	Kind = "ManualOwnerClickCount",
	ProgressMode = "CapturedFact",
	Triggers = { "HealingProgressChanged" },
	CopyTriggers = {},
	CaptureBeforeActive = true,
	Phases = { "Healing", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { Target = true })
	if not ok then
		return false, problem
	end
	return Util.integer(params.Target, 1, 1000000), "ManualOwnerClickCount requires a bounded positive Target"
end

function Objective.Capture(params, progress, cause)
	local current = math.max(tonumber(progress and progress.Current) or 0, cause.Payload.AcceptedClicks)
	return {
		Current = math.min(current, params.Target),
		SequenceCompleted = progress and progress.SequenceCompleted == true or cause.Payload.SequenceCompleted == true,
	}
end

function Objective.NormalizeProgress(value, params)
	if value == nil then
		return {}
	end
	local ok = type(value) == "table"
		and Util.integer(value.Current or 0, 0, params.Target)
		and (value.SequenceCompleted == nil or type(value.SequenceCompleted) == "boolean")
	if not ok then
		return nil, "invalid click progress"
	end
	for key in pairs(value) do
		if key ~= "Current" and key ~= "SequenceCompleted" then
			return nil, "unknown click progress field"
		end
	end
	return { Current = value.Current or 0, SequenceCompleted = value.SequenceCompleted == true }
end

function Objective.Evaluate(params, facts, progress)
	local canonical = tonumber(type(facts) == "table" and facts.HealingManualClicks) or 0
	local current = math.min(params.Target, math.max(canonical, tonumber(progress.Current) or 0))
	local completed = type(facts) == "table" and facts.HealingSequenceCompleted == true
		or progress.SequenceCompleted == true
	local satisfied = current >= params.Target and completed
	return {
		Satisfied = satisfied,
		Current = current,
		Target = params.Target,
		Phase = satisfied and "Satisfied" or "Healing",
		Tokens = { Current = current, Target = params.Target },
	}
end

return table.freeze(Objective)
