local Util = require(script.Parent.Util)

local Objective = {
	Kind = "BoostPurchased",
	ProgressMode = "CapturedFact",
	Triggers = { "BoostPurchased", "GemBalanceChanged" },
	CopyTriggers = { "GemBalanceChanged" },
	CaptureBeforeActive = true,
	Phases = { "Shortfall", "Affordable", "Satisfied" },
}

local function allowedItemIds(value)
	if type(value) ~= "table" or #value < 1 or #value > 8 then return nil end
	local result = {}
	for index, itemId in ipairs(value) do
		if value[index] ~= itemId or not Util.id(itemId) or result[itemId] then return nil end
		result[itemId] = true
	end
	for key in pairs(value) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then return nil end
	end
	return result
end

function Objective.Validate(params)
	local ok, problem = Util.exactKeys(params, { ItemIds = true })
	if not ok then return false, problem end
	return allowedItemIds(params.ItemIds) ~= nil, "BoostPurchased needs unique bounded ItemIds"
end

function Objective.Capture(params, progress, cause)
	if cause.Kind == "BoostPurchased" then
		local allowed = allowedItemIds(params.ItemIds)
		if allowed and allowed[cause.Payload.ItemId] then return { Captured = true } end
	end
	return progress or {}
end

function Objective.Evaluate(_, facts, progress)
	local captured = progress.Captured == true
	local target = math.floor(tonumber(type(facts) == "table" and facts.BoostPriceGems) or 1)
	if target < 1 then target = 1 end
	local balance = tonumber(type(facts) == "table" and facts.GemBalance) or 0
	if not Util.finite(balance) or balance < 0 then balance = 0 end
	local current = math.min(math.floor(balance), target)
	return {
		Satisfied = captured,
		Current = current,
		Target = target,
		ProgressFraction = captured and 1 or math.clamp(current / target, 0, 1) * 0.75,
		Phase = captured and "Satisfied" or balance >= target and "Affordable" or "Shortfall",
		Tokens = { Current = current, Target = target },
	}
end

Objective.NormalizeProgress = Util.boolProgress
return table.freeze(Objective)
