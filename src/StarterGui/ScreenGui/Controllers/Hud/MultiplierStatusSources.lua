-- MultiplierStatusSources: builds an always-available, player-wide explanation of every
-- active production multiplier. Sources are grouped by meaning rather than selected building.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local BoostShopConfig = require(Shared:WaitForChild("BoostShopConfig"))
local FloorConfig = require(Shared:WaitForChild("FloorConfig"))
local ProductionFormula = require(Shared:WaitForChild("ProductionFormula"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))

local MultiplierStatusSources = {}

local EPSILON = 1e-6

local function isActive(multiplier)
	return type(multiplier) == "number" and math.abs(multiplier - 1) > EPSILON
end

local function getObjectValue(parent, name)
	local value = parent and parent:FindFirstChild(name)
	return value and value:IsA("ObjectValue") and value.Value or nil
end

local function getPlayerSheet(player)
	local sheets = Workspace:FindFirstChild("CookieSheets")
	if not sheets then
		return nil
	end
	for _, sheet in ipairs(sheets:GetChildren()) do
		if getObjectValue(sheet, "SheetOwner") == player then
			return sheet
		end
	end
	return nil
end

local function getDisplayName(buildingId)
	local config = UpgradeConfig[buildingId]
	return tostring(config and config.DisplayName or buildingId)
end

local function sortedNames(set)
	local names = {}
	for name in pairs(set) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function addAffected(source, building)
	source._affectedNames[building.displayName] = true
	source._affectedCounts[building.displayName] = (source._affectedCounts[building.displayName] or 0) + 1
	source.AffectedCount += 1
end

local function finishSource(source)
	source.AffectedNames = source._affectedNameOrder or sortedNames(source._affectedNames)
	source.AffectedCounts = source._affectedCounts
	source._affectedNames = nil
	source._affectedNameOrder = nil
	source._affectedCounts = nil
	source.Active = isActive(source.Multiplier)
	return source
end

local function newProductionSource(fields)
	fields.AffectedCount = 0
	fields._affectedNames = {}
	fields._affectedCounts = {}
	return fields
end

local function collectBuildings(player, sheet)
	local buildings = {}
	if not sheet then
		return buildings
	end

	local skinMultiplierByBuildingId = {}
	local upgradeMultiplierByBuildingId = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and getObjectValue(child, "Owner") == player then
			local buildingId = child:GetAttribute(Attrs.UpgradeId)
			local config = type(buildingId) == "string" and UpgradeConfig[buildingId]
			if config and config.TemplateKind == "Building" then
				local floorId = FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId))
				local skinMultiplier = skinMultiplierByBuildingId[buildingId]
				if not skinMultiplier then
					skinMultiplier = ProductionFormula.GetSkinMultiplier(player, buildingId)
					skinMultiplierByBuildingId[buildingId] = skinMultiplier
				end
				local upgradeMultiplier = upgradeMultiplierByBuildingId[buildingId]
				if not upgradeMultiplier then
					upgradeMultiplier = ProductionFormula.GetUpgradeMultiplier(player, buildingId)
					upgradeMultiplierByBuildingId[buildingId] = upgradeMultiplier
				end
				local floorMultiplier = ProductionFormula.GetFloorMultiplier(buildingId, floorId)
				table.insert(buildings, {
					instance = child,
					displayName = getDisplayName(buildingId),
					floorId = floorId,
					skinMultiplier = skinMultiplier,
					upgradeMultiplier = upgradeMultiplier,
					floorMultiplier = floorMultiplier,
				})
			end
		end
	end
	return buildings
end

local function addGooSource(sources, player, buildings)
	local multiplier = ProductionFormula.GetGooSkinMultiplier(player)
	if not isActive(multiplier) then
		return
	end
	local source = newProductionSource({
		Id = "GooSkin",
		Kind = "Permanent",
		IconKey = "Goo",
		DisplayName = "Goo Boost",
		Multiplier = multiplier,
		CompactScope = "All buildings",
		Scope = "All your building production. Uses your strongest owned goo.",
	})
	for _, building in ipairs(buildings) do
		if math.abs(building.skinMultiplier - multiplier) <= EPSILON then
			addAffected(source, building)
		end
	end
	table.insert(sources, finishSource(source))
end

-- Player-global like the goo bonus rather than contextual, so every building is affected and the
-- scope copy names the one condition that actually gates it: those friends still being here.
local function addFriendSource(sources, player, buildings)
	local multiplier = ProductionFormula.GetFriendMultiplier(player)
	if not isActive(multiplier) then
		return
	end
	local friendCount = player:GetAttribute(Attrs.FriendBoostCount)
	friendCount = type(friendCount) == "number" and math.max(0, math.floor(friendCount)) or 0
	local source = newProductionSource({
		Id = "FriendBoost",
		Kind = "FriendBoost",
		IconKey = "FriendBoost",
		DisplayName = friendCount == 1 and "Friend Boost (1 friend)"
			or ("Friend Boost (%d friends)"):format(friendCount),
		Multiplier = multiplier,
		CompactScope = "All buildings and manual clicks",
		Scope = "All your building production and your manual clicks, while friends you brought here are online.",
	})
	for _, building in ipairs(buildings) do
		addAffected(source, building)
	end
	table.insert(sources, finishSource(source))
end

