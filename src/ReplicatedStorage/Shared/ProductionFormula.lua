local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UpgradeConfig = require(script.Parent.UpgradeConfig)
local WheelConfig = require(script.Parent.WheelConfig)
local Attrs = require(script.Parent.Attrs)
local FloorConfig = require(script.Parent.FloorConfig)
local FriendBoostConfig = require(script.Parent.FriendBoostConfig)
local SkinFeatureConfig = require(script.Parent.SkinFeatureConfig)

local ProductionFormula = {}

-- Defensive ceiling at production-tick time. WheelService already clamps each stored skin
-- value via WheelConfig.GetSkinMultiplier (wheel skins ≤×1.5, exclusive/mythical ≤×1.75), so
-- this is a backstop set to the highest legitimate value — the exclusive ceiling — and must
-- not sit below it or it would silently neuter the day-7 mythical reward.
local MAX_SKIN_MULTIPLIER = WheelConfig.MaxExclusiveSkinMultiplier
-- Same idea for the Friend Boost, whose transport to this module is a Player attribute: clamp to
-- the highest value the tuning bounds allow so a stale or corrupted attribute cannot inflate pay.
local MAX_FRIEND_MULTIPLIER = FriendBoostConfig.CeilingMultiplier()
local WORLD_EVENT_FOLDER_NAME = "WorldEventMultipliers"
local SERVER_BOOST_VALUE_NAME = "ServerBoost"
local SERVER_BOOST_ENDS_AT_ATTRIBUTE = "ServerBoostEndsAt"

local function isActiveMultiplier(value)
	return type(value) == "number" and math.abs(value - 1) > 1e-6
end

local function displayNameFromId(id)
	local text = tostring(id or "Multiplier")
	text = text:gsub("[_%-]+", " ")
	text = text:gsub("(%l)(%u)", "%1 %2")
	return text
end

local function addSource(sources, source)
	source.Active = isActiveMultiplier(source.Multiplier)
	table.insert(sources, source)
end

local function getUpgradeCount(player, upgradeId, context)
	if type(context) == "table" and type(context.UpgradeCounts) == "table" then
		return tonumber(context.UpgradeCounts[upgradeId]) or 0
	end

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

function ProductionFormula.GetUpgradeMultiplier(player, buildingId, context)
	local multiplier = 1

	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "BuildingUpgrade" and config.TargetBuilding == buildingId and config.Levels then
			local levelsOwned = getUpgradeCount(player, upgradeId, context)
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

-- Clients read the equipped-skin projection from EquippedSkinData. Server production supplies
-- an optional canonical skinContext so replicated values never become server authority.
function ProductionFormula.GetBuildingSkinMultiplier(player, buildingId, skinContext)
	if not SkinFeatureConfig.BuildingSkinsEnabled then
		return 1
	end
	if type(skinContext) == "table" and type(skinContext.BuildingMultiplier) == "number" then
		return math.clamp(skinContext.BuildingMultiplier, 0, MAX_SKIN_MULTIPLIER)
	end
	local multiplier = 1

	local skinData = player and player:FindFirstChild("EquippedSkinData")
	local value = skinData and skinData:FindFirstChild(buildingId)
	if value and (value:IsA("NumberValue") or value:IsA("IntValue")) and value.Value > 0 then
		multiplier = value.Value
	end

	return math.clamp(multiplier, 0, MAX_SKIN_MULTIPLIER)
end

function ProductionFormula.GetGooSkinMultiplier(player, skinContext)
	if not SkinFeatureConfig.GooSkinsEnabled then
		return 1
	end
	if type(skinContext) == "table" and type(skinContext.GooMultiplier) == "number" then
		return math.clamp(skinContext.GooMultiplier, 1, MAX_SKIN_MULTIPLIER)
	end
	local multiplier = player and player:GetAttribute(Attrs.GooSkinMultiplier)
	return math.clamp(type(multiplier) == "number" and multiplier or 1, 1, MAX_SKIN_MULTIPLIER)
end

-- Goo is universal; a future building-specific skin may override it for its building, but
-- bonuses never stack. This preserves a stable ceiling and lets both cosmetic families live
-- together later.
function ProductionFormula.GetSkinMultiplier(player, buildingId, skinContext)
	return math.max(
		ProductionFormula.GetGooSkinMultiplier(player, skinContext),
		ProductionFormula.GetBuildingSkinMultiplier(player, buildingId, skinContext)
	)
end

-- Presence-based and session-only: FriendBoostService recomputes it whenever a linked player joins
-- or leaves and publishes it on the Player. Server production passes the canonical value on the
-- context (and offline-earnings callers pass 1, since the friend was not there while the player
-- was away); clients read the replicated attribute.
function ProductionFormula.GetFriendMultiplier(player, context)
	if type(context) == "table" and type(context.FriendMultiplier) == "number" then
		return math.clamp(context.FriendMultiplier, 1, MAX_FRIEND_MULTIPLIER)
	end
	local multiplier = player and player:GetAttribute(Attrs.FriendBoostMultiplier)
	return math.clamp(type(multiplier) == "number" and multiplier or 1, 1, MAX_FRIEND_MULTIPLIER)
