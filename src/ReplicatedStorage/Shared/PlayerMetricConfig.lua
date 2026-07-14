local Attrs = require(script.Parent.Attrs)

local PlayerMetricConfig = {}

-- Flat fields intentionally live in Persistent rather than a nested Metrics table.
-- PlayerDataService's whitelist merge can then add future counters to old saves
-- without interpreting free-form inventory maps as schemas.
PlayerMetricConfig.PersistentAttributes = {
	Attrs.LifetimeCookiesEarned,
	Attrs.ManualClicks,
	Attrs.ManualCookiesEarned,
	Attrs.BuildingCookiesEarned,
	Attrs.AutoclickCookiesEarned,
	Attrs.OfflineCookiesEarned,
	Attrs.RewardCookiesEarned,
	Attrs.StolenCookiesEarned,
	Attrs.OtherCookiesEarned,
	Attrs.CookiesSpent,
	Attrs.CookiesLostToTheft,
	Attrs.HighestCps,
	Attrs.GoldenCookiesEarned,
	Attrs.GoldenCookiesSpent,
	Attrs.BuildingsPlaced,
	Attrs.WheelSpins,
	Attrs.BestLoginStreak,
	Attrs.LongestSessionSeconds,
}

PlayerMetricConfig.CookieSources = {
	Manual = "Manual",
	Building = "Building",
	Autoclick = "Autoclick",
	Offline = "Offline",
	Reward = "Reward",
	Theft = "Theft",
	Other = "Other",
	Purchase = "Purchase",
	PendingPurchase = "PendingPurchase",
	Shield = "Shield",
	TheftLoss = "TheftLoss",
	Refund = "Refund",
	Admin = "Admin",
}

PlayerMetricConfig.IncomeAttributeBySource = {
	[PlayerMetricConfig.CookieSources.Manual] = Attrs.ManualCookiesEarned,
	[PlayerMetricConfig.CookieSources.Building] = Attrs.BuildingCookiesEarned,
	[PlayerMetricConfig.CookieSources.Autoclick] = Attrs.AutoclickCookiesEarned,
	[PlayerMetricConfig.CookieSources.Offline] = Attrs.OfflineCookiesEarned,
	[PlayerMetricConfig.CookieSources.Reward] = Attrs.RewardCookiesEarned,
	[PlayerMetricConfig.CookieSources.Theft] = Attrs.StolenCookiesEarned,
	[PlayerMetricConfig.CookieSources.Other] = Attrs.OtherCookiesEarned,
}

PlayerMetricConfig.IncomeProfiles = {
	{ Attribute = Attrs.ManualCookiesEarned, Label = "Manual clicks" },
	{ Attribute = Attrs.BuildingCookiesEarned, Label = "Buildings" },
	{ Attribute = Attrs.AutoclickCookiesEarned, Label = "Autoclicker" },
	{ Attribute = Attrs.OfflineCookiesEarned, Label = "Offline baking" },
	{ Attribute = Attrs.RewardCookiesEarned, Label = "Rewards" },
	{ Attribute = Attrs.StolenCookiesEarned, Label = "Cookie theft" },
	{ Attribute = Attrs.OtherCookiesEarned, Label = "Legacy / other" },
}

return PlayerMetricConfig
