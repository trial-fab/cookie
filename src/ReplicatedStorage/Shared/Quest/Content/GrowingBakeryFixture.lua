-- Non-shipping scaling fixture. It proves a second four-quest arc can be authored
-- entirely as content with existing kinds. Its product rewards remain unresolved,
-- so every Rewards array is deliberately empty and this module is not in Manifest.

local function localized(key, fallback)
	return { Key = key, Fallback = fallback }
end

local function copy(key, fallback, tokens, progress)
	local result = {
		Default = localized(key, fallback),
		Tokens = tokens or {},
	}
	if progress then
		result.Progress = {
			Kind = "CountUp",
			Template = localized(key .. ".Progress", "({Current}/{Target})"),
		}
	end
	return result
end

local CURRENT = { Type = "Number", Source = "Current" }
local TARGET = { Type = "Number", Source = "Target" }
local NAME = { Type = "UpgradeDisplayName", Source = "UpgradeId" }
local presentation = {
	StepCompletion = "StandardConcise",
	QuestCompletion = "StandardCompletion",
	Passive = "PassiveToast",
}

local definitions = {
	{
		Id = "bakery_second_helper",
		Version = 1,
		ArcId = "growing_bakery",
		Order = 1,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = {},
		Title = localized("Quest.GrowingBakery.SecondHelper.Title", "A Second Kind of Helper"),
		Presentation = presentation,
		Steps = {
			{
				Id = "own_first_granny",
				Title = localized("Quest.GrowingBakery.SecondHelper.Step.Title", "Meet Another Helper"),
				Objective = { Kind = "BuildingCountAtLeast", Params = { UpgradeId = "Granny", Count = 1 } },
				Copy = copy("Quest.GrowingBakery.SecondHelper.Step", "Buy a {Name}.", {
					Name = NAME,
					Current = CURRENT,
					Target = TARGET,
				}, true),
				Presentation = { StepCompletion = "StandardConcise" },
			},
		},
		Rewards = {},
	},
	{
		Id = "bakery_sleeping_cookies",
		Version = 1,
		ArcId = "growing_bakery",
		Order = 2,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "bakery_second_helper" },
		Title = localized("Quest.GrowingBakery.Sleeping.Title", "Cookies While You Sleep"),
		Presentation = presentation,
		Steps = {
			{
				Id = "bank_return_cookies",
				Title = localized("Quest.GrowingBakery.Sleeping.Step.Title", "Keep the Bakery Growing"),
				Objective = { Kind = "CookieBalanceAtLeast", Params = { Amount = 500 } },
				Copy = copy("Quest.GrowingBakery.Sleeping.Step", "Reach {Target} cookies.", {
					Current = CURRENT,
					Target = TARGET,
				}, true),
				Presentation = { StepCompletion = "StandardConcise" },
			},
		},
		Rewards = {},
	},
	{
		Id = "bakery_golden_opportunity",
		Version = 1,
		ArcId = "growing_bakery",
		Order = 3,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "bakery_sleeping_cookies" },
		Title = localized("Quest.GrowingBakery.Golden.Title", "Golden Opportunity"),
		Presentation = presentation,
		Steps = {
			{
				Id = "build_golden_bankroll",
				Title = localized("Quest.GrowingBakery.Golden.Step.Title", "Build a Bankroll"),
				Objective = { Kind = "CookieBalanceAtLeast", Params = { Amount = 1000 } },
				Copy = copy("Quest.GrowingBakery.Golden.Step", "Reach {Target} cookies.", {
					Current = CURRENT,
					Target = TARGET,
				}, true),
				Presentation = { StepCompletion = "StandardConcise" },
			},
		},
		Rewards = {},
	},
	{
		Id = "bakery_room_to_grow",
		Version = 1,
		ArcId = "growing_bakery",
		Order = 4,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "bakery_golden_opportunity" },
		Title = localized("Quest.GrowingBakery.Room.Title", "Room to Grow"),
		Presentation = presentation,
		Steps = {
			{
				Id = "own_first_factory",
				Title = localized("Quest.GrowingBakery.Room.Step.Title", "Grow the Bakery"),
				Objective = {
					Kind = "BuildingCountAtLeast",
					Params = { UpgradeId = "Cookie Factory", Count = 1 },
				},
				Copy = copy("Quest.GrowingBakery.Room.Step", "Buy a {Name}.", {
					Name = NAME,
					Current = CURRENT,
					Target = TARGET,
				}, true),
				Presentation = { StepCompletion = "StandardConcise" },
			},
		},
		Rewards = {},
	},
}

return {
	Shipping = false,
	Manifest = {
		ContentVersion = 1,
		Arcs = {
			{
				Id = "growing_bakery",
				Order = 1,
				QuestIds = {
					"bakery_second_helper",
					"bakery_sleeping_cookies",
					"bakery_golden_opportunity",
					"bakery_room_to_grow",
				},
				DisplayQuestCount = 4,
				Title = localized("Quest.GrowingBakery.Title", "Growing the Bakery"),
			},
		},
		Definitions = definitions,
		RetiredRewardReceipts = {},
	},
}
