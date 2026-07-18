local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UpgradeConfig = require(script.Parent.UpgradeConfig)
local WheelConfig = require(script.Parent.WheelConfig)
local Attrs = require(script.Parent.Attrs)
local FloorConfig = require(script.Parent.FloorConfig)
local SkinFeatureConfig = require(script.Parent.SkinFeatureConfig)

local ProductionFormula = {}

-- Defensive ceiling at production-tick time. WheelService already clamps each stored skin
-- value via WheelConfig.GetSkinMultiplier (wheel skins ≤×1.5, exclusive/mythical ≤×1.75), so
-- this is a backstop set to the highest legitimate value — the exclusive ceiling — and must
-- not sit below it or it would silently neuter the day-7 mythical reward.
local MAX_SKIN_MULTIPLIER = WheelConfig.MaxExclusiveSkinMultiplier

local function getUpgradeCount(player, upgradeId)
	local upgradeCountData = player and player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return 0
	end

	local countValue = upgradeCountData:FindFirstChild(upgradeId)
	if countValue and countValue:IsA("IntValue") then
		return countValue.Value
	end

	return 0
end

local function multiplyNumericAttributes(multiplier, container)
	for _, value in pairs(container:GetAttributes()) do
		if typeof(value) == "number" then
			multiplier *= value
		end
	end

	return multiplier
end

local function multiplyNumericValues(multiplier, container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("NumberValue") or child:IsA("IntValue") then
			multiplier *= child.Value
		end
	end

	return multiplier
end

function ProductionFormula.GetUpgradeMultiplier(player, buildingId)
	local multiplier = 1

	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "BuildingUpgrade" and config.TargetBuilding == buildingId and config.Levels then
			local levelsOwned = getUpgradeCount(player, upgradeId)
			for level = 1, math.min(levelsOwned, #config.Levels) do
				local levelData = config.Levels[level]
				if levelData and type(levelData.OutputMultiplier) == "number" then
					multiplier *= levelData.OutputMultiplier
				end
			end
		end
	end

	return math.max(0, multiplier)
end

-- The equipped skin's multiplier is published per building as a NumberValue in
-- the player's EquippedSkinData folder by WheelService (replicates to the client,
-- so store previews and the server tick agree). Absent value = no skin = ×1.
function ProductionFormula.GetBuildingSkinMultiplier(player, buildingId)
	if not SkinFeatureConfig.BuildingSkinsEnabled then
		return 1
	end
	local multiplier = 1

	local skinData = player and player:FindFirstChild("EquippedSkinData")
	local value = skinData and skinData:FindFirstChild(buildingId)
	if value and (value:IsA("NumberValue") or value:IsA("IntValue")) and value.Value > 0 then
		multiplier = value.Value
	end

	return math.clamp(multiplier, 0, MAX_SKIN_MULTIPLIER)
end

function ProductionFormula.GetGooSkinMultiplier(player)
	if not SkinFeatureConfig.GooSkinsEnabled then
		return 1
	end
	local multiplier = player and player:GetAttribute(Attrs.GooSkinMultiplier)
	return math.clamp(type(multiplier) == "number" and multiplier or 1, 1, MAX_SKIN_MULTIPLIER)
end

-- Goo is universal; a future building-specific skin may override it for its building, but
-- bonuses never stack. This preserves a stable ceiling and lets both cosmetic families live
-- together later.
function ProductionFormula.GetSkinMultiplier(player, buildingId)
	return math.max(
		ProductionFormula.GetGooSkinMultiplier(player),
		ProductionFormula.GetBuildingSkinMultiplier(player, buildingId)
	)
end

function ProductionFormula.GetEventMultiplier()
	local worldEventMultipliers = ReplicatedStorage:FindFirstChild("WorldEventMultipliers")
	if not worldEventMultipliers then
		return 1
	end

	local multiplier = 1
	multiplier = multiplyNumericAttributes(multiplier, worldEventMultipliers)
	multiplier = multiplyNumericValues(multiplier, worldEventMultipliers)

	return math.max(0, multiplier)
end

function ProductionFormula.GetFloorMultiplier(buildingId, floorContext)
	local floorId = floorContext
	if typeof(floorContext) == "Instance" then
		floorId = floorContext:GetAttribute(Attrs.FloorId)
	end
	return FloorConfig.GetProductionMultiplier(FloorConfig.NormalizeId(floorId), buildingId)
end

function ProductionFormula.GetMultiplier(player, buildingId, config, floorContext)
	if not config or config.TemplateKind ~= "Building" then
		return 1
	end

	return ProductionFormula.GetUpgradeMultiplier(player, buildingId)
		* ProductionFormula.GetSkinMultiplier(player, buildingId)
		* ProductionFormula.GetEventMultiplier()
		* ProductionFormula.GetFloorMultiplier(buildingId, floorContext)
end

function ProductionFormula.GetCps(player, buildingId, config, floorContext)
	if not config or config.TemplateKind ~= "Building" then
		return 0
	end

	local updateTime = math.max(1, config.UpdateTime or 30)
	local baseCps = (config.CookiesGained or 0) / updateTime
	return baseCps * ProductionFormula.GetMultiplier(player, buildingId, config, floorContext)
end

function ProductionFormula.GetTickOutput(player, buildingId, config, floorContext)
	if not config or config.TemplateKind ~= "Building" then
		return 0
	end

	return (config.CookiesGained or 0) * ProductionFormula.GetMultiplier(player, buildingId, config, floorContext)
end

return ProductionFormula
