--!nocheck
-- Stage E production-content, Quest 5, and atomic-cutover acceptance.

local cache = {}
local function node(path)
	return setmetatable({ Path = path }, {
		__index = function(_, key)
			if key == "Parent" then return node(string.match(path, "^(.*)%.[^.]+$") or "") end
			return node(path == "" and key or path .. "." .. key)
		end,
	})
end

local function loadModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadstring(assert(SOURCES[name], "missing source " .. name)))
	local env
	env = setmetatable({
		script = node(name),
		Color3 = { fromRGB = function(r, g, b) return { R = r / 255, G = g / 255, B = b / 255 } end },
		require = function(target)
			return loadModule(assert(SOURCES[target.Path] and target.Path, "unknown module " .. tostring(target.Path)))
		end,
		warn = function() end,
	}, { __index = getfenv() })
	setfenv(chunk, env)
	local value = chunk()
	cache[name] = value
	return value
end

local DomainEvents = loadModule("DomainEvents")
local UiObservations = loadModule("UiObservations")
local QuestCopy = loadModule("QuestCopy")
local Objectives = loadModule("Objectives.Registry")
local Rewards = loadModule("Rewards.Registry")
local Schema = loadModule("QuestSchema")
local Engine = loadModule("QuestEngine")
local EffectRunner = loadModule("Quest.QuestEffectRunner")
local Opening = loadModule("Content.OpeningTutorial")
local Manifest = loadModule("Content.Manifest")
local Growing = loadModule("Content.GrowingBakeryFixture")
local GooSkinConfig = loadModule("GooSkinConfig")

local failures = 0
local function check(label, condition, detail)
	if condition then
		print("  ok   " .. label)
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and " -- " .. tostring(detail) or ""))
	end
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key)] = clone(child) end
	return result
end

local function facts(gems)
	return {
		StoryFacts = {}, HealingManualClicks = 0, HealingSequenceCompleted = false,
		UpgradeCounts = {}, UpgradeCosts = {}, UpgradeUnlockCounts = {}, CookieBalance = 0,
		GemBalance = gems or 0, BoostPriceGems = 40,
	}
end

local function event(kind, payload, at)
	return assert(DomainEvents.Validate(kind, payload, at or 1))
end

