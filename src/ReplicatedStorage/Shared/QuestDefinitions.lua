-- Canonical definitions for the staged tutorial-quest rollout.
-- Content spec: docs/quest-getting-started-arc.md. DisplayQuestCount keeps the approved
-- five-quest arc presentation while later quests are still being built, so the arc header
-- reads x/5 without exposing or inventing quests that do not exist yet.
--
-- Steps declare WHAT proves them (ObjectiveKind + ObjectiveTarget) and QuestService owns
-- one resolver per kind. Static copy lives here; only steps that need a live number carry
-- a DynamicCopy id. Sub-progress "(x/y)" is appended generically from the resolved
-- current/target, so no step string hardcodes a count.
--
-- Copy never hardcodes an upgrade's name either: "{Name}" resolves at runtime against
-- UpgradeConfig.DisplayName for the step's upgrade (ObjectiveTarget, its UpgradeId field,
-- or an explicit CopyUpgradeId). Renaming a building or upgrade moves its quest copy with
-- it -- which is exactly what the Auto-Clicker -> Goo Clicker rename needed.

local QuestDefinitions = {}

QuestDefinitions.SchemaVersion = 3

QuestDefinitions.ObjectiveKinds = table.freeze({
	StoryTransition = true,
	ManualOwnerClickCount = true,
	BuildingPlaced = true,
	BuildingCountAtLeast = true,
	BuildingSold = true,
	CookieBalanceAtLeast = true,
	UpgradePurchased = true,
	ClientUiObservation = true,
})

-- The closed allowlist of UI-only facts the client may report. None of these authorize
-- anything economic; the worst a forged one achieves is skipping a tutorial step the
-- player could have completed in two seconds. Anything with a canonical server trace
-- must use that trace instead of appearing here.
QuestDefinitions.Observations = table.freeze({
	StatsEyeEnabled = true,
	BuildViewOpened = true,
})

QuestDefinitions.Arcs = table.freeze({
	opening_tutorial = table.freeze({
		Id = "opening_tutorial",
		Order = 1,
		Title = "Getting Started",
		UnlockCondition = table.freeze({ Kind = "Always" }),
		QuestIds = table.freeze({ "gooey_beginning", "mixer_training", "first_automation" }),
		DisplayQuestCount = 5,
		CapstoneReward = table.freeze({
			ReceiptId = "opening_tutorial_capstone",
			-- Chosen 2026-07-26: Meteor Goo, 1.05x, non-rollable. Resolved flips to true
			-- when the art lands, which is what retires the locked-silhouette header.
			DisplayName = "Mystery Goo",
			Resolved = false,
		}),
	}),
})

