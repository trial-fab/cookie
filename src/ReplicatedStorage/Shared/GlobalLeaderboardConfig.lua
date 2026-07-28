local Attrs = require(script.Parent.Attrs)

local GlobalLeaderboardConfig = {}

GlobalLeaderboardConfig.TopCount = 10
GlobalLeaderboardConfig.RefreshSeconds = 120

GlobalLeaderboardConfig.Definitions = {
	{
		Id = "LifetimeCookies",
		Attribute = Attrs.LifetimeCookiesEarned,
		StoreSuffix = "LifetimeCookies",
		Heading = "LIFETIME COOKIES",
		Format = "Number",
		HudName = "Hud1",
	},
	{
		Id = "HighestCps",
		Attribute = Attrs.HighestCps,
		StoreSuffix = "HighestCps",
		Heading = "HIGHEST CPS",
		Format = "Rate",
		HudName = "Hud2",
	},
	{
		Id = "ManualClicks",
		Attribute = Attrs.ManualClicks,
		StoreSuffix = "ManualClicks",
		Heading = "MANUAL CLICKS",
		Format = "Number",
		HudName = "Hud3",
	},
}

GlobalLeaderboardConfig.ById = {}
for _, definition in ipairs(GlobalLeaderboardConfig.Definitions) do
	GlobalLeaderboardConfig.ById[definition.Id] = definition
end

return GlobalLeaderboardConfig
