-- XpConfig: shared XP curve, titles, and default source values.
--
-- Server code owns total XP awards. Clients derive level/title/progress from the
-- replicated total so the display cannot drift from the saved value.

local XpConfig = {}

XpConfig.Sources = {
	ManualClick = 1,
	BuildingUnlockBase = 25,
}

XpConfig.AutoTitleId = ""

XpConfig.Titles = {
	{ Id = "FreshlyBaked", MinLevel = 1, Title = "Freshly Baked" },
	{ Id = "GooFriend", MinLevel = 3, Title = "Goo Friend" },
	{ Id = "DoughDabbler", MinLevel = 5, Title = "Dough Dabbler" },
	{ Id = "SparkSlinger", MinLevel = 8, Title = "Spark Slinger" },
	{ Id = "LifeOfTheParty", MinLevel = 10, Title = "Life of the Party" },
	{ Id = "CrumbCatalyst", MinLevel = 13, Title = "Crumb Catalyst" },
	{ Id = "DoughWhisperer", MinLevel = 16, Title = "Dough Whisperer" },
	{ Id = "GooGuardian", MinLevel = 20, Title = "Goo Guardian" },
	{ Id = "Lifeweaver", MinLevel = 24, Title = "Lifeweaver" },
	{ Id = "ColonyCrafter", MinLevel = 28, Title = "Colony Crafter" },
	{ Id = "TheBigRiser", MinLevel = 32, Title = "The Big Riser" },
	{ Id = "Worldbaker", MinLevel = 36, Title = "Worldbaker" },
	{ Id = "PlanetProofer", MinLevel = 40, Title = "Planet Proofer" },
	{ Id = "GenesisChef", MinLevel = 45, Title = "Genesis Chef" },
	{ Id = "MakerOfMakers", MinLevel = 50, Title = "Maker of Makers" },
}

XpConfig.TitlesById = {}
for index, entry in ipairs(XpConfig.Titles) do
	entry.Order = index
	XpConfig.TitlesById[entry.Id] = entry
end

local BASE_LEVEL_XP = 100
local LEVEL_XP_GROWTH = 1.18

function XpConfig.GetXpNeededForLevel(level)
	level = math.max(1, math.floor(tonumber(level) or 1))
	return math.max(1, math.floor(BASE_LEVEL_XP * (LEVEL_XP_GROWTH ^ (level - 1)) + 0.5))
end

function XpConfig.GetTitleDefForLevel(level)
	level = math.max(1, math.floor(tonumber(level) or 1))

	local titleDef = XpConfig.Titles[1]
	for _, entry in ipairs(XpConfig.Titles) do
		local minLevel = tonumber(entry.MinLevel) or 1
		if level >= minLevel then
			titleDef = entry
		end
	end

	return titleDef
end

function XpConfig.GetTitleDefById(titleId)
	return type(titleId) == "string" and XpConfig.TitlesById[titleId] or nil
end

function XpConfig.IsTitleUnlocked(titleId, level)
	local titleDef = XpConfig.GetTitleDefById(titleId)
	level = math.max(1, math.floor(tonumber(level) or 1))
	return titleDef ~= nil and level >= titleDef.MinLevel
end

function XpConfig.NormalizeSelectedTitleId(titleId, level)
	if titleId == XpConfig.AutoTitleId then
		return XpConfig.AutoTitleId
	end
	return XpConfig.IsTitleUnlocked(titleId, level) and titleId or XpConfig.AutoTitleId
end

function XpConfig.GetEquippedTitleDef(level, selectedTitleId)
	local normalized = XpConfig.NormalizeSelectedTitleId(selectedTitleId, level)
	return normalized == XpConfig.AutoTitleId and XpConfig.GetTitleDefForLevel(level)
		or XpConfig.GetTitleDefById(normalized),
		normalized
end

function XpConfig.GetTitleForLevel(level)
	local titleDef = XpConfig.GetTitleDefForLevel(level)
	return titleDef and titleDef.Title or ""
end

function XpConfig.GetBuildingUnlockXp(_upgradeId, _config)
	return XpConfig.Sources.BuildingUnlockBase
end

function XpConfig.GetLevelInfo(totalXp, selectedTitleId)
	totalXp = math.max(0, math.floor(tonumber(totalXp) or 0))

	local remaining = totalXp
	local level = 1
	local needed = XpConfig.GetXpNeededForLevel(level)

	while remaining >= needed do
		remaining -= needed
		level += 1
		needed = XpConfig.GetXpNeededForLevel(level)
	end

	local progress = needed > 0 and math.clamp(remaining / needed, 0, 1) or 0
	local latestTitleDef = XpConfig.GetTitleDefForLevel(level)
	local equippedTitleDef, normalizedTitleId = XpConfig.GetEquippedTitleDef(level, selectedTitleId)
	return {
		totalXp = totalXp,
		level = level,
		title = equippedTitleDef and equippedTitleDef.Title or "",
		titleId = equippedTitleDef and equippedTitleDef.Id or "",
		titleDef = equippedTitleDef,
		latestTitleDef = latestTitleDef,
		selectedTitleId = normalizedTitleId,
		autoEquipTitle = normalizedTitleId == XpConfig.AutoTitleId,
		currentXp = remaining,
		neededXp = needed,
		progress = progress,
	}
end

return XpConfig
