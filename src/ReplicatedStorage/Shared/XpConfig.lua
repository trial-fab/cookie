-- XpConfig: shared XP curve, titles, and default source values.
--
-- Server code owns total XP awards. Clients derive level/title/progress from the
-- replicated total so the display cannot drift from the saved value.

local XpConfig = {}

XpConfig.Sources = {
	ManualClick = 1,
	BuildingUnlockBase = 25,
}

XpConfig.Titles = {
	{ MinLevel = 1, Title = "Newbie" },
	{ MinLevel = 5, Title = "Apprentice" },
	{ MinLevel = 10, Title = "Cookie Crafter" },
	{ MinLevel = 20, Title = "Baker" },
	{ MinLevel = 28, Title = "Master" },
	{ MinLevel = 40, Title = "Legend" },
}

local BASE_LEVEL_XP = 100
local LEVEL_XP_GROWTH = 1.18

function XpConfig.GetXpNeededForLevel(level)
	level = math.max(1, math.floor(tonumber(level) or 1))
	return math.max(1, math.floor(BASE_LEVEL_XP * (LEVEL_XP_GROWTH ^ (level - 1)) + 0.5))
end

function XpConfig.GetTitleForLevel(level)
	level = math.max(1, math.floor(tonumber(level) or 1))

	local title = XpConfig.Titles[1] and XpConfig.Titles[1].Title or ""
	for _, entry in ipairs(XpConfig.Titles) do
		local minLevel = tonumber(entry.MinLevel) or 1
		if level >= minLevel then
			title = entry.Title or title
		end
	end

	return title
end

function XpConfig.GetBuildingUnlockXp(_upgradeId, _config)
	return XpConfig.Sources.BuildingUnlockBase
end

function XpConfig.GetLevelInfo(totalXp)
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
	return {
		totalXp = totalXp,
		level = level,
		title = XpConfig.GetTitleForLevel(level),
		currentXp = remaining,
		neededXp = needed,
		progress = progress,
	}
end

return XpConfig
