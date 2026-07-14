local SkinRarityConfig = {}

SkinRarityConfig.MaxWheelMultiplier = 1.5
SkinRarityConfig.MaxExclusiveMultiplier = 1.75
SkinRarityConfig.LimitedRarityId = "Limited"
SkinRarityConfig.MythicalRarityId = "Mythical"
SkinRarityConfig.WheelRarities = {
	{ Id = "Common", DisplayName = "Common", Weight = 55, Multiplier = 1.05, Color = Color3.fromRGB(200, 200, 200) },
	{ Id = "Rare", DisplayName = "Rare", Weight = 27, Multiplier = 1.10, Color = Color3.fromRGB(90, 150, 255) },
	{ Id = "Epic", DisplayName = "Epic", Weight = 12, Multiplier = 1.25, Color = Color3.fromRGB(180, 90, 255) },
	{
		Id = "Legendary",
		DisplayName = "Legendary",
		Weight = 5,
		Multiplier = 1.50,
		Color = Color3.fromRGB(255, 200, 60),
	},
	{ Id = "Limited", DisplayName = "Limited", Weight = 1, Multiplier = 1.50, Color = Color3.fromRGB(255, 90, 120) },
}

SkinRarityConfig.ById = {}
for _, rarity in ipairs(SkinRarityConfig.WheelRarities) do
	SkinRarityConfig.ById[rarity.Id] = rarity
end
SkinRarityConfig.ById.Default =
	{ Id = "Default", DisplayName = "Default", Multiplier = 1, Color = Color3.fromRGB(0, 170, 255) }
-- Exclusive definitions own their individual multiplier; rarity is display metadata only.
SkinRarityConfig.ById.Mythical = { Id = "Mythical", DisplayName = "Mythical", Color = Color3.fromRGB(255, 95, 205) }

function SkinRarityConfig.Roll(random)
	local totalWeight = 0
	for _, rarity in ipairs(SkinRarityConfig.WheelRarities) do
		local weight = tonumber(rarity.Weight)
		assert(weight and weight > 0, ("Wheel rarity %s must have a positive weight"):format(tostring(rarity.Id)))
		totalWeight += weight
	end
	assert(totalWeight > 0, "Wheel rarity weights must have a nonzero total")

	local roll = random:NextNumber(0, totalWeight)
	local cumulative = 0
	for _, rarity in ipairs(SkinRarityConfig.WheelRarities) do
		cumulative += rarity.Weight
		if roll < cumulative then
			return rarity.Id
		end
	end
	return SkinRarityConfig.WheelRarities[#SkinRarityConfig.WheelRarities].Id
end

return SkinRarityConfig
