-- Builds the bounded canonical fact projection requested by registered definitions.

local QuestFactProvider = {}
QuestFactProvider.__index = QuestFactProvider

local STORY_ORDER = { "Meteor", "Healing", "Lore", "BuildTask", "Complete" }

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function QuestFactProvider.new(config)
	assert(type(config) == "table" and type(config.Content) == "table", "QuestFactProvider needs content")
	assert(
		type(config.UpgradeConfig) == "table" and type(config.GetUpgradeCost) == "function",
		"QuestFactProvider needs upgrades"
	)
	assert(type(config.BoostShopConfig) == "table", "QuestFactProvider needs boost-shop config")
	for _, definition in ipairs(config.Content.Definitions) do
		for _, step in ipairs(definition.Steps) do
			local params = step.Objective.Params or {}
			if params.CountFromUpgradeId then
				local upgrade = config.UpgradeConfig[params.CountFromUpgradeId]
				local firstLevel = upgrade and type(upgrade.Levels) == "table" and upgrade.Levels[1]
				local target = firstLevel and tonumber(firstLevel.UnlockCount)
				assert(
					type(target) == "number" and target == target and target % 1 == 0 and target >= 1,
					"QuestFactProvider invalid configured count source " .. params.CountFromUpgradeId
				)
			end
			if params.ShowAffordability == true then
				assert(
					config.UpgradeConfig[params.UpgradeId] ~= nil,
					"QuestFactProvider invalid affordability upgrade " .. tostring(params.UpgradeId)
				)
			end
		end
	end
	return setmetatable(config, QuestFactProvider)
end

function QuestFactProvider:Build(_, context)
	local data = context.Data
	local persistent = type(data) == "table" and data.Persistent or {}
	local run = type(data) == "table" and data.Run or {}
	local rawCounts = type(run.UpgradeCounts) == "table" and run.UpgradeCounts or {}
	local facts = {
		StoryFacts = {},
		HealingManualClicks = math.clamp(math.floor(tonumber(persistent.StoryHealingClicks) or 0), 0, 1000000),
		HealingSequenceCompleted = false,
		UpgradeCounts = {},
		UpgradeCosts = {},
		UpgradeUnlockCounts = {},
		CookieBalance = 0,
		GemBalance = 0,
		BoostPriceGems = 0,
	}
	local cookies = tonumber(run.Cookies) or 0
	if finite(cookies) then
		facts.CookieBalance = math.max(0, cookies)
	end
	local gems = tonumber(persistent.Gems) or 0
	if finite(gems) then
		facts.GemBalance = math.clamp(math.floor(gems), 0, 1000000000)
	end
	for _, itemId in ipairs(self.BoostShopConfig.Order or {}) do
		local item = self.BoostShopConfig.Items and self.BoostShopConfig.Items[itemId]
		local price = item and tonumber(item.PriceGems)
		if finite(price) and price >= 1 then
			price = math.floor(price)
			if facts.BoostPriceGems == 0 then
				facts.BoostPriceGems = price
			else
				assert(facts.BoostPriceGems == price, "opening boost choices must share one live price")
			end
		end
	end
	assert(facts.BoostPriceGems >= 1, "QuestFactProvider has no valid boost price")

	local storyRank = 1
	for rank, step in ipairs(STORY_ORDER) do
		if persistent.StoryStep == step then
			storyRank = rank
		end
	end
	for rank, step in ipairs(STORY_ORDER) do
		if storyRank >= rank then
			facts.StoryFacts[step] = true
		end
	end
	if persistent.IntroSeen == true or storyRank >= 2 then
		facts.StoryFacts.IntroCompleted = true
	end
	if storyRank >= 2 then
		facts.StoryFacts.RubbleCleared = true
	end
	if storyRank >= 3 then
		facts.HealingSequenceCompleted = true
		facts.HealingManualClicks = math.max(facts.HealingManualClicks, 5)
	end
	if storyRank >= 4 or persistent.MixerUnlocked == true then
		facts.StoryFacts.LoreCompleted = true
	end

	local requiredUpgradeIds = {}
	for _, definition in ipairs(self.Content.Definitions) do
		for _, step in ipairs(definition.Steps) do
			local params = step.Objective.Params
			if type(params) == "table" and type(params.UpgradeId) == "string" then
				requiredUpgradeIds[params.UpgradeId] = true
			end
			if type(params) == "table" and type(params.ImpliedByUpgradeId) == "string" then
				requiredUpgradeIds[params.ImpliedByUpgradeId] = true
			end
			if type(params) == "table" and type(params.CountFromUpgradeId) == "string" then
				requiredUpgradeIds[params.CountFromUpgradeId] = true
			end
		end
	end
	for upgradeId in pairs(requiredUpgradeIds) do
		local count = tonumber(rawCounts[upgradeId]) or 0
		if finite(count) then
			count = math.clamp(math.floor(count), 0, 1000000000)
		else
			count = 0
		end
		facts.UpgradeCounts[upgradeId] = count
		local config = self.UpgradeConfig[upgradeId]
		local firstLevel = config and type(config.Levels) == "table" and config.Levels[1]
		local unlockCount = firstLevel and tonumber(firstLevel.UnlockCount)
		if finite(unlockCount) and unlockCount >= 1 then
			facts.UpgradeUnlockCounts[upgradeId] = math.floor(unlockCount)
		end
		local cost = config and self.GetUpgradeCost(config, count)
		if finite(cost) and cost > 0 then
			facts.UpgradeCosts[upgradeId] = math.floor(cost)
		end
	end
	return facts
end

return QuestFactProvider
