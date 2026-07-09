-- WheelConfig — the golden-cookie wheel + skin economy (economy-rebalance-spec §7).
--
-- These numbers are a fixed contract with the spec. Do NOT change spin cost,
-- odds, the duplicate refund, or any rarity multiplier without re-opening
-- docs/economy-rebalance-spec.md §7. Design invariant 2: the legendary skin
-- multiplier is capped at ×1.5 — no future skin may exceed it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local WheelConfig = {}

-- Spending: the only sink for golden cookies (spec §6 isolation rules).
WheelConfig.SpinCost = 75
WheelConfig.DuplicateRefundGC = 30

-- Wheel/RNG skin cap (design invariant 2): no skin obtainable from the wheel may exceed ×1.5.
WheelConfig.MaxSkinMultiplier = 1.5

-- Exclusive (non-wheel) skins get a higher ceiling. The day-7 daily-streak "Mythical"
-- building skin is a *playtime* reward — never rolled by the wheel — so it sits above the
-- ×1.5 wheel cap. This intentionally exceeds invariant 2's ×1.5 wording, which covers wheel
-- skins only; the wheel itself still obeys MaxSkinMultiplier above.
WheelConfig.MaxExclusiveSkinMultiplier = 1.75
WheelConfig.MythicalRarityId = "Mythical"
WheelConfig.MythicalMultiplier = 1.75

-- Wheel odds (spec §7). Weights sum to 100. "Limited" has no production
-- multiplier — it is a purely cosmetic building reward.
WheelConfig.Rarities = {
	{ Id = "Common", DisplayName = "Common", Weight = 55, Multiplier = 1.05, Color = Color3.fromRGB(200, 200, 200) },
	{ Id = "Rare", DisplayName = "Rare", Weight = 27, Multiplier = 1.10, Color = Color3.fromRGB(90, 150, 255) },
	{ Id = "Epic", DisplayName = "Epic", Weight = 12, Multiplier = 1.25, Color = Color3.fromRGB(180, 90, 255) },
	{ Id = "Legendary", DisplayName = "Legendary", Weight = 5, Multiplier = 1.50, Color = Color3.fromRGB(255, 200, 60) },
	{ Id = "Limited", DisplayName = "Limited", Weight = 1, Multiplier = nil, Color = Color3.fromRGB(255, 90, 120) },
}

WheelConfig.LimitedRarityId = "Limited"

-- Starter cosmetic-building set awarded by the 1% "Limited" slot. Visual/3D work
-- can trail the system (spec §7) — these are inventory entries for now.
WheelConfig.LimitedBuildings = {
	"Galaxy Cookie Tree",
	"Crystal Cookie Fountain",
	"Aurora Cookie Spire",
}

-- Buildings that have a "Mythical" skin variant — the day-7 daily-streak reward
-- (DailyRewardConfig). Registered in SkinRegistry so they equip/show like any other skin,
-- but kept OUT of the wheel roll (rollReward only uses EligibleBuildings × SkinRarities).
-- Configurable: add buildings here to offer more mythical variants.
WheelConfig.MythicalBuildings = {
	"Cookie Factory",
}

local SKIN_ID_SEPARATOR = "::"

WheelConfig.RarityById = {}
for _, rarity in ipairs(WheelConfig.Rarities) do
	WheelConfig.RarityById[rarity.Id] = rarity
end

-- "Mythical" is registered for display (color/name) but deliberately NOT added to the
-- weighted Rarities table above, so RollRarity can never roll it. Exclusive to daily streaks.
WheelConfig.RarityById[WheelConfig.MythicalRarityId] = {
	Id = WheelConfig.MythicalRarityId,
	DisplayName = "Mythical",
	Multiplier = WheelConfig.MythicalMultiplier,
	Color = Color3.fromRGB(255, 95, 205),
}

-- Eligible buildings = the cookie producers (positive CookiesGained). Defense
-- buildings (negative upkeep) never receive skins. Derived from UpgradeConfig so
-- the skin set stays in sync with the building ladder (spec §3).
local function buildEligibleBuildings()
	local buildings = {}
	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "Building" and (config.CookiesGained or 0) > 0 then
			table.insert(buildings, upgradeId)
		end
	end

	table.sort(buildings, function(a, b)
		local costA = UpgradeConfig[a].BaseCost or 0
		local costB = UpgradeConfig[b].BaseCost or 0
		if costA == costB then
			return a < b
		end
		return costA < costB
	end)

	return buildings
end

