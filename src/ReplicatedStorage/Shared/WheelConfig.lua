-- Shared wheel facade. Goo skins are the active prize family; building skins are dormant.
local SkinFeatureConfig = require(script.Parent.SkinFeatureConfig)
local SkinRarityConfig = require(script.Parent.SkinRarityConfig)
local GooSkinConfig = require(script.Parent.GooSkinConfig)
local BuildingSkinConfig = require(script.Parent.BuildingSkinConfig)

local WheelConfig = {
	SpinCost = 75,
	DuplicateRefundGC = 30,
	MaxSkinMultiplier = SkinRarityConfig.MaxWheelMultiplier,
	MaxExclusiveSkinMultiplier = SkinRarityConfig.MaxExclusiveMultiplier,
	MythicalRarityId = SkinRarityConfig.MythicalRarityId,
	LimitedRarityId = SkinRarityConfig.LimitedRarityId,
	Rarities = SkinRarityConfig.WheelRarities,
	RarityById = SkinRarityConfig.ById,
	GooSkinDefinitions = GooSkinConfig.Definitions,
	GooSkinRegistry = GooSkinConfig.ById,
	BuildingSkinRegistry = BuildingSkinConfig.Registry,
	DefaultGooSkinId = GooSkinConfig.DefaultSkinId,
	DailyGooSkinId = GooSkinConfig.DailySkinId,
	FeatureFlags = SkinFeatureConfig,
	EligibleBuildings = BuildingSkinConfig.EligibleBuildings,
	LimitedBuildings = BuildingSkinConfig.LimitedBuildings,
	MythicalBuildings = BuildingSkinConfig.MythicalBuildings,
	SkinRarities = BuildingSkinConfig.SkinRarities,
}

WheelConfig.SkinRegistry = {}
for id, def in pairs(GooSkinConfig.ById) do
	WheelConfig.SkinRegistry[id] = def
end
for id, def in pairs(BuildingSkinConfig.Registry) do
	WheelConfig.SkinRegistry[id] = def
end

WheelConfig.MakeSkinId = BuildingSkinConfig.MakeSkinId
WheelConfig.MakeLimitedSkinId = BuildingSkinConfig.MakeLimitedSkinId

function WheelConfig.GetSkinDef(id)
	return GooSkinConfig.GetSkinDef(id) or BuildingSkinConfig.GetSkinDef(id)
end
function WheelConfig.GetSkinMultiplier(id)
	local def = WheelConfig.GetSkinDef(id)
	if not def then
		return 1
	end
	return def.Kind == "Goo" and GooSkinConfig.GetMultiplier(id) or BuildingSkinConfig.GetMultiplier(id)
end
function WheelConfig.GetRollableGooSkins(rarityId)
	return GooSkinConfig.GetRollable(rarityId)
end
function WheelConfig.RollRarity(random)
	return SkinRarityConfig.Roll(random)
end

return WheelConfig
