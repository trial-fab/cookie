local SkinRarityConfig = require(script.Parent.SkinRarityConfig)

local GooSkinConfig = {
	DefaultSkinId = "Goo::Default",
	DailySkinId = "Goo::Celestial",
}

local function skin(id, name, rarityId, multiplier, order, rollable, assetName)
	return {
		Id = id,
		Kind = "Goo",
		DisplayName = name,
		RarityId = rarityId,
		Multiplier = multiplier,
		Order = order,
		Rollable = rollable == true,
		IsExclusive = rarityId == "Mythical",
		IsLimited = rarityId == "Limited",
		AssetName = assetName,
	}
end

GooSkinConfig.Definitions = {
	skin("Goo::Default", "Classic Blue", "Default", 1.00, 1, false, "Default"),
	skin("Goo::Lime", "Lime", "Common", 1.05, 2, true, "Lime"),
	skin("Goo::Berry", "Berry", "Common", 1.05, 3, true, "Berry"),
	skin("Goo::Violet", "Violet", "Common", 1.05, 4, true, "Violet"),
	skin("Goo::Chrome", "Chrome", "Rare", 1.10, 5, true, "Chrome"),
	skin("Goo::Crystal", "Crystal", "Rare", 1.10, 6, true, "Crystal"),
	skin("Goo::Ember", "Ember", "Epic", 1.25, 7, true, "Ember"),
	skin("Goo::Nebula", "Nebula", "Epic", 1.25, 8, true, "Nebula"),
	skin("Goo::Titan", "Titan", "Legendary", 1.50, 9, true, "Titan"),
	skin("Goo::Prism", "Prism", "Limited", 1.50, 10, true, "Prism"),
	skin("Goo::Celestial", "Celestial", "Mythical", 1.75, 11, false, "Celestial"),
}

GooSkinConfig.ById = {}
GooSkinConfig.RollableByRarity = {}
for _, def in ipairs(GooSkinConfig.Definitions) do
	GooSkinConfig.ById[def.Id] = def
	if def.Rollable then
		local pool = GooSkinConfig.RollableByRarity[def.RarityId] or {}
		GooSkinConfig.RollableByRarity[def.RarityId] = pool
		table.insert(pool, def)
	end
end

function GooSkinConfig.GetSkinDef(id)
	return type(id) == "string" and GooSkinConfig.ById[id] or nil
end

function GooSkinConfig.GetRollable(rarityId)
	return GooSkinConfig.RollableByRarity[rarityId] or {}
end

function GooSkinConfig.GetMultiplier(id)
	local def = GooSkinConfig.GetSkinDef(id)
	if not def then
		return 1
	end
	local cap = def.IsExclusive and SkinRarityConfig.MaxExclusiveMultiplier or SkinRarityConfig.MaxWheelMultiplier
	return math.clamp(tonumber(def.Multiplier) or 1, 1, cap)
end

function GooSkinConfig.ValidateDefinitions()
	local errors = {}
	local ids = {}
	local orders = {}
	for _, def in ipairs(GooSkinConfig.Definitions) do
		if type(def.Id) ~= "string" or def.Id == "" or ids[def.Id] then
			table.insert(errors, ("Goo skin ID must be nonempty and unique: %s"):format(tostring(def.Id)))
		end
		ids[def.Id] = true
		if type(def.Order) ~= "number" or def.Order % 1 ~= 0 or def.Order < 1 or orders[def.Order] then
			table.insert(errors, ("Goo skin order must be a unique positive integer: %s"):format(tostring(def.Order)))
		end
		orders[def.Order] = true
		if type(def.Multiplier) ~= "number" or def.Multiplier < 1 then
			table.insert(errors, ("Goo skin %s has an invalid multiplier"):format(tostring(def.Id)))
		end
		if type(def.AssetName) ~= "string" or def.AssetName == "" then
			table.insert(errors, ("Goo skin %s has no AssetName"):format(tostring(def.Id)))
		end
		if def.Kind ~= "Goo" then
			table.insert(errors, ("Goo skin %s has incoherent Kind"):format(tostring(def.Id)))
		end
		if def.Rollable then
			local rarity = SkinRarityConfig.ById[def.RarityId]
			if not rarity then
				table.insert(
					errors,
					("Rollable goo skin %s has unknown rarity %s"):format(def.Id, tostring(def.RarityId))
				)
			elseif type(rarity.Multiplier) ~= "number" or def.Multiplier ~= rarity.Multiplier then
				table.insert(errors, ("Rollable goo skin %s does not match its rarity multiplier"):format(def.Id))
			end
			if def.Multiplier > SkinRarityConfig.MaxWheelMultiplier then
				table.insert(errors, ("Rollable goo skin %s exceeds the wheel multiplier cap"):format(def.Id))
			end
		end
	end
	for index = 1, #GooSkinConfig.Definitions do
		if not orders[index] then
			table.insert(errors, ("Goo skin order is missing position %d"):format(index))
		end
	end
	for _, rarity in ipairs(SkinRarityConfig.WheelRarities) do
		if #GooSkinConfig.GetRollable(rarity.Id) == 0 then
			table.insert(errors, ("Wheel rarity %s has no rollable goo skin"):format(rarity.Id))
		end
	end
	return errors
end

return GooSkinConfig
