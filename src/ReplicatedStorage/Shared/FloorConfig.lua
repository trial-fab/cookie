-- FloorConfig: shared source of truth for vertical-floor economy, ordering, themes,
-- geometry marker names, and presentation-tuning keys. Approved economy values are
-- final config, not DevTuning.
local FloorConfig = {}

FloorConfig.DimensionId = "Earth"
FloorConfig.GroundFloorId = "Ground"
FloorConfig.ExpansionUpgradeId = "Base Expansion"
FloorConfig.PlacementSchemaVersion = 2
FloorConfig.UnlockableFloorCount = 3

FloorConfig.Geometry = {
	FloorsContainerName = "Floors",
	PlacementBoundsName = "PlacementBounds",
	PlacementOriginName = "PlacementOrigin",
}

-- Persistent approved defaults for the authored floor/crater reveal. DevTuning mirrors
-- these while the feature remains adjustable; disabled tuning resolves to these values.
FloorConfig.Reveal = {
	FloorStartHeight = 24,
	FloorStartRadialOffset = 16,
	GateSlideDistance = 67,
	FloorRevealDuration = 1.1,
	FloorRelockDuration = 0.7,
	GateRevealDuration = 1.25,
	GateRelockDuration = 1.25,
	PartStagger = 0.03,
	SequenceGap = 0.3,
	FloorEasingStyle = Enum.EasingStyle.Quint,
	GateEasingStyle = Enum.EasingStyle.Quint,
}

local definitions = {
	{
		Id = "Ground",
		Order = 0,
		DisplayName = "Ground Floor",
		Theme = "Ground",
		GridColorTuningId = "VerticalFloors.GroundGridColor",
		Multiplier = 1,
		Price = 0,
		BuildingIds = {},
	},
	{
		Id = "Floor1",
		GeometryName = "Floor 1",
		Order = 1,
		DisplayName = "Industry Floor",
		Theme = "Industry",
		GridColorTuningId = "VerticalFloors.IndustryGridColor",
		Multiplier = 1.5,
		Price = 75000,
		BuildingIds = { "Cookie Mine", "Cookie Factory" },
	},
	{
		Id = "Floor2",
		GeometryName = "Floor 2",
		Order = 2,
		DisplayName = "Finance & Distribution Floor",
		Theme = "Finance & Distribution",
		GridColorTuningId = "VerticalFloors.FinanceGridColor",
		Multiplier = 1.5,
		Price = 500000000,
		BuildingIds = { "Cookie Bank", "Cookie Distributer" },
	},
	{
		Id = "Floor3",
		GeometryName = "Floor 3",
		Order = 3,
		DisplayName = "Science Floor",
		Theme = "Science",
		GridColorTuningId = "VerticalFloors.ScienceGridColor",
		Multiplier = 1.5,
		Price = 100000000000,
		BuildingIds = { "Research Facility", "Portal", "Time Machine" },
	},
}

local byId = {}
local byOrder = {}
local themedFloorByBuildingId = {}
local seenGridColorTuningIds = {}

for _, definition in ipairs(definitions) do
	assert(type(definition.Id) == "string" and byId[definition.Id] == nil, "FloorConfig has duplicate floor id")
	assert(type(definition.Order) == "number" and byOrder[definition.Order] == nil, "FloorConfig has duplicate order")
	assert(
		type(definition.GridColorTuningId) == "string" and not seenGridColorTuningIds[definition.GridColorTuningId],
		"FloorConfig requires one unique grid-color tuning id per floor"
	)
	byId[definition.Id] = definition
	byOrder[definition.Order] = definition
	seenGridColorTuningIds[definition.GridColorTuningId] = true

	for _, buildingId in ipairs(definition.BuildingIds) do
		assert(themedFloorByBuildingId[buildingId] == nil, "A building may belong to only one floor theme")
		themedFloorByBuildingId[buildingId] = definition.Id
	end
end

assert(
	#definitions == FloorConfig.UnlockableFloorCount + 1
		and byOrder[0]
		and byOrder[FloorConfig.UnlockableFloorCount],
	"Launch config requires Ground plus three floors"
)

function FloorConfig.GetDefinitions()
	return definitions
end

function FloorConfig.Get(floorId)
	return type(floorId) == "string" and byId[floorId] or nil
end

function FloorConfig.GetByOrder(order)
	return byOrder[tonumber(order)]
end

function FloorConfig.NormalizeId(floorId)
	return FloorConfig.Get(floorId) and floorId or FloorConfig.GroundFloorId
end

function FloorConfig.GetThemedFloorId(buildingId)
	return themedFloorByBuildingId[buildingId]
end

function FloorConfig.GetGridColorTuningId(floorId)
	local definition = FloorConfig.Get(floorId)
	return definition and definition.GridColorTuningId or nil
end

function FloorConfig.GetProductionMultiplier(floorId, buildingId)
	local definition = FloorConfig.Get(floorId)
	if definition and themedFloorByBuildingId[buildingId] == definition.Id then
		return definition.Multiplier
	end
	return 1
end

function FloorConfig.GetExpansionLevels()
	local levels = {}
	for order = 1, FloorConfig.UnlockableFloorCount do
		local definition = byOrder[order]
		table.insert(levels, {
			Cost = definition.Price,
			FloorId = definition.Id,
			Effects = { FloorUnlock = definition.Order },
			EffectText = "Unlock " .. definition.Theme .. " floor",
		})
	end
	return levels
end

return FloorConfig