end

local function getFriendSource(player, context)
	return {
		Id = "FriendBoost",
		Kind = "FriendBoost",
		DisplayName = "Friend Boost",
		Multiplier = ProductionFormula.GetFriendMultiplier(player, context),
		Contextual = false,
		ServerWide = false,
		Scope = "All your building production and your manual clicks, while friends you brought here are online.",
	}
end

local function getEventExpiry(source)
	local endsAt = source:GetAttribute("EndsAt")
	if type(endsAt) == "number" then
		return endsAt
	end
	if source.Name == SERVER_BOOST_VALUE_NAME then
		local serverBoostEndsAt = ReplicatedStorage:GetAttribute(SERVER_BOOST_ENDS_AT_ATTRIBUTE)
		return type(serverBoostEndsAt) == "number" and serverBoostEndsAt or nil
	end
	return nil
end

-- Returns every replicated world-event multiplier as its own source. The same ordered
-- list is multiplied by GetEventMultiplier, so HUD callers cannot drift from production
-- or accidentally count the Server Boost twice.
function ProductionFormula.GetEventMultiplierBreakdown()
	local sources = {}
	local worldEventMultipliers = ReplicatedStorage:FindFirstChild(WORLD_EVENT_FOLDER_NAME)
	if not worldEventMultipliers then
		return { Sources = sources, Total = 1 }
	end

	local total = 1
	local attributes = worldEventMultipliers:GetAttributes()
	local attributeNames = {}
	for name, value in pairs(attributes) do
		if typeof(value) == "number" then
			table.insert(attributeNames, name)
		end
	end
	table.sort(attributeNames)
	for _, name in ipairs(attributeNames) do
		local value = attributes[name]
		total *= value
		addSource(sources, {
			Id = "WorldEventAttribute:" .. name,
			Kind = "Event",
			DisplayName = displayNameFromId(name),
			Multiplier = value,
			Contextual = false,
			ServerWide = true,
			Scope = "Entire server. Building production, manual clicks, autoclick income, and offline claim calculations.",
		})
	end

	local values = {}
	for _, child in ipairs(worldEventMultipliers:GetChildren()) do
		if child:IsA("NumberValue") or child:IsA("IntValue") then
			table.insert(values, child)
		end
	end
	table.sort(values, function(left, right)
		return left.Name < right.Name
	end)
	for _, valueObject in ipairs(values) do
		local value = valueObject.Value
		total *= value
		local isServerBoost = valueObject.Name == SERVER_BOOST_VALUE_NAME
		addSource(sources, {
			Id = "WorldEventValue:" .. valueObject.Name,
			Kind = isServerBoost and "ServerBoost" or "Event",
			DisplayName = isServerBoost and "Server Boost" or displayNameFromId(valueObject.Name),
			Multiplier = value,
			Contextual = false,
			ServerWide = true,
			ExpiresAt = getEventExpiry(valueObject),
			Scope = "Entire server. Building production, manual clicks, autoclick income, and offline claim calculations.",
		})
	end

	return {
		Sources = sources,
		Total = math.max(0, total),
	}
end

function ProductionFormula.GetEventMultiplier()
	return ProductionFormula.GetEventMultiplierBreakdown().Total
end

function ProductionFormula.GetFloorMultiplier(buildingId, floorContext)
	local floorId = floorContext
	if typeof(floorContext) == "Instance" then
		floorId = floorContext:GetAttribute(Attrs.FloorId)
	end
	return FloorConfig.GetProductionMultiplier(FloorConfig.NormalizeId(floorId), buildingId)
end

local function getSkinSource(player, buildingId, skinContext)
	local gooMultiplier = ProductionFormula.GetGooSkinMultiplier(player, skinContext)
	local buildingSkinMultiplier = type(buildingId) == "string"
			and ProductionFormula.GetBuildingSkinMultiplier(player, buildingId, skinContext)
		or 1
	if buildingSkinMultiplier > gooMultiplier then
		return {
			Id = "BuildingSkin:" .. tostring(buildingId),
			Kind = "Permanent",
			DisplayName = tostring(buildingId) .. " Skin",
			Multiplier = buildingSkinMultiplier,
			Contextual = true,
			ServerWide = false,
			Scope = "Only " .. tostring(buildingId) .. " production.",
		}
	end
	return {
		Id = "GooSkin",
		Kind = "Permanent",
		DisplayName = "Goo Bonus",
		Multiplier = gooMultiplier,
		Contextual = false,
		ServerWide = false,
		Scope = "All your building production. Uses your strongest owned goo.",
	}
end

