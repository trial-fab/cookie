-- Shared upgrade cost calculation. Optional CostTuningId values remain live through
-- DevTuning while their feature is in development; all other costs use baked config.
local DevTuning = require(script.Parent.DevTuning.DevTuning)

local UpgradePricing = {}

function UpgradePricing.GetCost(config, currentCount)
	if type(config) ~= "table" then
		return nil
	end

	currentCount = math.max(0, math.floor(tonumber(currentCount) or 0))
	if config.MaxCount and currentCount >= config.MaxCount then
		return nil
	end
	if config.Levels then
		local nextLevel = config.Levels[currentCount + 1]
		return nextLevel and nextLevel.Cost or nil
	end

	local baseCost = config.BaseCost or 0
	if type(config.CostTuningId) == "string" then
		baseCost = DevTuning.get(config.CostTuningId)
	end
	local multiplier = config.CostMultiplier or 1
	return math.floor(baseCost * (multiplier ^ currentCount))
end

return UpgradePricing