local function addUpgradeSources(sources, player, buildings)
	local byMultiplier = {}
	for _, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "BuildingUpgrade" and type(config.TargetBuilding) == "string" then
			local multiplier = ProductionFormula.GetUpgradeMultiplier(player, config.TargetBuilding)
			if isActive(multiplier) then
				local key = tostring(multiplier)
				local source = byMultiplier[key]
				if not source then
					source = newProductionSource({
						Id = "BuildingUpgradeGroup:" .. key,
						Kind = "BuildingUpgrade",
						IconKey = multiplier <= 2 + EPSILON and "UpgradeX2" or "UpgradeX4",
						DisplayName = "Building Upgrades",
						Multiplier = multiplier,
						Scope = "Permanent upgrades for the listed building types.",
					})
					byMultiplier[key] = source
				end
				source._affectedNames[getDisplayName(config.TargetBuilding)] = true
			end
		end
	end
	for _, building in ipairs(buildings) do
		local source = byMultiplier[tostring(building.upgradeMultiplier)]
		if source then
			addAffected(source, building)
		end
	end
	local ordered = {}
	for _, source in pairs(byMultiplier) do
		table.insert(ordered, finishSource(source))
	end
	table.sort(ordered, function(left, right)
		return left.Multiplier < right.Multiplier
	end)
	for _, source in ipairs(ordered) do
		table.insert(sources, source)
	end
end

local function addFloorSources(sources, player, buildings)
	local unlockedCount = math.max(0, tonumber(player:GetAttribute(Attrs.UnlockedFloorCount)) or 0)
	for _, definition in ipairs(FloorConfig.GetDefinitions()) do
		if definition.Order > 0 and definition.Order <= unlockedCount and isActive(definition.Multiplier) then
			local source = newProductionSource({
				Id = "Floor:" .. definition.Id,
				Kind = "Floor",
				IconKey = "Floor" .. tostring(definition.Order),
				DisplayName = definition.DisplayName,
				Multiplier = definition.Multiplier,
				_affectedNameOrder = {},
				Scope = "Buildings of this floor's matching types placed on this floor.",
			})
			for _, buildingId in ipairs(definition.BuildingIds) do
				local displayName = getDisplayName(buildingId)
				table.insert(source._affectedNameOrder, displayName)
				source._affectedNames[displayName] = true
				source._affectedCounts[displayName] = 0
			end
			for _, building in ipairs(buildings) do
				if building.floorId == definition.Id and isActive(building.floorMultiplier) then
					addAffected(source, building)
				end
			end
			table.insert(sources, finishSource(source))
		end
	end
end

local function fieldCovers(field, item, building)
	if building.floorId ~= FloorConfig.NormalizeId(field:GetAttribute(Attrs.FloorId)) then
		return false
	end
	local radius = tonumber(field:GetAttribute("Radius")) or item.Radius
	local delta = building.instance:GetPivot().Position - field:GetPivot().Position
	return delta.X * delta.X + delta.Z * delta.Z <= radius * radius
end

local function addFieldSources(sources, sheet, buildings)
	if not sheet then
		return
	end
	local prefix = BoostShopConfig.FieldNamePrefix
	local fields = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child.Name:sub(1, #prefix) == prefix then
			local itemId = child:GetAttribute("ItemId") or child.Name:sub(#prefix + 1)
			local item = BoostShopConfig.Items[itemId]
			if item then
				table.insert(fields, { instance = child, item = item })
			end
		end
	end
	table.sort(fields, function(left, right)
		local leftFloor = FloorConfig.Get(left.instance:GetAttribute(Attrs.FloorId))
		local rightFloor = FloorConfig.Get(right.instance:GetAttribute(Attrs.FloorId))
		local leftOrder = leftFloor and leftFloor.Order or 0
		local rightOrder = rightFloor and rightFloor.Order or 0
		if leftOrder == rightOrder then
			return (table.find(BoostShopConfig.Order, left.item.Id) or 99)
				< (table.find(BoostShopConfig.Order, right.item.Id) or 99)
		end
		return leftOrder < rightOrder
	end)

	for _, entry in ipairs(fields) do
		local field = entry.instance
		local item = entry.item
		local strengthPercent = tonumber(field:GetAttribute("StrengthPercent")) or item.StrengthPercent
		local multiplier = 1 + strengthPercent / 100
		local floorId = FloorConfig.NormalizeId(field:GetAttribute(Attrs.FloorId))
		local source = newProductionSource({
			Id = ("BoostField:%s:%s"):format(floorId, item.Id),
			Kind = "BoostField",
			IconKey = item.Id,
			DisplayName = item.DisplayName,
			Multiplier = multiplier,
			RemainingInstance = field,
		})
		for _, building in ipairs(buildings) do
			if fieldCovers(field, item, building) then
				addAffected(source, building)
			end
		end
		table.insert(sources, finishSource(source))
	end
end

local function addEventSources(sources, buildings)
	for _, event in ipairs(ProductionFormula.GetEventMultiplierBreakdown().Sources) do
		if event.Active then
			local source = newProductionSource({
				Id = event.Id,
				Kind = event.Kind,
				IconKey = event.Kind == "ServerBoost" and "ServerBoost" or "Event",
				DisplayName = event.DisplayName,
				Multiplier = event.Multiplier,
				ExpiresAt = event.ExpiresAt,
				CompactScope = "All server income",
				Scope = event.Scope,
			})
			for _, building in ipairs(buildings) do
				addAffected(source, building)
			end
			table.insert(sources, finishSource(source))
		end
	end
end

function MultiplierStatusSources.get(player)
	local sources = {}
	local sheet = getPlayerSheet(player)
	local buildings = collectBuildings(player, sheet)
	addGooSource(sources, player, buildings)
	addFriendSource(sources, player, buildings)
	addUpgradeSources(sources, player, buildings)
	addFloorSources(sources, player, buildings)
	addFieldSources(sources, sheet, buildings)
	addEventSources(sources, buildings)
	return sources
end

return MultiplierStatusSources
