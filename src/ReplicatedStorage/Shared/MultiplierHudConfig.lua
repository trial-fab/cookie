-- Persistent values and authored-instance names for the multiplier status HUD.
return {
	RootName = "MultiplierStatusHud",
	SlotsName = "SourceSlots",
	SlotPrefix = "SourceSlot",
	MaxSlots = 16,
	SlotsPerRow = 8,
	InfinityText = "∞",
	WorldEventFolderName = "WorldEventMultipliers",
	ServerBoostEndsAtAttribute = "ServerBoostEndsAt",
	PlaceholderIcon = "rbxassetid://82392603595263",
	Icons = {
		Goo = {
			Image = "rbxassetid://82392603595263",
		},
		UpgradeX2 = {
			Image = "rbxassetid://118270371326156",
			Color = Color3.fromRGB(255, 255, 255),
		},
		UpgradeX4 = {
			Image = "rbxassetid://85613781027114",
			Color = Color3.fromRGB(255, 255, 255),
		},
		Floor1 = {
			Image = "rbxassetid://71498286432491",
		},
		Floor2 = {
			Image = "rbxassetid://89263789822119",
		},
		Floor3 = {
			Image = "rbxassetid://113816677150656",
		},
		-- The same clover already authored on BottomRightHud.FriendBoost, so the two readouts of
		-- one bonus stay recognizably the same thing.
		FriendBoost = {
			Image = "rbxassetid://134627555829309",
			Color = Color3.fromRGB(120, 230, 110),
		},
		PowerField = {
			Image = "rbxassetid://95966796252712",
		},
		SpeedField = {
			Image = "rbxassetid://93969396085546",
			Color = Color3.fromRGB(255, 225, 65),
		},
		ServerBoost = {
			Image = "rbxassetid://114718052798079",
		},
		Event = {
			Image = "rbxassetid://114718052798079",
		},
	},
	LeftOffset = 16,
	-- BottomRightHud's authored desktop stack leaves the XP bar 8px above its bottom edge.
	DesktopXpBarBottomOffset = 8,
	BottomOffset = 24,
	SlotGap = 12,
	TooltipOffsetX = 0,
	TooltipOffsetY = 0,
	DesktopScale = 1,
	CompactScale = 0.85,
	InfinityTextSize = 20,
	CountdownTextSize = 14,
	CountdownRefreshSeconds = 0.25,
	WarningThresholdSeconds = 30,
	NormalTextColor = Color3.fromRGB(255, 255, 255),
	WarningTextColor = Color3.fromRGB(255, 210, 70),
	ActivationStartScale = 0.78,
	ActivationPopScale = 1.16,
	ActivationPopSeconds = 0.12,
	ActivationSettleSeconds = 0.14,
	RemovalScale = 1,
	RemovalSeconds = 0.16,
	WarningPulseScale = 1.08,
	WarningPulseSeconds = 0.55,
}
