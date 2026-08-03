-- Canonical declarative content for the complete opening tutorial arc.

local function localized(key, fallback)
	return { Key = key, Fallback = fallback }
end

local function phrase(key, fallback, variants)
	local result = { Default = localized(key, fallback) }
	if variants then
		result.Variants = {}
		for inputKind, text in pairs(variants) do
			result.Variants[inputKind] = localized(key .. "." .. inputKind, text)
		end
	end
	return result
end

local function copy(key, fallback, config)
	config = config or {}
	local result = phrase(key, fallback, config.Variants)
	result.Tokens = config.Tokens or {}
	if config.Phases then
		result.Phases = {}
		for phase, value in pairs(config.Phases) do
			result.Phases[phase] = phrase(key .. "." .. phase, value.Fallback, value.Variants)
		end
	end
	if config.Progress then
		result.Progress = {
			Kind = config.Progress.Kind or "CountUp",
			Template = localized(key .. ".Progress", config.Progress.Fallback or "({Current}/{Target})"),
			Phases = config.Progress.Phases,
		}
	end
	return result
end

local NAME_TOKEN = { Type = "UpgradeDisplayName", Source = "UpgradeId" }
local CURRENT_TOKEN = { Type = "Number", Source = "Current" }
local TARGET_TOKEN = { Type = "Number", Source = "Target" }

local tutorialPresentation = {
	StepCompletion = "TutorialStrikeThenReveal",
	QuestCompletion = "TutorialCompletion",
	Passive = "TrackedOnly",
}

