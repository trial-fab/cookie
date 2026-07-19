-- Persistent defaults and authored-instance names for the multiplier status HUD.
-- Visual/timing values remain live through the MultiplierHud DevTuning registry until baked.
return {
	RootName = "MultiplierStatusHud",
	SlotsName = "SourceSlots",
	SlotPrefix = "SourceSlot",
	MaxSlots = 8,
	InfinityText = "∞",
	WorldEventFolderName = "WorldEventMultipliers",
	ServerBoostEndsAtAttribute = "ServerBoostEndsAt",
	LeftOffset = 16,
	BottomOffset = 24,
	SlotGap = 8,
	DesktopScale = 1,
	CompactScale = 0.85,
	InfinityTextSize = 18,
	CountdownTextSize = 14,
	CountdownRefreshSeconds = 0.25,
	WarningThresholdSeconds = 30,
	NormalTextColor = Color3.fromRGB(255, 255, 255),
	WarningTextColor = Color3.fromRGB(255, 210, 70),
}
