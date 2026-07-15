-- Single source of truth for every client<->server remote name.
-- Reference a remote as `Net.Names.PurchaseUpgrade` (or `RemoteNames.PurchaseUpgrade`).
-- A typo'd key resolves to `nil`, which `Net.event` rejects with an error at the call
-- site -- instead of the old failure mode where a misspelled string literal made the
-- client hang forever at `WaitForChild`.
return {
	-- client -> server request/response (RemoteFunction; result returns to the caller)
	PurchaseUpgrade = "PurchaseUpgrade",
	SellUpgrade = "SellUpgrade",
	SellAll = "SellAll",
	ClaimDailyReward = "ClaimDailyReward",
	SelectGooSkin = "SelectGooSkin",

	-- client -> server (fire-and-forget actions; RemoteEvent)
	DamageBuilding = "DamageBuilding",
	ToggleShield = "ToggleShield",
	ResetStats = "ResetStats",
	RequestSpin = "RequestSpin",
	EquipSkin = "EquipSkin",
	DisableBuildViewNudge = "DisableBuildViewNudge",
	MarkIntroSeen = "MarkIntroSeen",
	UpdateSetting = "UpdateSetting",
	StoryAction = "StoryAction",

	-- debug / test harness only (server handler is gated to Studio or the place creator)
	DebugPlot = "DebugPlot",

	-- server -> client (results / pushes)
	ProductionEarnings = "ProductionEarnings",
	CookieIncrease = "CookieIncrease",
	GoldenCookieEarned = "GoldenCookieEarned",
	OfflineEarningsClaim = "OfflineEarningsClaim",
	SpinResult = "SpinResult",
	SkinInventoryChanged = "SkinInventoryChanged",
	GooSkinInventoryChanged = "GooSkinInventoryChanged",
	StoryStateChanged = "StoryStateChanged",
}