local definitions = {
	{
		Id = "gooey_beginning",
		Version = 1,
		ArcId = "opening_tutorial",
		Order = 1,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = {},
		Title = localized("Quest.GooeyBeginning.Title", "A Gooey Beginning"),
		Help = { Enabled = true },
		Replay = {
			Enabled = true,
			Terminal = localized("Quest.GooeyBeginning.Replay.Terminal", "Chapter replay complete."),
			RewardLabel = localized("Quest.GooeyBeginning.Replay.RewardLabel", "Chapter Replay"),
			RewardValue = localized("Quest.GooeyBeginning.Replay.RewardValue", "No Reward"),
		},
		Presentation = tutorialPresentation,
		Steps = {
			{
				Id = "begin_rescue",
				Title = localized("Quest.GooeyBeginning.BeginRescue.Title", "Witness the Impact"),
				Objective = { Kind = "StoryTransition", Params = { Fact = "IntroCompleted" } },
				Copy = copy(
					"Quest.GooeyBeginning.BeginRescue.Objective",
					"Watch the Goo's meteor crash-land."
				),
				Presentation = { StepCompletion = "TutorialStrikeThenReveal" },
			},
			{
				Id = "unearth_cookie",
				Title = localized("Quest.GooeyBeginning.UnearthCookie.Title", "Free the Goo"),
				Objective = { Kind = "StoryTransition", Params = { Fact = "RubbleCleared" } },
				Copy = copy("Quest.GooeyBeginning.UnearthCookie.Objective", "Clear the meteor rubble."),
				LocalProgress = {
					Id = "rubble_cleared",
					Target = 5,
					CompletionPolicy = "TutorialStrikeThenReveal",
					Card = copy("Quest.GooeyBeginning.UnearthCookie.Card", "Clear the meteor rubble.", {
						Tokens = { Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
						Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})" },
					}),
					Prompt = copy("Quest.GooeyBeginning.UnearthCookie.Prompt", "Clear the rubble!", {
						Tokens = { Remaining = { Type = "Number", Source = "Remaining" } },
						Progress = { Kind = "CountDown", Fallback = "({Remaining} left)" },
					}),
				},
				Presentation = { StepCompletion = "TutorialImmediateReveal" },
			},
			{
				Id = "help_goo_recover",
				Title = localized("Quest.GooeyBeginning.HelpGooRecover.Title", "Help the Goo Recover"),
				Objective = { Kind = "ManualOwnerClickCount", Params = { Target = 5 } },
				Copy = copy("Quest.GooeyBeginning.HelpGooRecover.Objective", "Tap the cookie 5 times to heal Goob.", {
					Variants = {
						Keyboard = "Click the cookie 5 times to heal Goob.",
						Gamepad = "Select the cookie 5 times to heal Goob.",
					},
					Tokens = { Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})" },
				}),
				Presentation = {
					StepCompletion = "TutorialHealingThenReveal",
					Guide = {
						Kind = "Cookie",
						Style = "HighlightPointer",
						Frame = "CookieHighlight",
					},
				},
			},
			{
				Id = "unlock_mixer",
				Title = localized("Quest.GooeyBeginning.UnlockMixer.Title", "Unlock the Mixer"),
				Objective = { Kind = "StoryTransition", Params = { Fact = "LoreCompleted" } },
				Copy = copy("Quest.GooeyBeginning.UnlockMixer.Objective", "Finish talking with Goob."),
				Presentation = {
					StepCompletion = "TutorialMixerUnlockThenReveal",
					Guide = {
						Kind = "Dialogue",
						TargetId = "Continue",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
			{
				Id = "build_first_helper",
				Title = localized("Quest.GooeyBeginning.BuildFirstHelper.Title", "Build Your First Helper"),
				Objective = {
					Kind = "BuildingPlaced",
					Params = { UpgradeId = "Noob Clicker", ShowAffordability = true },
				},
				Copy = copy("Quest.GooeyBeginning.BuildFirstHelper.Objective", "Place a {Name} from the Mixer.", {
					Tokens = { Name = NAME_TOKEN, Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Phases = {
						Saving = { Fallback = "Save {Target} cookies for a {Name}." },
						Affordable = { Fallback = "Place a {Name} from the Mixer." },
						Satisfied = { Fallback = "Place a {Name} from the Mixer." },
					},
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})", Phases = { "Saving" } },
				}),
				Presentation = {
					StepCompletion = "TutorialImmediateReveal",
					Milestones = {
						{ Phase = "Affordable", Policy = "TutorialStrikeThenReveal" },
					},
					Guide = {
						Kind = "StoreRow",
						TargetId = "Noob Clicker",
						Surface = "Mixer",
						Category = "Building",
						PlacementControlId = "SlotRight",
						SavingTargetId = "Cookie",
						Style = "CatchPulse",
						Frame = "CatchPulse",
					},
				},
			},
		},
		Rewards = { { SlotId = "gooey_beginning_gems", Kind = "Gems", Params = { Amount = 15 } } },
	},
	{
		Id = "mixer_training",
		Version = 1,
		ArcId = "opening_tutorial",
		Order = 2,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "gooey_beginning" },
		Title = localized("Quest.MixerTraining.Title", "Mixer Training"),
		Help = { Enabled = true },
		Presentation = tutorialPresentation,
		Steps = {
			{
				Id = "see_the_numbers",
				Title = localized("Quest.MixerTraining.SeeNumbers.Title", "See the Numbers"),
				Objective = { Kind = "ClientUiObservation", Params = { Observation = "StatsEyeEnabled" } },
				Copy = copy("Quest.MixerTraining.SeeNumbers.Objective", "Turn on Building Stats in the Mixer."),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "UiControl",
						TargetId = "StatsEyeToggle",
						Surface = "Mixer",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
			{
				Id = "hire_another_noob",
				Title = localized("Quest.MixerTraining.HireAnotherNoob.Title", "Hire Another Noob"),
				Objective = { Kind = "BuildingCountAtLeast", Params = { UpgradeId = "Noob Clicker", Count = 2 } },
				Copy = copy("Quest.MixerTraining.HireAnotherNoob.Objective", "Buy a second {Name}.", {
					Tokens = { Name = NAME_TOKEN, Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})" },
				}),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "StoreRow",
						TargetId = "Noob Clicker",
						Surface = "Mixer",
						Category = "Building",
						PlacementControlId = "SlotRight",
						Style = "CatchPulse",
						Frame = "CatchPulse",
					},
				},
			},
			{
				Id = "look_from_above",
				Title = localized("Quest.MixerTraining.LookFromAbove.Title", "Look From Above"),
				Objective = { Kind = "ClientUiObservation", Params = { Observation = "BuildViewOpened" } },
				Copy = copy("Quest.MixerTraining.LookFromAbove.Objective", "Open Build View to see your plot from above.", {
					Variants = { Keyboard = "Open Build View (V) to see your plot from above." },
				}),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "UiControl",
						TargetId = "BuildView",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
			{
				Id = "undo_a_purchase",
				Title = localized("Quest.MixerTraining.UndoPurchase.Title", "Undo a Purchase"),
				Objective = { Kind = "BuildingSold", Params = { UpgradeId = "Any" } },
				Copy = copy(
					"Quest.MixerTraining.UndoPurchase.Objective",
					"Switch the Mixer to Sell, then sell one placed {Name}.",
					{ Tokens = { Name = { Type = "UpgradeDisplayName", Value = "Noob Clicker" } } }
				),
				Presentation = {
					StepCompletion = "TutorialImmediateReveal",
					CompletionAction = { Kind = "SetStoreMode", Params = { Mode = "Build" } },
					Guide = {
						Kind = "PlacedBuilding",
						UpgradeId = "Noob Clicker",
						Surface = "Mixer",
						ModeControlId = "SellButton",
						Style = "HighlightPointer",
						Frame = "WorldPointer",
					},
				},
			},
		},
		Rewards = { { SlotId = "mixer_training_gems", Kind = "Gems", Params = { Amount = 10 } } },
	},
	{
		Id = "first_automation",
		Version = 1,
		ArcId = "opening_tutorial",
		Order = 3,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "mixer_training" },
		Title = localized("Quest.FirstAutomation.Title", "First Automation"),
		Help = { Enabled = true },
		Presentation = tutorialPresentation,
		Steps = {
			{
				Id = "save_for_goo_clicker",
				Title = localized("Quest.FirstAutomation.SaveCookies.Title", "Save Your Cookies"),
				Objective = { Kind = "CookieBalanceAtLeast", Params = { UpgradeId = "Autoclicker" } },
				Copy = copy("Quest.FirstAutomation.SaveCookies.Objective", "Earn cookies to buy the {Name}.", {
					Tokens = { Name = NAME_TOKEN, Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})" },
				}),
				Presentation = { StepCompletion = "TutorialStrikeThenReveal" },
			},
			{
				Id = "buy_goo_clicker",
				Title = localized("Quest.FirstAutomation.BuyGooClicker.Title", "Hire the Goo Clicker"),
				Objective = { Kind = "UpgradePurchased", Params = { UpgradeId = "Autoclicker" } },
				Copy = copy("Quest.FirstAutomation.BuyGooClicker.Objective", "Buy the {Name} from the Upgrades tab.", {
					Tokens = { Name = NAME_TOKEN },
				}),
				Presentation = {
					StepCompletion = "TutorialImmediateReveal",
					Guide = {
						Kind = "StoreRow",
						TargetId = "Autoclicker",
						Surface = "Mixer",
						Category = "Upgrade",
						Style = "CatchPulse",
						Frame = "CatchPulse",
					},
				},
			},
		},
		Rewards = { { SlotId = "first_automation_gems", Kind = "Gems", Params = { Amount = 10 } } },
	},
	{
		Id = "understanding_upgrades",
		Version = 1,
		ArcId = "opening_tutorial",
		Order = 4,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "first_automation" },
		Title = localized("Quest.UnderstandingUpgrades.Title", "Understanding Upgrades"),
		Help = { Enabled = true },
		Presentation = tutorialPresentation,
		Steps = {
			{
				Id = "build_a_crew",
				Title = localized("Quest.UnderstandingUpgrades.BuildCrew.Title", "Build a Crew"),
				Objective = {
					Kind = "BuildingCountAtLeast",
					Params = {
						UpgradeId = "Noob Clicker",
						CountFromUpgradeId = "Noob Clicker Upgrades",
						ImpliedByUpgradeId = "Noob Clicker Upgrades",
					},
				},
				Copy = copy("Quest.UnderstandingUpgrades.BuildCrew.Objective", "Own {Target} {Name}s.", {
					Tokens = { Name = NAME_TOKEN, Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})" },
				}),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
				},
			},
			{
				Id = "follow_the_pulse",
				Title = localized("Quest.UnderstandingUpgrades.FollowPulse.Title", "Follow the Pulse"),
				Objective = {
					Kind = "ClientUiObservation",
					Params = {
						Observation = "UpgradeNudgeActivated",
						ImpliedByUpgradeId = "Noob Clicker Upgrades",
					},
				},
				Copy = copy("Quest.UnderstandingUpgrades.FollowPulse.Objective", "Tap the pulse on the {Name} card.", {
					Variants = {
						Keyboard = "Click the pulse on the {Name} card.",
						Gamepad = "Select the pulse on the {Name} card.",
					},
					Tokens = { Name = { Type = "UpgradeDisplayName", Value = "Noob Clicker" } },
				}),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "UiControl",
						TargetId = "UpgradeNudge",
						UpgradeId = "Noob Clicker",
						Surface = "Mixer",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
			{
				Id = "steady_hands",
				Title = localized("Quest.UnderstandingUpgrades.SteadyHands.Title", "Steady Hands"),
				Objective = { Kind = "UpgradePurchased", Params = { UpgradeId = "Noob Clicker Upgrades" } },
				Copy = copy("Quest.UnderstandingUpgrades.SteadyHands.Objective", "Buy {Name} to double your Noob Clickers.", {
					Tokens = { Name = NAME_TOKEN },
				}),
				Presentation = {
					StepCompletion = "TutorialImmediateReveal",
					Guide = {
						Kind = "StoreRow",
						TargetId = "Noob Clicker Upgrades",
						Surface = "Mixer",
						Category = "Upgrade",
						Style = "CatchPulse",
						Frame = "CatchPulse",
					},
				},
			},
		},
		Rewards = { { SlotId = "understanding_upgrades_gems", Kind = "Gems", Params = { Amount = 5 } } },
	},
	{
		Id = "powering_up",
		Version = 1,
		ArcId = "opening_tutorial",
		Order = 5,
		Lifecycle = { Kind = "OneTime" },
		RequiresDefinitionIds = { "understanding_upgrades" },
		Title = localized("Quest.PoweringUp.Title", "Powering Up"),
		Help = { Enabled = true },
		Presentation = tutorialPresentation,
		Steps = {
			{
				Id = "find_boost_shop",
				Title = localized("Quest.PoweringUp.FindShop.Title", "Find the Shop"),
				Objective = {
					Kind = "ClientUiObservation",
					Params = { Observation = "BoostShopApproached" },
				},
				Copy = copy(
					"Quest.PoweringUp.FindShop.Objective",
					"Visit the boost shop in the middle of the map."
				),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "OffscreenWorldTarget",
						TargetId = "SignAnchor",
						Style = "HighlightPointer",
						Frame = "WorldPointer",
					},
				},
			},
			{
				Id = "buy_boost_field",
				Title = localized("Quest.PoweringUp.BuyField.Title", "Spend Your Gems"),
				Objective = {
					Kind = "BoostPurchased",
					Params = { ItemIds = { "PowerField", "SpeedField" } },
				},
				Copy = copy("Quest.PoweringUp.BuyField.Objective", "Buy a Power Field or a Speed Field. ({Target} gems)", {
					Tokens = { Current = CURRENT_TOKEN, Target = TARGET_TOKEN },
					Phases = {
						Shortfall = { Fallback = "Earn {Target} gems to buy a boost field." },
						Affordable = { Fallback = "Buy a Power Field or a Speed Field. ({Target} gems)" },
						Satisfied = { Fallback = "Buy a Power Field or a Speed Field. ({Target} gems)" },
					},
					Progress = { Kind = "CountUp", Fallback = "({Current}/{Target})", Phases = { "Shortfall" } },
				}),
				Presentation = {
					StepCompletion = "TutorialStrikeThenReveal",
					Guide = {
						Kind = "UiControl",
						TargetId = "BoostPurchaseConfirm",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
			{
				Id = "drop_boost_field",
				Title = localized("Quest.PoweringUp.DropField.Title", "Drop the Field"),
				Objective = {
					Kind = "BoostFieldDropped",
					Params = { ItemIds = { "PowerField", "SpeedField" } },
				},
				Copy = copy("Quest.PoweringUp.DropField.Objective", "Drop your field over your buildings."),
				Presentation = {
					StepCompletion = "TutorialImmediateReveal",
					Guide = {
						Kind = "UiControl",
						TargetId = "BoostFieldCharge",
						Style = "Pointer",
						Frame = "Pointer",
					},
				},
			},
		},
		Rewards = {
			{
				SlotId = "opening_tutorial_capstone",
				Kind = "GooSkin",
				Params = {
					SkinId = "Goo::Meteor",
					DisplayName = "Meteor Goo",
					MysteryDisplayName = "Mystery Goo",
					Resolved = false,
				},
			},
		},
	},
}

return {
	ContentVersion = 3,
	Arcs = {
		{
			Id = "opening_tutorial",
			Order = 1,
			QuestIds = {
				"gooey_beginning",
				"mixer_training",
				"first_automation",
				"understanding_upgrades",
				"powering_up",
			},
			DisplayQuestCount = 5,
			Title = localized("Quest.OpeningTutorial.Title", "Getting Started"),
			Reward = { DefinitionId = "powering_up", SlotId = "opening_tutorial_capstone" },
		},
	},
	Definitions = definitions,
	RetiredRewardReceipts = {},
}
