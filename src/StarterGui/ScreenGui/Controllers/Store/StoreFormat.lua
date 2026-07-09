-- StoreFormat: pure number/rate/multiplier/integrity text helpers for the store rows.
-- Stateless aside from the production-rate display mode constants; takes config/values
-- as arguments. Constructed once with the shared StoreController context (for `player`
-- and `UpgradeConfig`); requires its Shared deps directly.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local ProductionFormula = require(shared:WaitForChild("ProductionFormula"))

local PRODUCTION_RATE_DISPLAY = "CPM"
local TOTAL_PRODUCTION_RATE_DISPLAY = "TCPM"

local StoreFormat = {}

function StoreFormat.new(ctx)
	local player = ctx.player

	local M = {}

	function M.formatNumber(value)
		return NumberFormat.abbreviate(value)
	end

	function M.formatCount(value)
		return NumberFormat.abbreviate(value)
	end

	function M.formatRateValue(value)
		return NumberFormat.rate(value)
	end

	function M.formatMultiplier(value)
		return NumberFormat.multiplier(value)
	end

	function M.getProductionMultiplier(upgradeId, config)
		return ProductionFormula.GetMultiplier(player, upgradeId, config)
	end

	function M.getIntegrityText(config)
		if not config or config.TemplateKind ~= "Building" then
			return ""
		end

		local maxIntegrity = config.MaxIntegrity
		if typeof(maxIntegrity) ~= "number" then
			return ""
		end

		return M.formatCount(maxIntegrity)
	end

	function M.getMultiplierText(upgradeId, config)
		if not config or config.TemplateKind ~= "Building" then
			return ""
		end

		return M.formatMultiplier(M.getProductionMultiplier(upgradeId, config))
	end

	function M.getBuildingProductionRates(config, multiplier)
		if not config or config.TemplateKind ~= "Building" then
			return 0, 0
		end

		local updateTime = math.max(1, config.UpdateTime or 30)
		local cookiesGained = config.CookiesGained or 0
		local cps = cookiesGained / updateTime * (multiplier or 1)
		local cpm = cps * 60
		return cpm, cps
	end

	function M.getProductionRateText(config, multiplier)
		if not config or config.TemplateKind ~= "Building" then
			return ""
		end

		local cpm, cps = M.getBuildingProductionRates(config, multiplier)
		if PRODUCTION_RATE_DISPLAY == "CPS" then
			return M.formatRateValue(cps)
		end

		return M.formatRateValue(cpm)
	end

	function M.getTotalProductionRateText(config, count, multiplier)
		if not config or config.TemplateKind ~= "Building" then
			return ""
		end

		local cpm, cps = M.getBuildingProductionRates(config, multiplier)
		if TOTAL_PRODUCTION_RATE_DISPLAY == "TCPS" then
			return M.formatRateValue(cps * count)
		end

		return M.formatRateValue(cpm * count)
	end

	return M
end

return StoreFormat
