-- Economy values are governed by docs/economy-rebalance-spec.md (v3).
-- Producers: §3 ladder. Clicking Power: §4b. Gear: §5. Building upgrades: §4a.
-- Re-run tools/economy_sim.py after any value change here.
local UpgradeConfig = {
	Cookie = {
		DisplayName = "Cookie",
		Description = "FOOD. THE SECRET OF LIFE. THE ANSWER TO EVERYTHING IN THE UNIVERSE. YES11! Has 2 bites.",
		InitialCount = 0,
		BaseCost = 1,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Cookie",
		StoreVisible = false,
		MaxCount = 1,
	},

	-- §4b: each purchase doubles total cookies per click (1 -> 2 -> 4 -> 8 ...).
	-- Cost ladder 500, 5k, 50k, 500k ... via BaseCost 500 x CostMultiplier 10 ^ count.
	["Clicking Power"] = {
		DisplayName = "Clicking Power",
		Description = "Doubles your cookies per click.",
		IconFill = "rbxassetid://84671355431653",
		IconOutline = "rbxassetid://125420180944081",
		InitialCount = 0,
		BaseCost = 500,
		CostMultiplier = 10,
		TemplateKind = "Stat",
		TemplateName = "Clicking Power",
		ClickPowerMultiplier = 2,
		Effects = { ClickPowerMultiplier = 2 },
	},

	["CPG - Cookie Powered Grenade"] = {
		DisplayName = "Cookie Powered Grenade",
		Description = "Launch cookie powered grenades at others.",
		InitialCount = 0,
		BaseCost = 2000000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "CPG - Cookie Powered Grenade",
		StoreVisible = false,
		MaxCount = 1,
	},

	["Gravity Coil"] = {
		DisplayName = "Gravity Coil",
		Description = "Fly through the air, over your enemies defenses.",
		InitialCount = 0,
		BaseCost = 250000000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Gravity Coil",
		StoreVisible = false,
		MaxCount = 1,
	},

	["Speed Coil"] = {
		DisplayName = "Speed Coil",
		Description = "Move faster than something close to light.",
		InitialCount = 0,
		BaseCost = 5000000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Speed Coil",
		StoreVisible = false,
		MaxCount = 1,
	},

	["Health + 2"] = {
		DisplayName = "Health + 2",
		Description = "Increases your max health by 2.",
		InitialCount = 0,
		BaseCost = 5000,
		CostMultiplier = 1.15,
		TemplateKind = "Stat",
		TemplateName = "Health + 2",
		Effects = { MaxHealthBonus = 2 },
	},

	["Hot Potato"] = {
		DisplayName = "Hot Potato",
		Description = "An explosive gear for fighting other players.",
		InitialCount = 0,
		BaseCost = 50,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Hot Potato",
		StoreVisible = false,
		MaxCount = 1,
	},

	Taco = {
		DisplayName = "Taco",
		Description = "A tasty treat that restores health.",
		InitialCount = 0,
		BaseCost = 300000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Taco",
		StoreVisible = false,
		MaxCount = 1,
	},

	["High Tech Pick Axe"] = {
		DisplayName = "High Tech Pick Axe",
		Description = "Destroy buildings and walls faster with this high tech pick axe.",
		InitialCount = 0,
		BaseCost = 250000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "High Tech Pick Axe",
		StoreVisible = false,
		MaxCount = 1,
	},

	["Green Katana"] = {
		DisplayName = "Green Katana",
		Description = "A stylish higher-damage sword.",
		InitialCount = 0,
		BaseCost = 10000,
		CostMultiplier = 1,
		TemplateKind = "Gear",
		TemplateName = "Green Katana",
		StoreVisible = false,
		MaxCount = 1,
	},

	-- §3 producer ladder: CostMultiplier 1.15, UpdateTime 10, CookiesGained = CpS x 10.
	["Noob Clicker"] = {
		DisplayName = "Noob Clicker",
		Description = "This noob will cook cookies for you.",
		InitialCount = 0,
		BaseCost = 15,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Noob Clicker",
		CookiesGained = 1,
		UpdateTime = 10,
		MaxIntegrity = 300,
	},

	Granny = {
		DisplayName = "Granny",
		Description = "Granny makes cookies over time.",
		InitialCount = 0,
		BaseCost = 100,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Granny",
		CookiesGained = 10,
		UpdateTime = 10,
		MaxIntegrity = 500,
	},

	Farm = {
		DisplayName = "Farm",
		Description = "Farms cookies over time.",
		InitialCount = 0,
		BaseCost = 800,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Farm",
		CookiesGained = 80,
		UpdateTime = 10,
		MaxIntegrity = 800,
	},

	["Cookie Mine"] = {
		DisplayName = "Cookie Mine",
		Description = "Mines cookies from deep underground.",
		InitialCount = 0,
		BaseCost = 9000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Cookie Mine",
		CookiesGained = 470,
		UpdateTime = 10,
		MaxIntegrity = 1500,
	},

	["Cookie Factory"] = {
		DisplayName = "Cookie Factory",
		Description = "Factories produce more cookies over time.",
		InitialCount = 0,
		BaseCost = 95000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Cookie Factory",
		CookiesGained = 2600,
		UpdateTime = 10,
		MaxIntegrity = 2500,
	},

	["Cookie Bank"] = {
		DisplayName = "Cookie Bank",
		Description = "Stores cookies and makes cookie investments.",
		InitialCount = 0,
		BaseCost = 1400000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Cookie Bank",
		CookiesGained = 14000,
		UpdateTime = 10,
		MaxIntegrity = 4000,
	},

	["Cookie Distributer"] = {
		DisplayName = "Cookie Distributer",
		Description = "Ships cookies around the world.",
		InitialCount = 0,
		BaseCost = 20000000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Cookie Distributer",
		CookiesGained = 90000,
		UpdateTime = 10,
		MaxIntegrity = 6000,
	},

	["Research Facility"] = {
		DisplayName = "Research Facility",
		Description = "Research cookie cloning and creation.",
		InitialCount = 0,
		BaseCost = 330000000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Research Facility",
		CookiesGained = 700000,
		UpdateTime = 10,
		MaxIntegrity = 9000,
	},

	-- Portal is the dimension door (roadmap Phase 5/6): 2x2 footprint, and its
	-- purchase is gated behind owning >= 1 Research Facility.
	Portal = {
		DisplayName = "Portal",
		Description = "Transports cookies from unknown regions of space.",
		InitialCount = 0,
		BaseCost = 5100000000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Portal",
		CookiesGained = 4500000,
		UpdateTime = 10,
		MaxIntegrity = 13000,
		FootprintCells = { 2, 2 },
		UnlockRequirement = { Building = "Research Facility", Count = 1 },
	},

	["Time Machine"] = {
		DisplayName = "Time Machine",
		Description = "Brings cookies from the past.",
		InitialCount = 0,
		BaseCost = 75000000000,
		CostMultiplier = 1.15,
		TemplateKind = "Building",
		TemplateName = "Time Machine",
		CookiesGained = 30000000,
		UpdateTime = 10,
		MaxIntegrity = 20000,
	},

	-- Defense buildings keep their upkeep model (negative CookiesGained).
	-- Out of scope for the economy rebalance; rebalance in a later PvP pass.
	["Cookie Wall"] = {
		DisplayName = "Cookie Wall",
		Description = "A defensive wall.",
		InitialCount = 0,
		BaseCost = 100,
		TemplateKind = "Building",
		TemplateName = "Cookie Wall",
		CookiesGained = -25,
		UpdateTime = 30,
		MaxIntegrity = 2000,
	},

	["Cookie Incinerator"] = {
		DisplayName = "Cookie Incinerator",
		Description = "Defensive structure that costs cookies over time.",
		InitialCount = 0,
		BaseCost = 3500,
		TemplateKind = "Building",
		TemplateName = "Cookie Incinerator",
		CookiesGained = -5,
		UpdateTime = 30,
		MaxIntegrity = 2000,
		TouchDamage = true,
		TouchDamagePerSecond = 10,
		TouchDamageInterval = 1,
	},

	["Spiked Wall"] = {
		DisplayName = "Spiked Wall",
		Description = "A defensive wall with spikes.",
		InitialCount = 0,
		BaseCost = 30000,
		TemplateKind = "Building",
		TemplateName = "Spiked Wall",
		CookiesGained = -50,
		UpdateTime = 30,
		MaxIntegrity = 7500,
		TouchDamage = true,
		TouchDamagePerSecond = 25,
		TouchDamageInterval = 1,
		TouchDamagePartName = "Spike Mesh",
	},

	["Cookie Trap"] = {
		DisplayName = "Cookie Trap",
		Description = "Explodes enemies who come near your cookies.",
		InitialCount = 0,
		BaseCost = 7000,
		TemplateKind = "Building",
		TemplateName = "Cookie Trap",
		CookiesGained = -5,
		UpdateTime = 30,
		MaxIntegrity = 1000,
	},

	["Reinforced Deadly Wall"] = {
		DisplayName = "Reinforced Deadly Wall",
		Description = "A deadly reinforced defensive wall.",
		InitialCount = 0,
		BaseCost = 50500,
		TemplateKind = "Building",
		TemplateName = "Reinforced Deadly Wall",
		CookiesGained = -50,
		UpdateTime = 30,
		MaxIntegrity = 10000,
		TouchDamage = true,
		TouchDamagePerSecond = 40,
		TouchDamageInterval = 1,
	},

	["Cookie Stairs"] = {
		DisplayName = "Cookie Stairs",
		Description = "Allows access to the top of your walls.",
		InitialCount = 0,
		BaseCost = 200,
		TemplateKind = "Building",
		TemplateName = "Cookie Stairs",
		CookiesGained = -25,
		UpdateTime = 30,
		MaxIntegrity = 2000,
	},

	-- §4a building upgrades: ONE leveled entry per producer, levels up in place
	-- (playtest 2026-06-11: separate per-level entries bloated the store).
	-- currentCount = levels owned; GetCost reads Levels[currentCount + 1].
	-- L1 unlocks at 10 owned (cost base x 25); L2 at 25 owned (cost base x 250).
	-- Lifetime cap x4 per building. TargetBuilding must match the producer's config key.
	["Noob Clicker Upgrades"] = {
		DisplayName = "Steady Hands",
		Description = "Doubles Noob Clicker output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Noob Clicker",
		Levels = {
			{ Cost = 375, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 3750, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Granny Upgrades"] = {
		DisplayName = "Granny's Secret Recipe",
		Description = "Doubles Granny output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Granny",
		Levels = {
			{ Cost = 2500, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 25000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Farm Upgrades"] = {
		DisplayName = "Fertile Soil",
		Description = "Doubles Farm output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Farm",
		Levels = {
			{ Cost = 20000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 200000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Cookie Mine Upgrades"] = {
		DisplayName = "Diamond Pickaxes",
		Description = "Doubles Cookie Mine output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Cookie Mine",
		Levels = {
			{ Cost = 225000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 2250000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Cookie Factory Upgrades"] = {
		DisplayName = "Assembly Line",
		Description = "Doubles Cookie Factory output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Cookie Factory",
		Levels = {
			{ Cost = 2375000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 23750000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Cookie Bank Upgrades"] = {
		DisplayName = "Compound Interest",
		Description = "Doubles Cookie Bank output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Cookie Bank",
		Levels = {
			{ Cost = 35000000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 350000000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Cookie Distributer Upgrades"] = {
		DisplayName = "Express Shipping",
		Description = "Doubles Cookie Distributer output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Cookie Distributer",
		Levels = {
			{ Cost = 500000000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 5000000000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Research Facility Upgrades"] = {
		DisplayName = "Peer Review",
		Description = "Doubles Research Facility output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Research Facility",
		Levels = {
			{ Cost = 8250000000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 82500000000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Portal Upgrades"] = {
		DisplayName = "Stabilized Rifts",
		Description = "Doubles Portal output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Portal",
		Levels = {
			{ Cost = 127500000000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 1275000000000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	["Time Machine Upgrades"] = {
		DisplayName = "Temporal Tuning",
		Description = "Doubles Time Machine output per level.",
		InitialCount = 0,
		TemplateKind = "BuildingUpgrade",
		TargetBuilding = "Time Machine",
		Levels = {
			{ Cost = 1875000000000, OutputMultiplier = 2, UnlockCount = 10 },
			{ Cost = 18750000000000, OutputMultiplier = 2, UnlockCount = 25 },
		},
	},

	-- §4c utility/QoL upgrades: pure sinks, no CpS inflation. Effects are
	-- declared here and walked by UpgradeService.ApplyUpgrade's effect-handler
	-- table; entitlement-style effects are queried from upgrade counts by
	-- their future runtime services rather than mutating client state now.
	["Multi-Place"] = {
		DisplayName = "Multi-Place",
		Description = "Place multiple buildings without reopening the store.",
		IconFill = "rbxassetid://110048456377257",
		IconOutline = "rbxassetid://99460809814929",
		IconTint = false,
		ActiveIcon = "rbxassetid://105869790587533",
		InactiveIcon = "rbxassetid://117985787938297",
		StateIconColor = Color3.fromRGB(0, 0, 0),
		StateIconName = "IconState",
		CreateStateIcon = true,
		InitialCount = 0,
		BaseCost = 50000,
		CostMultiplier = 1,
		TemplateKind = "Stat",
		TemplateName = "Multi-Place",
		MaxCount = 1,
		Effects = { UnlocksMultiPlace = 1 },
	},

	-- §4c IDLE ROUTE: two INDEPENDENT autoclick lines (not synced to manual click
	-- power). autoclickCps = AutoclickPayout (this line, cookies per auto-click) ×
	-- autoclick speed (clicks/s, the "Autoclick Speed" line below, base 2/s) ×
	-- world-event multiplier. Autoclicks never roll golden-cookie drops (§6) and
	-- are NOT counted by OfflineEarningsService (in-session/idle engine only).
	--
	-- Power line: cheap session-1 entry (L1 = 550), then cost ×10 / output ×5 per
	-- level so cost-per-CpS grows ×2 — autoclick is the early/early-mid hook +
	-- supplement and DELIBERATELY tapers late (buildings are the real idle engine;
	-- spec §2). Validated supplement: peaks ~7% of building CpS, never dominates.
	-- EffectText shows CpS at base speed (2/s); it rises further with speed levels.
	-- Numbers governed by tools/economy_sim.py — re-run after any change.
	Autoclicker = {
		DisplayName = "Autoclick Power",
		Description = "An auto-clicker taps your cookie for you. Each level raises cookies per auto-click. Buy Autoclick Speed to tap faster.",
		IconFill = "rbxassetid://84671355431653",
		IconOutline = "rbxassetid://125420180944081",
		IconDetail = "rbxassetid://119532598792293",
		IconDetailLayerOrder = "Under",
		InitialCount = 0,
		BaseCost = 550,
		TemplateKind = "Stat",
		TemplateName = "Autoclicker",
		Sellable = false,
		Levels = {
			{ Cost = 550,        AutoclickPayout = 1,    EffectText = "2 cookies/s" },
			{ Cost = 5000,       AutoclickPayout = 5,    EffectText = "10 cookies/s" },
			{ Cost = 50000,      AutoclickPayout = 25,   EffectText = "50 cookies/s" },
			{ Cost = 500000,     AutoclickPayout = 125,  EffectText = "250 cookies/s" },
			{ Cost = 5000000,    AutoclickPayout = 625,  EffectText = "1.25K cookies/s" },
			{ Cost = 50000000,   AutoclickPayout = 3125, EffectText = "6.25K cookies/s" },
		},
	},

	-- §4c Autoclick Speed: the short, bounded "feel" line — auto-clicks per second.
	-- Base speed (level 0, owned implicitly with any Autoclick Power) = 2/s. Capped
	-- at 5/s (×2.5) so power × speed can't run away. Drives autoclick income AND the
	-- orbiting-mice visual cadence (AutoclickVisualController). Read by AutoclickService.
	["Autoclick Speed"] = {
		DisplayName = "Autoclick Speed",
		Description = "Your auto-clicker taps faster, multiplying all autoclick income.",
		IconFill = "rbxassetid://84671355431653",
		IconOutline = "rbxassetid://125420180944081",
		IconDetail = "rbxassetid://110236744350984",
		IconDetailLayerOrder = "Under",
		InitialCount = 0,
		BaseCost = 25000,
		TemplateKind = "Stat",
		TemplateName = "Autoclick Speed",
		Sellable = false,
		Levels = {
			{ Cost = 25000,    AutoclickSpeed = 3, EffectText = "3 clicks/s" },
			{ Cost = 1000000,  AutoclickSpeed = 4, EffectText = "4 clicks/s" },
			{ Cost = 50000000, AutoclickSpeed = 5, EffectText = "5 clicks/s" },
		},
	},

	["Offline Earnings"] = {
		DisplayName = "Offline Earnings",
		Description = "Raises your offline earnings cap.",
		InitialCount = 0,
		BaseCost = 10000000,
		CostMultiplier = 1,
		TemplateKind = "Stat",
		TemplateName = "Offline Earnings",
		Sellable = false,
		Levels = {
			{ Cost = 10000000, Effects = { OfflineCapHours = 4 }, EffectText = "+4h cap" },
			{ Cost = 1000000000, Effects = { OfflineCapHours = 12 }, EffectText = "+12h cap" },
		},
	},

	["Base Expansion"] = {
		DisplayName = "Base Expansion",
		Description = "Pushes your plot's frontier outward, adding build space.",
		InitialCount = 0,
		BaseCost = 50000,
		CostMultiplier = 1,
		TemplateKind = "Stat",
		TemplateName = "Base Expansion",
		Sellable = false,
		-- Plot starts 22 wide x 6 deep; each level adds 4 cells of DEPTH (grows outward).
		-- Depth stays even (see PLOT_*_CELLS in UpgradeService). Costs are PLACEHOLDERS pending
		-- balance now that expansion is the core early build-space loop.
		Levels = {
			{ Cost = 50000,        Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x10" },
			{ Cost = 400000,       Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x14" },
			{ Cost = 3000000,      Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x18" },
			{ Cost = 25000000,     Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x22" },
			{ Cost = 200000000,    Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x26" },
			{ Cost = 1600000000,   Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x30" },
			{ Cost = 13000000000,  Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x34" },
			{ Cost = 100000000000, Effects = { GridExpansion = 4 }, EffectText = "Depth -> 22x38" },
		},
	},
}

return UpgradeConfig
