-- Server-authored analytics for vertical-floor progression and usage.
local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local FloorAnalyticsService = {}

local function log(player, eventName, value, fields)
	if RunService:IsStudio() then
		return
	end
	local ok, analyticsError = pcall(function()
		AnalyticsService:LogCustomEvent(player, eventName, value, fields)
	end)
	if not ok then
		warn("Floor analytics failed: " .. tostring(analyticsError))
	end
end

function FloorAnalyticsService.RecordFloorUnlocked(player, definition)
	log(player, "FloorUnlocked", definition.Order, {
		FloorId = definition.Id,
		Theme = definition.Theme,
		Cost = tostring(definition.Price),
	})
end

function FloorAnalyticsService.RecordBuildingPlaced(player, floorId, buildingId, bonusApplied)
	log(player, "BuildingPlacedOnFloor", 1, {
		FloorId = floorId,
		BuildingId = buildingId,
		BonusApplied = bonusApplied == true and "true" or "false",
	})
end

function FloorAnalyticsService.Init() end

return FloorAnalyticsService