print("\nPowering Up declarative acceptance")
local q5 = Manifest.DefinitionsById.powering_up
check("shipping manifest contains all five quests", #Manifest.Definitions == 5 and Manifest.Arcs[1].DisplayQuestCount == 5)
check("Powering Up uses only reusable registered kinds",
	q5.Steps[1].Objective.Kind == "ClientUiObservation"
		and q5.Steps[2].Objective.Kind == "BoostPurchased"
		and q5.Steps[3].Objective.Kind == "BoostFieldDropped"
		and Rewards.Get("GooSkin") ~= nil)
check("Boost shop approach is narrowly allowlisted",
	UiObservations.IsAllowed("BoostShopApproached")
		and DomainEvents.Validate("UiObservation", { Observation = "GrantGooSkin" }, 1) == nil)
check("arc reward references the capstone slot declaratively",
	Manifest.Arcs[1].Reward.DefinitionId == q5.Id
		and Manifest.Arcs[1].Reward.SlotId == q5.Rewards[1].SlotId)
local meteor = GooSkinConfig.GetSkinDef("Goo::Meteor")
check("Meteor Goo is an earned non-rollable x1.05 capstone",
	meteor and meteor.RarityId == "Earned" and meteor.Rollable == false
		and GooSkinConfig.GetMultiplier(meteor.Id) == 1.05)
check("economy simulator exercises the same x1.05 capstone value",
	string.find(ECONOMY_SIM_SOURCE, "OPENING_QUEST_SKIN_MULTIPLIER = 1.05", 1, true) ~= nil)

local shortfall = assert(Objectives.Evaluate(q5.Steps[2].Objective, facts(25), {}))
local affordable = assert(Objectives.Evaluate(q5.Steps[2].Objective, facts(40), {}))
local copyContext = { FormatNumber = function(value) return tostring(math.floor(value)) end }
local shortfallCopy = assert(QuestCopy.Render(q5.Steps[2].Copy, shortfall, copyContext))
local affordableCopy = assert(QuestCopy.Render(q5.Steps[2].Copy, affordable, copyContext))
check("live boost price drives shortfall progress", shortfallCopy == "Earn 40 gems to buy a boost field. (25/40)", shortfallCopy)
check("live boost price drives affordable instruction", affordableCopy == "Buy a Power Field or a Speed Field for 40 gems.", affordableCopy)

local isolatedAuthored = clone(Opening)
isolatedAuthored.Arcs[1].QuestIds = { "powering_up" }
isolatedAuthored.Definitions = { clone(Opening.Definitions[5]) }
isolatedAuthored.Definitions[1].Order = 1
isolatedAuthored.Definitions[1].RequiresDefinitionIds = {}
local isolated = Schema.ValidateManifest(isolatedAuthored, Objectives, Rewards)
local state, session = Schema.NewState(isolated), {}
state, session = Engine.reduce(isolated, state, facts(40), { Kind = "FullReconcile", Timestamp = 1 }, session)
local id = isolated.Definitions[1].InstanceId
state, session = Engine.reduce(isolated, state, facts(40), event("UiObservation", { Observation = "BoostShopApproached" }, 2), session)
check("validated approach observation advances to purchase", state.Instances[id].StepIndex == 2)
state, session = Engine.reduce(isolated, state, facts(0), event("BoostPurchased", { ItemId = "PowerField", ChargeCount = 1 }, 3), session)
check("committed purchase advances to drop", state.Instances[id].StepIndex == 3)
local effects
state, session, _, effects = Engine.reduce(isolated, state, facts(0), event("BoostFieldDropped", {
	ItemId = "PowerField", FloorId = "Floor1", OwnerUserId = 7, DropperUserId = 8,
}, 4), session)
local rewardEffect
for _, effectValue in ipairs(effects) do if effectValue.Kind == "RewardGrant" then rewardEffect = effectValue end end
check("accepted cross-plot field drop reaches capstone reward", state.Instances[id].RewardPending and rewardEffect ~= nil)

local grants = 0
local runner = EffectRunner.new({
	Engine = Engine,
	Enabled = true,
	ExecuteReward = function(_, _, effectValue)
		check("capstone effect carries stable goo-skin identity",
			effectValue.RewardKind == "GooSkin" and effectValue.Params.SkinId == "Goo::Meteor")
		grants += 1
		return true
	end,
	ExecuteAnalytics = function() end,
})
local succeeded
state, session, _, _, succeeded = runner:Execute({}, isolated, state, session, rewardEffect, { Kind = "FullReconcile", Timestamp = 5 })
runner:Execute({}, isolated, state, session, rewardEffect, { Kind = "FullReconcile", Timestamp = 6 })
check("goo-skin reward receipt makes the adapter idempotent", succeeded and grants == 1 and state.RewardReceipts[rewardEffect.ReceiptId] == true, grants)

print("\nContent-only scaling fixture")
local growingManifest = Schema.ValidateManifest(Growing.Manifest, Objectives, Rewards)
local noRewards = Growing.Shipping == false and Manifest.ArcsById.growing_bakery == nil
for _, definition in ipairs(growingManifest.Definitions) do noRewards = noRewards and #definition.Rewards == 0 end
check("Growing the Bakery validates but is not shipping", #growingManifest.Definitions == 4 and noRewards)

print("\nAtomic cutover boundaries")
check("only protocol-v2 quest remotes remain",
	string.find(REMOTE_NAMES_SOURCE, "QuestReadyV2", 1, true)
		and string.find(REMOTE_NAMES_SOURCE, "QuestEnvelopeV2", 1, true)
		and not string.find(REMOTE_NAMES_SOURCE, "QuestAction =", 1, true)
		and not string.find(REMOTE_NAMES_SOURCE, "QuestSnapshot =", 1, true))
check("client binds envelope before Ready and sends dedicated intents",
	string.find(CLIENT_SOURCE, "QuestProgressV2Controller.new", 1, true)
		and string.find(CLIENT_SOURCE, "QuestObservationV2", 1, true)
		and string.find(CLIENT_SOURCE, "QuestPreferenceV2", 1, true)
		and string.find(CLIENT_SOURCE, "QuestSelectV2", 1, true)
		and not string.find(CLIENT_SOURCE, "QuestAction", 1, true))
check("fresh quest profile has no legacy migration or dual state",
	string.find(PLAYER_DATA_SOURCE, "UniversalQuestState", 1, true)
		and not string.find(PLAYER_DATA_SOURCE, "\n\tQuestState =", 1, true))
check("server reward is active and suppresses the legacy gem presentation event",
	string.find(QUEST_SERVICE_SOURCE, "Enabled = true", 1, true)
		and string.find(QUEST_SERVICE_SOURCE, "SuppressPresentation = true", 1, true)
		and string.find(GEM_SERVICE_SOURCE, "SuppressPresentation", 1, true))
check("committed boost publishers run after charge/drop mutation",
	string.find(BOOST_SHOP_SOURCE, 'NotifyDomain(player, "BoostPurchased"', 1, true)
		and string.find(BOOST_FIELD_SOURCE, 'NotifyDomain(player, "BoostFieldDropped"', 1, true))
check("genuine prompt publisher emits only an allowlisted observation",
	string.find(BOOST_PROMPTS_SOURCE, 'Publish("BoostShopApproached")', 1, true)
		and not string.find(BOOST_PROMPTS_SOURCE, "QuestId", 1, true))
check("arc reward and the two progress surfaces retain separate generic bindings",
	string.find(RENDERER_SOURCE, 'child(trackedBody, "QuestProgressBar", "Frame")', 1, true)
		and string.find(RENDERER_SOURCE, 'root:SetAttribute("Progress", arcProgress(arc, instance))', 1, true)
		and string.find(RENDERER_SOURCE, "definition.RewardBySlotId", 1, true)
		and string.find(RENDERER_SOURCE, "CursorTooltip.get(screenGui):registerGui", 1, true))
check("transition presentation is isolated from the successor quest",
	string.find(RENDERER_SOURCE, "findInstance(snapshot, eventDisplay.InstanceId)", 1, true)
		and string.find(RENDERER_SOURCE, "InstanceId = transition.InstanceId", 1, true))
check("client-only milestones retain immutable quest and step identity",
	string.find(CLIENT_SOURCE, "InstanceId = selected.InstanceId", 1, true)
		and string.find(CLIENT_SOURCE, "StepId = step.Id", 1, true)
		and string.find(PRESENTATION_QUEUE_SOURCE, "InstanceId = event.InstanceId", 1, true)
		and string.find(PRESENTATION_QUEUE_SOURCE, "StepId = event.StepId", 1, true))
check("session replacement clears queued presentation state atomically",
	string.find(PRESENTATION_QUEUE_SOURCE, "function QuestProgressPresentationQueue:Reset(snapshot)", 1, true)
		and string.find(CLIENT_SOURCE, "if strikeVisual and metadata.SessionChanged then", 1, true)
		and not string.find(CLIENT_SOURCE, "if strikeVisual and (metadata.SessionChanged or metadata.TransitionCount == 0)", 1, true))
check("live currency progress is objective-owned and renderer-generic",
	Objectives.Get("BuildingPlaced").LiveProgress.Source == "CookieBalance"
		and Objectives.Get("BoostPurchased").LiveProgress.Source == "GemBalance"
		and string.find(RENDERER_SOURCE, "ResolveLiveProgress", 1, true)
		and not string.find(RENDERER_SOURCE, "CookieBalanceAtLeast", 1, true)
		and not string.find(RENDERER_SOURCE, "BoostPurchased", 1, true))
check("live currency presentation reacts without owning completion",
	string.find(CLIENT_SOURCE, 'GetPropertyChangedSignal("Value")', 1, true)
		and string.find(CLIENT_SOURCE, "GetAttributeChangedSignal(Attrs.Gems)", 1, true)
		and string.find(CLIENT_SOURCE, "RefreshLiveProgress", 1, true))
check("quest gem copy follows the held currency display without mutating event-time copy",
	string.find(CURRENCY_CONTROLLER_SOURCE, "SetAttribute(Attrs.DisplayedGems", 1, true)
		and string.find(CLIENT_SOURCE, "GetAttribute(Attrs.DisplayedGems)", 1, true)
		and string.find(CLIENT_SOURCE, "GetAttributeChangedSignal(Attrs.DisplayedGems)", 1, true)
		and string.find(RENDERER_SOURCE, "if replay or eventDisplay or completionInstanceId or barAwaitingPresentation then return end", 1, true))

local forbidden = { "IN_PLACE_STRIKE_STEPS", "GATED_STEPS", "COOKIE_SAVING_STEPS", "CATCH_ROW_STEPS", "dynamicCopy" }
local orchestration = table.concat({ QUEST_SERVICE_SOURCE, CLIENT_SOURCE, RENDERER_SOURCE, GUIDE_TARGET_SOURCE }, "\n")
local clean = true
for _, needle in ipairs(forbidden) do clean = clean and not string.find(orchestration, needle, 1, true) end
check("shipping orchestration has no retired step-specific inference tables", clean)
check("Quest 5 IDs occur only in declarative content",
	not string.find(orchestration, "find_boost_shop", 1, true)
		and not string.find(orchestration, "buy_boost_field", 1, true)
		and not string.find(orchestration, "drop_boost_field", 1, true))

print(("\n%d failure(s)"):format(failures))
if failures > 0 then error(("Stage E quest cutover has %d failure(s)"):format(failures)) end
