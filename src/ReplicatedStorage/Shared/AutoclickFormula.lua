local ProductionFormula = require(script.Parent.ProductionFormula)
local UpgradeConfig = require(script.Parent.UpgradeConfig)
local AutoclickerConfig = require(script.Parent.AutoclickerConfig)

local AutoclickFormula = {}

local POWER_UPGRADE_ID = AutoclickerConfig.PowerUpgradeId
local SPEED_UPGRADE_ID = AutoclickerConfig.SpeedUpgradeId
local BASE_SPEED = 2

local function getUpgradeLevel(player, upgradeId, context)
	local count
	if type(context) == "table" and type(context.UpgradeCounts) == "table" then
		count = tonumber(context.UpgradeCounts[upgradeId]) or 0
	else
		local upgradeCountData = player and player:FindFirstChild("UpgradeCountData")
		local countValue = upgradeCountData and upgradeCountData:FindFirstChild(upgradeId)
		if not countValue or not countValue:IsA("IntValue") then
			return 0
		end
		count = countValue.Value
	end

	local config = UpgradeConfig[upgradeId]
	local maxLevel = config and config.Levels and #config.Levels or 0
	return math.clamp(count, 0, maxLevel)
end

-- Cookies earned by one automatic click. Autoclick power is intentionally
-- independent from the player's manual CookiesGainedPerClick value.
function AutoclickFormula.GetPower(player, context)
	local config = UpgradeConfig[POWER_UPGRADE_ID]
	local level = getUpgradeLevel(player, POWER_UPGRADE_ID, context)
	local levelConfig = config and config.Levels and config.Levels[level]
	local power = levelConfig and tonumber(levelConfig.AutoclickPayout) or 0
	return math.max(0, power)
end

-- Automatic clicks per second. The base speed only produces income after at
-- least one Autoclick Power level has been purchased.
function AutoclickFormula.GetSpeed(player, context)
	local config = UpgradeConfig[SPEED_UPGRADE_ID]
	local level = getUpgradeLevel(player, SPEED_UPGRADE_ID, context)
	local levelConfig = config and config.Levels and config.Levels[level]
	local speed = levelConfig and tonumber(levelConfig.AutoclickSpeed) or BASE_SPEED
	return math.max(BASE_SPEED, speed)
end

function AutoclickFormula.GetBaseCps(player, context)
	local power = AutoclickFormula.GetPower(player, context)
	if power <= 0 then
		return 0
	end

	return power * AutoclickFormula.GetSpeed(player, context)
end

-- In-session autoclick income receives the same replicated world-event boost
-- as manual clicks and buildings. Offline earnings deliberately do not use it.
function AutoclickFormula.GetLiveCps(player, context)
	return AutoclickFormula.GetBaseCps(player, context) * ProductionFormula.GetEventMultiplier()
end

return AutoclickFormula