WheelConfig.EligibleBuildings = buildEligibleBuildings()

-- Multiplier-bearing rarities (everything except the cosmetic-only "Limited").
WheelConfig.SkinRarities = {}
for _, rarity in ipairs(WheelConfig.Rarities) do
	if rarity.Multiplier ~= nil then
		table.insert(WheelConfig.SkinRarities, rarity.Id)
	end
end

function WheelConfig.MakeSkinId(buildingId, rarityId)
	return tostring(buildingId) .. SKIN_ID_SEPARATOR .. tostring(rarityId)
end

function WheelConfig.MakeLimitedSkinId(buildingName)
	return WheelConfig.LimitedRarityId .. SKIN_ID_SEPARATOR .. tostring(buildingName)
end

-- Full skin registry: one skin per (producer building × multiplier rarity),
-- plus one cosmetic entry per limited building.
local function buildSkinRegistry()
	local registry = {}

	for _, buildingId in ipairs(WheelConfig.EligibleBuildings) do
		local buildingConfig = UpgradeConfig[buildingId]
		local buildingName = (buildingConfig and buildingConfig.DisplayName) or buildingId
		for _, rarityId in ipairs(WheelConfig.SkinRarities) do
			local rarity = WheelConfig.RarityById[rarityId]
			local skinId = WheelConfig.MakeSkinId(buildingId, rarityId)
			registry[skinId] = {
				Id = skinId,
				BuildingId = buildingId,
				RarityId = rarityId,
				DisplayName = ("%s %s Skin"):format(buildingName, rarity.DisplayName),
				Multiplier = rarity.Multiplier,
				IsLimited = false,
			}
		end
	end

	for _, buildingName in ipairs(WheelConfig.LimitedBuildings) do
		local skinId = WheelConfig.MakeLimitedSkinId(buildingName)
		registry[skinId] = {
			Id = skinId,
			BuildingId = nil,
			RarityId = WheelConfig.LimitedRarityId,
			DisplayName = buildingName,
			Multiplier = nil,
			IsLimited = true,
		}
	end

	-- Mythical building skins (daily day-7 reward). Equippable like wheel skins (BuildingId
	-- set, not limited) but flagged IsExclusive so GetSkinMultiplier lets them past the ×1.5
	-- wheel cap up to MaxExclusiveSkinMultiplier. Not part of the wheel roll.
	for _, buildingId in ipairs(WheelConfig.MythicalBuildings) do
		local buildingConfig = UpgradeConfig[buildingId]
		local buildingName = (buildingConfig and buildingConfig.DisplayName) or buildingId
		local skinId = WheelConfig.MakeSkinId(buildingId, WheelConfig.MythicalRarityId)
		registry[skinId] = {
			Id = skinId,
			BuildingId = buildingId,
			RarityId = WheelConfig.MythicalRarityId,
			DisplayName = ("%s Mythical Skin"):format(buildingName),
			Multiplier = WheelConfig.MythicalMultiplier,
			IsLimited = false,
			IsExclusive = true,
		}
	end

	return registry
end

WheelConfig.SkinRegistry = buildSkinRegistry()

function WheelConfig.GetSkinDef(skinId)
	if type(skinId) ~= "string" then
		return nil
	end
	return WheelConfig.SkinRegistry[skinId]
end

-- Multiplier an equipped skin contributes to its building's production. Limited
-- cosmetics and unknown ids contribute nothing (×1). Clamped to the invariant.
function WheelConfig.GetSkinMultiplier(skinId)
	local def = WheelConfig.GetSkinDef(skinId)
	if not def or type(def.Multiplier) ~= "number" then
		return 1
	end
	-- Exclusive (mythical) skins clamp to the higher exclusive ceiling; all wheel skins to ×1.5.
	local ceiling = def.IsExclusive and WheelConfig.MaxExclusiveSkinMultiplier or WheelConfig.MaxSkinMultiplier
	return math.clamp(def.Multiplier, 0, ceiling)
end

-- Weighted rarity roll. `random` is a Random instance supplied by the caller so
-- the server owns the RNG source.
function WheelConfig.RollRarity(random)
	local totalWeight = 0
	for _, rarity in ipairs(WheelConfig.Rarities) do
		totalWeight += rarity.Weight
	end

	local roll = random:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, rarity in ipairs(WheelConfig.Rarities) do
		cumulative += rarity.Weight
		if roll <= cumulative then
			return rarity.Id
		end
	end

	return WheelConfig.Rarities[#WheelConfig.Rarities].Id
end

return WheelConfig
