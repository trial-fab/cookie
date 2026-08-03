local Util = require(script.Parent.Util)

local Objective = {
	Kind = "BoostFieldDropped",
	ProgressMode = "CapturedFact",
	Triggers = { "BoostFieldDropped" },
	CopyTriggers = {},
	CaptureBeforeActive = true,
	Phases = { "Waiting", "Satisfied" },
}

local function itemSet(items)
	if type(items) ~= "table" or #items < 1 or #items > 8 then return nil end
	local result = {}
	for _, itemId in ipairs(items) do
		if not Util.id(itemId) or result[itemId] then return nil end
		result[itemId] = true
	end
	for key in pairs(items) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #items then return nil end
	end
	return result
end

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { ItemIds = true })
	if not ok then return false, problem end
	return itemSet(params.ItemIds) ~= nil, "BoostFieldDropped needs unique bounded ItemIds"
end

function Objective.Capture(params, progress, cause)
	local allowed = itemSet(params.ItemIds)
	if cause.Kind == "BoostFieldDropped" and allowed and allowed[cause.Payload.ItemId] then
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
		Phase = satisfied and "Satisfied" or "Waiting",
		Tokens = {},
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