QuestDefinitions.Quests = table.freeze({
	gooey_beginning = table.freeze({
		Id = "gooey_beginning",
		ArcId = "opening_tutorial",
		Order = 1,
		Title = "A Gooey Beginning",
		RequiresQuestIds = table.freeze({}),
		Reward = table.freeze({
			Kind = "Gems",
			Amount = 15,
			ReceiptId = "quest_reward_gooey_beginning_v1",
		}),
		Steps = table.freeze({
			table.freeze({
				Id = "begin_rescue",
				Title = "Witness the Impact",
				CompactObjective = "Watch the cookie meteor crash-land.",
				ObjectiveKind = "StoryTransition",
				ObjectiveTarget = "IntroCompleted",
				GuideCapability = false,
			}),
			table.freeze({
				Id = "unearth_cookie",
				Title = "Free the Goo",
				-- The one authored wording for this step. The client appends "(x/5)" as the
				-- player clears it; it must never carry a second sentence of its own.
				CompactObjective = "Clear the meteor rubble.",
				ObjectiveKind = "StoryTransition",
				ObjectiveTarget = "Healing",
				GuideCapability = false,
			}),
			table.freeze({
				Id = "help_goo_recover",
				Title = "Help the Goo Recover",
				CompactObjective = "Click the cookie 5 times to heal the goo.",
				ObjectiveKind = "ManualOwnerClickCount",
				ObjectiveTarget = 5,
				GuideCapability = true,
			}),
			table.freeze({
				Id = "unlock_mixer",
				Title = "Unlock the Mixer",
				CompactObjective = "Finish talking with Goob.",
				ObjectiveKind = "StoryTransition",
				ObjectiveTarget = "BuildTask",
				GuideCapability = true,
			}),
			table.freeze({
				Id = "build_first_helper",
				Title = "Build Your First Helper",
				CompactObjective = "Buy and place a Noob Clicker from the Mixer.",
				ObjectiveKind = "BuildingPlaced",
				ObjectiveTarget = "Noob Clicker",
				-- Reads the live configured price; never restates it here.
				DynamicCopy = "FirstHelperAffordability",
				GuideCapability = true,
			}),
		}),
	}),

	mixer_training = table.freeze({
		Id = "mixer_training",
		ArcId = "opening_tutorial",
		Order = 2,
		Title = "Mixer Training",
		RequiresQuestIds = table.freeze({ "gooey_beginning" }),
		Reward = table.freeze({
			Kind = "Gems",
			Amount = 10,
			ReceiptId = "quest_reward_mixer_training_v1",
		}),
		Steps = table.freeze({
			table.freeze({
				Id = "see_the_numbers",
				Title = "See the Numbers",
				CompactObjective = "Turn on Building Stats in the Mixer.",
				ObjectiveKind = "ClientUiObservation",
				ObjectiveTarget = "StatsEyeEnabled",
				GuideCapability = true,
			}),
			table.freeze({
				Id = "hire_another_noob",
				Title = "Hire Another Noob",
				CompactObjective = "Buy a second {Name}.",
				ObjectiveKind = "BuildingCountAtLeast",
				ObjectiveTarget = table.freeze({ UpgradeId = "Noob Clicker", Count = 2 }),
				GuideCapability = true,
			}),
			table.freeze({
				Id = "look_from_above",
				Title = "Look From Above",
				CompactObjective = "Open Build View to see your plot from above.",
				-- V is already surfaced to keyboard users through the cursor tooltip, so it
				-- is the one keybind the arc names. Touch and gamepad get the plain line.
				CompactObjectiveKeyboard = "Open Build View (V) to see your plot from above.",
				ObjectiveKind = "ClientUiObservation",
				ObjectiveTarget = "BuildViewOpened",
				GuideCapability = true,
			}),
			table.freeze({
				Id = "undo_a_purchase",
				Title = "Undo a Purchase",
				-- "Placed" is load-bearing: the store card sells ALL of a building through
				-- SellAll, only the world object sells one.
				CompactObjective = "Switch the Mixer to Sell, then sell one placed {Name}.",
				ObjectiveKind = "BuildingSold",
				ObjectiveTarget = "Any",
				CopyUpgradeId = "Noob Clicker",
				GuideCapability = true,
			}),
		}),
	}),

	-- Two steps, not three. The specced third step ("let the Goo Clicker earn its first
	-- cookies") completed on the first payout tick roughly half a second after the
	-- purchase, with no player action -- the same ceremony the arc spec stripped out of
	-- Mixer Training, and it raced its own quest-completion strike. The lesson it carried
	-- now lands on the completed card's lesson line, where the income jump is visible.
	first_automation = table.freeze({
		Id = "first_automation",
		ArcId = "opening_tutorial",
		Order = 3,
		Title = "First Automation",
		RequiresQuestIds = table.freeze({ "mixer_training" }),
		Reward = table.freeze({
			Kind = "Gems",
			Amount = 10,
			ReceiptId = "quest_reward_first_automation_v1",
		}),
		Steps = table.freeze({
			table.freeze({
				Id = "save_for_goo_clicker",
				Title = "Save Your Cookies",
				-- Cost and name both resolve live; AutoclickerUnlock.Cost is DevTuning-backed.
				-- "Earn" leaves the method open: by now the player has a producer, and buying
				-- more buildings is a legitimate way to reach the price.
				CompactObjective = "Earn cookies to buy the {Name}.",
				ObjectiveKind = "CookieBalanceAtLeast",
				ObjectiveTarget = "Autoclicker",
				DynamicCopy = "GooClickerSavings",
				-- No cue. Clicking the cookie was taught in quest 1 and the objective spells
				-- it out; pointing at it a third time is noise.
				GuideCapability = false,
			}),
			table.freeze({
				Id = "buy_goo_clicker",
				Title = "Hire the Goo Clicker",
				CompactObjective = "Buy the {Name} from the Upgrades tab.",
				ObjectiveKind = "UpgradePurchased",
				ObjectiveTarget = "Autoclicker",
				GuideCapability = true,
			}),
		}),
	}),
})

local function fail(message)
	error("QuestDefinitions: " .. message, 3)
end

local function validId(value)
	return type(value) == "string"
		and value ~= ""
		and not string.find(string.lower(value), "preview", 1, true)
		and not string.find(string.lower(value), "example", 1, true)
end

-- The upgrade whose DisplayName fills "{Name}" in this step's copy. Most steps already
-- name their upgrade in the objective target; CopyUpgradeId covers the ones whose target
-- is broader than the thing the sentence talks about (BuildingSold accepts "Any").
function QuestDefinitions.GetCopyUpgradeId(step)
	if type(step.CopyUpgradeId) == "string" then
		return step.CopyUpgradeId
	end
	local target = step.ObjectiveTarget
	if type(target) == "table" and type(target.UpgradeId) == "string" then
		return target.UpgradeId
	end
	if type(target) == "string" then
		return target
	end
	return nil
end

local function validateCopy(step)
	for _, field in ipairs({ "CompactObjective", "CompactObjectiveKeyboard" }) do
		local text = step[field]
		if type(text) == "string" and string.find(text, "{Name}", 1, true) then
			if not QuestDefinitions.GetCopyUpgradeId(step) then
				fail(("step %s uses {Name} with no upgrade to resolve it from"):format(step.Id))
			end
		end
	end
	if step.CopyUpgradeId ~= nil and type(step.CopyUpgradeId) ~= "string" then
		fail(("step %s has an invalid CopyUpgradeId"):format(step.Id))
	end
end

local function validateObjective(step)
	local kind = step.ObjectiveKind
	local target = step.ObjectiveTarget

	if kind == "ManualOwnerClickCount" then
		if type(target) ~= "number" or target < 1 or target % 1 ~= 0 then
			fail(("step %s needs a positive integer click target"):format(step.Id))
		end
	elseif kind == "BuildingCountAtLeast" then
		if
			type(target) ~= "table"
			or type(target.UpgradeId) ~= "string"
			or target.UpgradeId == ""
			or type(target.Count) ~= "number"
			or target.Count < 1
			or target.Count % 1 ~= 0
		then
			fail(("step %s needs an UpgradeId and a positive integer Count"):format(step.Id))
		end
	elseif kind == "ClientUiObservation" then
		if not QuestDefinitions.Observations[target] then
			fail(("step %s observes %s, which is not on the allowlist"):format(step.Id, tostring(target)))
		end
	elseif type(target) ~= "string" or target == "" then
		fail(("step %s needs a non-empty objective target"):format(step.Id))
	end
end

function QuestDefinitions.Validate()
	local questMembership = {}
	local capstoneReceipts = {}

	for arcId, arc in pairs(QuestDefinitions.Arcs) do
		if arc.Id ~= arcId or not validId(arcId) then
			fail("arc IDs must be stable, non-preview identifiers")
		end
		if type(arc.Order) ~= "number" or arc.Order < 1 or arc.Order % 1 ~= 0 then
			fail(("arc %s has an invalid order"):format(arcId))
		end
		if type(arc.QuestIds) ~= "table" or #arc.QuestIds < 1 then
			fail(("arc %s has no staged quests"):format(arcId))
		end
		if
			type(arc.DisplayQuestCount) ~= "number"
			or arc.DisplayQuestCount % 1 ~= 0
			or arc.DisplayQuestCount < #arc.QuestIds
		then
			fail(("arc %s has an invalid display quest count"):format(arcId))
		end
		local capstone = arc.CapstoneReward
		if type(capstone) ~= "table" or not validId(capstone.ReceiptId) then
			fail(("arc %s must declare one stable capstone receipt"):format(arcId))
		end
		if capstoneReceipts[capstone.ReceiptId] then
			fail(("duplicate capstone receipt %s"):format(capstone.ReceiptId))
		end
		capstoneReceipts[capstone.ReceiptId] = true

		for order, questId in ipairs(arc.QuestIds) do
			if questMembership[questId] then
				fail(("quest %s belongs to more than one arc"):format(questId))
			end
			questMembership[questId] = { ArcId = arcId, Order = order }
		end
	end

	local stepIds = {}
	local rewardReceipts = {}
	local dependencyGraph = {}
	for questId, quest in pairs(QuestDefinitions.Quests) do
		if quest.Id ~= questId or not validId(questId) then
			fail("quest IDs must be stable, non-preview identifiers")
		end
		local membership = questMembership[questId]
		if not membership or membership.ArcId ~= quest.ArcId or membership.Order ~= quest.Order then
			fail(("quest %s has invalid arc membership or ordering"):format(questId))
		end
		if type(quest.Steps) ~= "table" or #quest.Steps < 1 then
			fail(("quest %s has no steps"):format(questId))
		end
		local reward = quest.Reward
		if
			type(reward) ~= "table"
			or reward.Kind ~= "Gems"
			or type(reward.Amount) ~= "number"
			or reward.Amount < 0
			or reward.Amount % 1 ~= 0
			or not validId(reward.ReceiptId)
		then
			fail(("quest %s has an invalid reward"):format(questId))
		end
		if rewardReceipts[reward.ReceiptId] then
			fail(("duplicate quest reward receipt %s"):format(reward.ReceiptId))
		end
		rewardReceipts[reward.ReceiptId] = true
		dependencyGraph[questId] = {}
		for _, dependencyId in ipairs(quest.RequiresQuestIds or {}) do
			if not QuestDefinitions.Quests[dependencyId] then
				fail(("quest %s depends on missing quest %s"):format(questId, tostring(dependencyId)))
			end
			table.insert(dependencyGraph[questId], dependencyId)
		end

		for _, step in ipairs(quest.Steps) do
			if not validId(step.Id) or stepIds[step.Id] then
				fail(("quest %s has a duplicate or invalid step ID"):format(questId))
			end
			stepIds[step.Id] = true
			if not QuestDefinitions.ObjectiveKinds[step.ObjectiveKind] then
				fail(("step %s uses unsupported objective kind %s"):format(step.Id, tostring(step.ObjectiveKind)))
			end
			validateObjective(step)
			if step.CompactObjectiveKeyboard ~= nil and type(step.CompactObjectiveKeyboard) ~= "string" then
				fail(("step %s has an invalid keyboard copy variant"):format(step.Id))
			end
			validateCopy(step)
		end
	end

	for questId in pairs(questMembership) do
		if not QuestDefinitions.Quests[questId] then
			fail(("arc references missing quest %s"):format(questId))
		end
	end

	local visiting = {}
	local visited = {}
	local function visit(questId)
		if visiting[questId] then
			fail(("quest dependency cycle reaches %s"):format(questId))
		end
		if visited[questId] then
			return
		end
		visiting[questId] = true
		for _, dependencyId in ipairs(dependencyGraph[questId]) do
			visit(dependencyId)
		end
		visiting[questId] = nil
		visited[questId] = true
	end
	for questId in pairs(dependencyGraph) do
		visit(questId)
	end

	return true
end

-- Quests of an arc in authored order, so callers never depend on pairs() ordering.
function QuestDefinitions.GetArcQuests(arcId)
	local arc = QuestDefinitions.Arcs[arcId]
	local quests = {}
	if not arc then
		return quests
	end
	for _, questId in ipairs(arc.QuestIds) do
		local quest = QuestDefinitions.Quests[questId]
		if quest then
			table.insert(quests, quest)
		end
	end
	return quests
end

function QuestDefinitions.GetArcsInOrder()
	local arcs = {}
	for _, arc in pairs(QuestDefinitions.Arcs) do
		table.insert(arcs, arc)
	end
	table.sort(arcs, function(a, b)
		return a.Order < b.Order
	end)
	return arcs
end

QuestDefinitions.Validate()
return table.freeze(QuestDefinitions)
