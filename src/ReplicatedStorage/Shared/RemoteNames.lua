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
	PurchaseBoostItem = "PurchaseBoostItem",
	ActivateHubCore = "ActivateHubCore",
	DropBoostField = "DropBoostField",
	SelectGooSkin = "SelectGooSkin",
	SelectTitle = "SelectTitle",
	GetGlobalLeaderboards = "GetGlobalLeaderboards",
	DevTuningApply = "DevTuningApply",

	-- client -> server (fire-and-forget actions; RemoteEvent)
	DamageBuilding = "DamageBuilding",
	ToggleShield = "ToggleShield",
	RequestSpin = "RequestSpin",
	EquipSkin = "EquipSkin",
	DisableBuildViewNudge = "DisableBuildViewNudge",
	MarkIntroSeen = "MarkIntroSeen",
	UpdateSetting = "UpdateSetting",
	StoryAction = "StoryAction",
	PlacementControlUsed = "PlacementControlUsed",
	QuestReadyV2 = "QuestReadyV2",
	QuestObservationV2 = "QuestObservationV2",
	QuestPreferenceV2 = "QuestPreferenceV2",
	QuestSelectV2 = "QuestSelectV2",

	-- debug / test harness only (server handler is gated to Studio or the place creator)
	DebugPlot = "DebugPlot",
	DebugOnboardingReset = "DebugOnboardingReset",

	-- server -> client (results / pushes)
	ProductionEarnings = "ProductionEarnings",
	CookieIncrease = "CookieIncrease",
	GoldenCookieEarned = "GoldenCookieEarned",
	GemEarned = "GemEarned",
	OfflineEarningsClaim = "OfflineEarningsClaim",
	SpinResult = "SpinResult",
	SkinInventoryChanged = "SkinInventoryChanged",
	GooSkinInventoryChanged = "GooSkinInventoryChanged",
	StoryStateChanged = "StoryStateChanged",
	QuestEnvelopeV2 = "QuestEnvelopeV2",
	OrbLayerPreviewChanged = "OrbLayerPreviewChanged",
}