-- Focused player-facing breakdown of the exact factors used for one building context.
-- Sources with x1 remain in the result for diagnostics, but Active=false lets HUD callers
-- hide them without having to reinterpret production math.
function ProductionFormula.GetMultiplierBreakdown(player, buildingId, config, floorContext, skinContext)
	if not config or config.TemplateKind ~= "Building" then
		return { Sources = {}, Total = 1 }
	end

	local sources = {}
	local skinSource = getSkinSource(player, buildingId, skinContext)
	addSource(sources, skinSource)

	local friendSource = getFriendSource(player, skinContext)
	addSource(sources, friendSource)

	local upgradeMultiplier = ProductionFormula.GetUpgradeMultiplier(player, buildingId, skinContext)
	addSource(sources, {
		Id = "BuildingUpgrade:" .. tostring(buildingId),
		Kind = "BuildingUpgrade",
		DisplayName = tostring(config.DisplayName or buildingId) .. " Upgrades",
		Multiplier = upgradeMultiplier,
		Contextual = true,
		ServerWide = false,
		Scope = "Only " .. tostring(config.DisplayName or buildingId) .. " production on every floor.",
	})

	local floorId = floorContext
	if typeof(floorContext) == "Instance" then
		floorId = floorContext:GetAttribute(Attrs.FloorId)
	end
	floorId = FloorConfig.NormalizeId(floorId)
	local floorMultiplier = ProductionFormula.GetFloorMultiplier(buildingId, floorId)
	local floorDefinition = FloorConfig.Get(floorId)
	addSource(sources, {
		Id = "Floor:" .. floorId .. ":" .. tostring(buildingId),
		Kind = "Floor",
		DisplayName = floorDefinition and floorDefinition.DisplayName or "Floor Bonus",
		Multiplier = floorMultiplier,
		Contextual = true,
		ServerWide = false,
		Scope = "Only this " .. tostring(config.DisplayName or buildingId) .. " placed on this floor.",
		FloorId = floorId,
	})

	-- A dropped Power field boosts only the buildings its disc covers, so it arrives on the context
	-- the caller built for THIS group rather than being read from anywhere global. Routing it
	-- through the breakdown (instead of multiplying it in at the call site) is what keeps the HUD's
	-- explanation and the production math the same number.
	local powerFieldMultiplier = 1
	if type(skinContext) == "table" and type(skinContext.PowerFieldMultiplier) == "number" then
		powerFieldMultiplier = math.max(0, skinContext.PowerFieldMultiplier)
	end
	addSource(sources, {
		Id = "BoostField:Power",
		Kind = "BoostField",
		DisplayName = "Power Field",
		Multiplier = powerFieldMultiplier,
		Contextual = true,
		ServerWide = false,
		Scope = "Only buildings standing inside a dropped Power Field.",
	})

	local eventBreakdown = ProductionFormula.GetEventMultiplierBreakdown()
	for _, source in ipairs(eventBreakdown.Sources) do
		table.insert(sources, source)
	end

	return {
		Sources = sources,
		Total = upgradeMultiplier
			* skinSource.Multiplier
			* friendSource.Multiplier
			* eventBreakdown.Total
			* floorMultiplier
			* powerFieldMultiplier,
	}
end

-- Sources that apply identically to every one of the player's buildings. Contextual
-- building-upgrade and floor factors are intentionally absent until a building is selected
-- or placed, preventing the always-on HUD from implying that they affect all production.
function ProductionFormula.GetGlobalMultiplierBreakdown(player, skinContext)
	local sources = {}
	local skinSource = getSkinSource(player, nil, skinContext)
	addSource(sources, skinSource)
	local friendSource = getFriendSource(player, skinContext)
	addSource(sources, friendSource)
	local eventBreakdown = ProductionFormula.GetEventMultiplierBreakdown()
	for _, source in ipairs(eventBreakdown.Sources) do
		table.insert(sources, source)
	end
	return {
		Sources = sources,
		Total = skinSource.Multiplier * friendSource.Multiplier * eventBreakdown.Total,
	}
end

function ProductionFormula.GetMultiplier(player, buildingId, config, floorContext, skinContext)
	if not config or config.TemplateKind ~= "Building" then
		return 1
	end

	return ProductionFormula.GetMultiplierBreakdown(player, buildingId, config, floorContext, skinContext).Total
end

function ProductionFormula.GetCps(player, buildingId, config, floorContext, skinContext)
	if not config or config.TemplateKind ~= "Building" then
		return 0
	end

	local updateTime = math.max(1, config.UpdateTime or 30)
	local baseCps = (config.CookiesGained or 0) / updateTime
	return baseCps * ProductionFormula.GetMultiplier(player, buildingId, config, floorContext, skinContext)
end

function ProductionFormula.GetTickOutput(player, buildingId, config, floorContext, skinContext)
	if not config or config.TemplateKind ~= "Building" then
		return 0
	end

	return
		(config.CookiesGained or 0)
		* ProductionFormula.GetMultiplier(player, buildingId, config, floorContext, skinContext)
end

return ProductionFormula
