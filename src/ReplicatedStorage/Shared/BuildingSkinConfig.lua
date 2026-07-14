-- Dormant building-skin family. Kept separate so it can later coexist with goo skins.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local SkinRarityConfig = require(script.Parent.SkinRarityConfig)

local BuildingSkinConfig = {
	LimitedBuildings = { "Galaxy Cookie Tree", "Crystal Cookie Fountain", "Aurora Cookie Spire" },
	MythicalBuildings = { "Cookie Factory" },
	SkinRarities = { "Common", "Rare", "Epic", "Legendary" },
}

local eligible = {}
for upgradeId, config in pairs(UpgradeConfig) do
	if config.TemplateKind == "Building" and (config.CookiesGained or 0) > 0 then
		table.insert(eligible, upgradeId)
	end
end
table.sort(eligible, function(a, b)
	local ac, bc = UpgradeConfig[a].BaseCost or 0, UpgradeConfig[b].BaseCost or 0
	return ac == bc and a < b or ac < bc
end)
BuildingSkinConfig.EligibleBuildings = eligible

function BuildingSkinConfig.MakeSkinId(buildingId, rarityId)
	return tostring(buildingId) .. "::" .. tostring(rarityId)
end
function BuildingSkinConfig.MakeLimitedSkinId(name)
	return "Limited::" .. tostring(name)
end

BuildingSkinConfig.Registry = {}
for _, buildingId in ipairs(eligible) do
	local name = UpgradeConfig[buildingId].DisplayName or buildingId
	for _, rarityId in ipairs(BuildingSkinConfig.SkinRarities) do
		local rarity = SkinRarityConfig.ById[rarityId]
		local id = BuildingSkinConfig.MakeSkinId(buildingId, rarityId)
		BuildingSkinConfig.Registry[id] = {
			Id = id,
			Kind = "Building",
			BuildingId = buildingId,
			RarityId = rarityId,
			DisplayName = ("%s %s Skin"):format(name, rarity.DisplayName),
			Multiplier = rarity.Multiplier,
			IsLimited = false,
		}
	end
end
for _, name in ipairs(BuildingSkinConfig.LimitedBuildings) do
	local id = BuildingSkinConfig.MakeLimitedSkinId(name)
	BuildingSkinConfig.Registry[id] =
		{ Id = id, Kind = "Building", RarityId = "Limited", DisplayName = name, IsLimited = true }
end
for _, buildingId in ipairs(BuildingSkinConfig.MythicalBuildings) do
	local name = UpgradeConfig[buildingId].DisplayName or buildingId
	local id = BuildingSkinConfig.MakeSkinId(buildingId, "Mythical")
	BuildingSkinConfig.Registry[id] = {
		Id = id,
		Kind = "Building",
		BuildingId = buildingId,
		RarityId = "Mythical",
		DisplayName = ("%s Mythical Skin"):format(name),
		Multiplier = 1.75,
		IsLimited = false,
		IsExclusive = true,
	}
end

function BuildingSkinConfig.GetSkinDef(id)
	return type(id) == "string" and BuildingSkinConfig.Registry[id] or nil
end
function BuildingSkinConfig.GetMultiplier(id)
	local def = BuildingSkinConfig.GetSkinDef(id)
	if not def or type(def.Multiplier) ~= "number" then
		return 1
	end
	local cap = def.IsExclusive and SkinRarityConfig.MaxExclusiveMultiplier or SkinRarityConfig.MaxWheelMultiplier
	return math.clamp(def.Multiplier, 1, cap)
end

return BuildingSkinConfig
