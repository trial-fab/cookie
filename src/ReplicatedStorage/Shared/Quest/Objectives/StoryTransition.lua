local Util = require(script.Parent.Util)

local Objective = {
	Kind = "StoryTransition",
	ProgressMode = "CapturedFact",
	Triggers = { "StoryAdvanced", "IntroCompleted" },
	CopyTriggers = {},
	CaptureBeforeActive = true,
	Phases = { "Waiting", "Satisfied" },
}

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { Fact = true })
	if not ok then
		return false, problem
	end
	return Util.id(params.Fact), "StoryTransition requires a Fact"
end

function Objective.Capture(params, progress, cause)
	progress = progress or {}
	local matched = cause.Kind == "IntroCompleted" and params.Fact == "IntroCompleted"
		or cause.Kind == "StoryAdvanced" and cause.Payload.StoryStep == params.Fact
	return matched and { Captured = true } or progress
end

function Objective.Evaluate(params, facts, progress)
	local storyFacts = type(facts) == "table" and facts.StoryFacts
	local satisfied = progress.Captured == true or type(storyFacts) == "table" and storyFacts[params.Fact] == true
	return {
		Satisfied = satisfied,
		Current = satisfied and 1 or 0,
		Target = 1,
		Phase = satisfied and "Satisfied" or "Waiting",
		Tokens = {},
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
