-- Canonical definitions for the staged tutorial-quest rollout.
-- Only A Gooey Beginning ships in Stage 1. DisplayQuestCount keeps the approved
-- five-quest arc presentation without exposing or inventing the later quests.

local QuestDefinitions = {}

QuestDefinitions.SchemaVersion = 2
QuestDefinitions.ObjectiveKinds = table.freeze({
	StoryTransition = true,
	ManualOwnerClickCount = true,
	BuildingPlaced = true,
})

QuestDefinitions.Arcs = table.freeze({
	opening_tutorial = table.freeze({
		Id = "opening_tutorial",
		Order = 1,
		Title = "Getting Started",
		UnlockCondition = table.freeze({ Kind = "Always" }),
		QuestIds = table.freeze({ "gooey_beginning" }),
		DisplayQuestCount = 5,
		CapstoneReward = table.freeze({
			ReceiptId = "opening_tutorial_capstone",
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
				CompactObjective = "Clear the rubble around the cookie.",
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

QuestDefinitions.Validate()
return table.freeze(QuestDefinitions)
