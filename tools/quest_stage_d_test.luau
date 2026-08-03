--!nocheck
-- Pure Stage D content, copy, guide, and Understanding Upgrades acceptance tests.

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
		require = function(target)
			return loadModule(assert(SOURCES[target.Path] and target.Path, "unknown module " .. tostring(target.Path)))
		end,
		warn = function() end,
	}, { __index = getfenv() })
	setfenv(chunk, env)
	local result = chunk()
	cache[name] = result
	return result
end

local DomainEvents = loadModule("DomainEvents")
local UiObservations = loadModule("UiObservations")
local QuestCopy = loadModule("QuestCopy")
local QuestContentReader = loadModule("QuestContentReader")
local Objectives = loadModule("Objectives.Registry")
local Rewards = loadModule("Rewards.Registry")
local Schema = loadModule("QuestSchema")
local Engine = loadModule("QuestEngine")
local FactProvider = loadModule("QuestFactProvider")
local OpeningTutorial = loadModule("Content.OpeningTutorial")
local Manifest = loadModule("Content.Manifest")
local GuideKinds = loadModule("QuestProgressGuideKinds")
local ClientPolicies = loadModule("QuestProgressPresentationPolicies").new()

local failures = 0
local function check(label, condition, detail)
	if condition then
		print("  ok   " .. label)
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and " -- " .. tostring(detail) or ""))
	end
end

local function rejects(label, callback, needle)
	local ok, problem = pcall(callback)
	check(label, not ok and string.find(tostring(problem), needle, 1, true) ~= nil, problem)
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key)] = clone(child) end
	return result
end

local function render(step, projection, inputKind)
	return QuestCopy.Render(step.Copy, projection, {
		InputKind = inputKind,
		FormatNumber = function(value) return tostring(math.floor(value)) end,
		ResolveUpgradeDisplayName = function(upgradeId)
			return ({
				["Noob Clicker"] = "Noob Clicker",
				["Noob Clicker Upgrades"] = "Steady Hands",
				Autoclicker = "Goo Clicker",
			})[upgradeId]
		end,
	})
end

print("\nDeclarative opening content")
local arc = Manifest.ArcsById.opening_tutorial
check("opening manifest retains the canonical quests 1-4 definitions", #Manifest.Definitions == 5 and #arc.QuestIds == 5
	and Manifest.Definitions[4].Id == "understanding_upgrades")
check("approved arc header remains x/5", arc.DisplayQuestCount == 5)
local gemTotal = 0
local fullyDeclared = true
local policiesResolvable = true
for index, definition in ipairs(Manifest.Definitions) do
	if index <= 4 then gemTotal += definition.Rewards[1].Params.Amount end
	fullyDeclared = fullyDeclared
		and definition.Title ~= nil
		and definition.Lesson == nil
		and definition.Help.Enabled == true
		and definition.Presentation.QuestCompletion ~= nil
	policiesResolvable = policiesResolvable and ClientPolicies:Get(definition.Presentation.QuestCompletion, "Quest") ~= nil
	for _, step in ipairs(definition.Steps) do
		fullyDeclared = fullyDeclared
			and step.Title ~= nil
			and step.Copy ~= nil
			and step.Presentation ~= nil
			and step.Presentation.StepCompletion ~= nil
		policiesResolvable = policiesResolvable and ClientPolicies:Get(step.Presentation.StepCompletion, "Step") ~= nil
		for _, milestone in ipairs(step.Presentation.Milestones or {}) do
			policiesResolvable = policiesResolvable and ClientPolicies:Get(milestone.Policy, "Step") ~= nil
		end
	end
end
check("quests 1-4 retain the approved 40-gem declaration", gemTotal == 40, gemTotal)
check("copy, help, rewards, and presentation remain content-owned while lessons are deferred", fullyDeclared)
check("every authored timing/strike policy resolves in the client registry", policiesResolvable)
check("chapter replay is declared once on canonical quest 1", Manifest.Definitions[1].Replay.Enabled == true)
local canonicalHelp = assert(QuestContentReader.BuildHelp(Manifest, "gooey_beginning", nil, {}))
local canonicalReplay = assert(QuestContentReader.BuildReplay(Manifest, "gooey_beginning", nil, {}))
check(
	"Help and replay read the same canonical title and steps",
	canonicalHelp.Title == canonicalReplay.Title and #canonicalHelp.Steps == #canonicalReplay.Steps
)

local q2 = Manifest.DefinitionsById.mixer_training
local countText = render(q2.StepById.hire_another_noob, {
	Phase = "Collecting", Current = 1, Target = 2,
	Tokens = { UpgradeId = "Noob Clicker", Current = 1, Target = 2 },
}, "Touch")
check("structural count-up renders without rewriting prose", countText == "Buy a second Noob Clicker. (1/2)", countText)
local buildViewText = render(q2.StepById.look_from_above, {
	Phase = "WaitingForObservation", Current = 0, Target = 1, Tokens = {},
}, "Keyboard")
check("device variants are canonical content", buildViewText == "Open Build View (V) to see your plot from above.", buildViewText)

local q1 = Manifest.DefinitionsById.gooey_beginning
local firstHelper = q1.StepById.build_first_helper
local saving = render(firstHelper, {
	Phase = "Saving", Current = 4, Target = 15,
	Tokens = { UpgradeId = "Noob Clicker", Current = 4, Target = 15 },
}, "Touch")
local affordable = render(firstHelper, {
	Phase = "Affordable", Current = 15, Target = 15,
	Tokens = { UpgradeId = "Noob Clicker", Current = 15, Target = 15 },
}, "Touch")
check("affordability phase copy and progress are declarative", saving == "Save 15 cookies for a Noob Clicker. (4/15)", saving)
check("affordable phase structurally drops its count", affordable == "Place a Noob Clicker from the Mixer.", affordable)

local rubble = q1.StepById.unearth_cookie.LocalProgress
local rubbleProjection = assert(QuestCopy.ProjectLocal(rubble, 2))
local card = QuestCopy.Render(rubble.Card, rubbleProjection, {
	InputKind = "Touch", FormatNumber = tostring,
})
local prompt = QuestCopy.Render(rubble.Prompt, rubbleProjection, {
	InputKind = "Touch", FormatNumber = tostring,
})
check("rubble card counts up from the shared projection", card == "Clear the meteor rubble. (2/5)", card)
check("rubble prompt counts down from that same projection", prompt == "Clear the rubble! (3 left)", prompt)

print("\nValidation failures")
local malformed = clone(OpeningTutorial)
malformed.Definitions[1].Steps[1].Copy.Default.Fallback = "Bad {Missing}."
rejects("undeclared copy token fails at validation", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "undeclared token")
malformed = clone(OpeningTutorial)
malformed.Definitions[1].Steps[3].Presentation.Guide.Frame = "InventedFrame"
rejects("unknown GuideFrame fails at validation", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "unknown GuideFrame")
malformed = clone(OpeningTutorial)
malformed.Definitions[1].Steps[1].Presentation.StepCompletion = "OneOffBranch"
rejects("unknown presentation policy fails at validation", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "unknown step completion policy")
malformed = clone(OpeningTutorial)
malformed.Definitions[1].Steps[5].Presentation.Milestones[1].Phase = "MadeUpPhase"
rejects("unknown authored phase fails at validation", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "invalid objective phase")
malformed = clone(OpeningTutorial)
malformed.Definitions[1].Steps[1].Copy.Default.Fallback = nil
rejects("missing localization fallback fails at validation", function()
	Schema.ValidateManifest(malformed, Objectives, Rewards)
end, "localization fallback")

print("\nUnderstanding Upgrades acceptance")
local q4 = Manifest.DefinitionsById.understanding_upgrades
check(
	"Quest 4 uses only the three approved objective kinds",
	q4.Steps[1].Objective.Kind == "BuildingCountAtLeast"
		and q4.Steps[2].Objective.Kind == "ClientUiObservation"
		and q4.Steps[3].Objective.Kind == "UpgradePurchased"
)
check(
	"Quest 4 count target is config-derived, not a copied literal",
	q4.Steps[1].Objective.Params.Count == nil
		and q4.Steps[1].Objective.Params.CountFromUpgradeId == "Noob Clicker Upgrades"
)
local provider = FactProvider.new({
	Content = Manifest,
	UpgradeConfig = {
		["Noob Clicker"] = { BaseCost = 15 },
		["Noob Clicker Upgrades"] = { Levels = { { UnlockCount = 13 } } },
		Autoclicker = { BaseCost = 200 },
	},
	BoostShopConfig = {
		Order = { "PowerField", "SpeedField" },
		Items = { PowerField = { PriceGems = 40 }, SpeedField = { PriceGems = 40 } },
	},
	GetUpgradeCost = function(config) return config.BaseCost end,
})
local configuredFacts = provider:Build({}, {
	Data = { Persistent = {}, Run = { Cookies = 0, UpgradeCounts = {} } },
})
local configuredResult = assert(Objectives.Evaluate(q4.Steps[1].Objective, configuredFacts, {}))
check(
	"Quest 4 target follows the configured first-level UnlockCount",
	configuredResult.Target == 13,
	configuredResult.Target
)
check(
	"real nudge observation is narrowly allowlisted",
	UiObservations.IsAllowed("UpgradeNudgeActivated")
		and not UiObservations.IsAllowed("CompleteQuest")
		and DomainEvents.Validate("UiObservation", { Observation = "CompleteQuest" }, 1) == nil
)

local isolatedAuthored = clone(OpeningTutorial)
isolatedAuthored.Arcs[1].QuestIds = { "understanding_upgrades" }
isolatedAuthored.Arcs[1].Reward = nil
isolatedAuthored.Definitions = { clone(OpeningTutorial.Definitions[4]) }
isolatedAuthored.Definitions[1].Order = 1
isolatedAuthored.Definitions[1].RequiresDefinitionIds = {}
local isolated = Schema.ValidateManifest(isolatedAuthored, Objectives, Rewards)
local function facts(buildings, upgrade)
	return {
		StoryFacts = {}, HealingManualClicks = 0, HealingSequenceCompleted = false,
		UpgradeCounts = {
			["Noob Clicker"] = buildings or 0,
			["Noob Clicker Upgrades"] = upgrade or 0,
		},
		UpgradeCosts = {}, UpgradeUnlockCounts = { ["Noob Clicker Upgrades"] = 10 }, CookieBalance = 0,
		GemBalance = 0, BoostPriceGems = 40,
	}
end
local state, session = Schema.NewState(isolated), {}
state, session = Engine.reduce(isolated, state, facts(9, 0), { Kind = "FullReconcile", Timestamp = 1 }, session)
local instanceId = isolated.Definitions[1].InstanceId
check("Quest 4 waits for the live configured building count", state.Instances[instanceId].StepIndex == 1)
state, session = Engine.reduce(isolated, state, facts(10, 0), assert(DomainEvents.Validate(
	"BuildingCountChanged", { UpgradeId = "Noob Clicker", Count = 10 }, 2
)), session)
check("ten buildings advances to the real nudge observation", state.Instances[instanceId].StepIndex == 2)
state, session = Engine.reduce(isolated, state, facts(10, 0), assert(DomainEvents.Validate(
	"UiObservation", { Observation = "UpgradeNudgeActivated" }, 3
)), session)
check("genuine nudge activation advances to Steady Hands", state.Instances[instanceId].StepIndex == 3)
local effects
state, session, _, effects = Engine.reduce(isolated, state, facts(10, 1), assert(DomainEvents.Validate(
	"UpgradePurchased", { UpgradeId = "Noob Clicker Upgrades", Count = 1 }, 4
)), session)
check("committed Steady Hands purchase reaches the declared reward", state.Instances[instanceId].RewardPending and #effects > 0)

local earlyState, earlySession = Schema.NewState(isolated), {}
earlyState, earlySession = Engine.reduce(isolated, earlyState, facts(0, 1), assert(DomainEvents.Validate(
	"UpgradePurchased", { UpgradeId = "Noob Clicker Upgrades", Count = 1 }, 5
)), earlySession)
check(
	"buying Steady Hands directly implies count and nudge without a simulated pulse",
	earlyState.Instances[instanceId].RewardPending == true
)

local q4Default = render(q4.StepById.follow_the_pulse, {
	Phase = "WaitingForObservation", Current = 0, Target = 1,
	Tokens = { UpgradeId = "Noob Clicker" },
}, "Touch")
local q4Keyboard = render(q4.StepById.follow_the_pulse, {
	Phase = "WaitingForObservation", Current = 0, Target = 1,
	Tokens = { UpgradeId = "Noob Clicker" },
}, "Keyboard")
check("Quest 4 touch copy says Tap", q4Default == "Tap the pulse on the Noob Clicker card.", q4Default)
check("Quest 4 keyboard copy says Click", q4Keyboard == "Click the pulse on the Noob Clicker card.", q4Keyboard)

print("\nReusable guide and publisher boundaries")
local resolvedNodes = {}
local guideRunner = GuideKinds.new({
	Content = Manifest,
	Targets = {
		IsSurfaceOpen = function(surface)
			table.insert(resolvedNodes, "StoreOpenPath:" .. tostring(surface))
			return true
		end,
		UiControl = function(targetId)
			table.insert(resolvedNodes, "UiControl:" .. tostring(targetId))
			return targetId
		end,
	},
	Show = function() return function() end end,
})
local guideOutcome
guideRunner:Start({
	Instance = { DefinitionId = "understanding_upgrades" },
	Step = { StepId = "follow_the_pulse", Projection = { Phase = "WaitingForObservation" } },
}, function(outcome) guideOutcome = outcome end)
check(
	"Quest 4 nudge uses the reusable surface navigation path",
	guideOutcome == "completed"
		and table.concat(resolvedNodes, ",") == "StoreOpenPath:Mixer,UiControl:UpgradeNudge",
	table.concat(resolvedNodes, ",")
)
check(
	"real StoreUpgradeNudge publishes only after its navigation action",
	string.find(STORE_NUDGE_SOURCE, "ctx.openUpgradeCategory(targetUpgradeId)", 1, true)
		and string.find(STORE_NUDGE_SOURCE, 'Publish("UpgradeNudgeActivated")', 1, true)
)
check(
	"observation bus registers no live transport",
	not string.find(OBSERVATION_BUS_SOURCE, "Net", 1, true)
		and not string.find(OBSERVATION_BUS_SOURCE, "Remote", 1, true)
		and not string.find(V2_CONTROLLER_SOURCE, "QuestProgressObservationBus", 1, true)
)
check(
	"canonical replay owns no duplicate quest prose",
	not string.find(REPLAY_SOURCE, "Watch the Goo's meteor", 1, true)
		and not string.find(REPLAY_SOURCE, "Clear the meteor rubble", 1, true)
		and string.find(REPLAY_SOURCE, "QuestContentReader.RenderStep", 1, true)
)
check(
	"replacement Help consumes the canonical content reader",
	string.find(HELP_SOURCE, "QuestContentReader", 1, true)
		and not string.find(HELP_SOURCE, "Objective =", 1, true)
)
check("replacement reward boundary is active", string.find(QUEST_SERVICE_SOURCE, "Enabled = true", 1, true) ~= nil)

local forbidden = {
	"IN_PLACE_STRIKE_STEPS", "GATED_STEPS", "COOKIE_SAVING_STEPS", "CATCH_ROW_STEPS", "dynamicCopy",
}
local replacementSources = table.concat({
	SOURCES["QuestEngine"], SOURCES["QuestSchema"], SOURCES["QuestCopy"],
	SOURCES["QuestProgressGuideKinds"], SOURCES["PresentationPolicySchema"],
}, "\n")
local clean = true
for _, needle in ipairs(forbidden) do clean = clean and not string.find(replacementSources, needle, 1, true) end
check("replacement implementation has no retired step-specific tables or dynamic copy", clean)
check(
	"Quest 4 identity appears only in content among replacement orchestration sources",
	not string.find(replacementSources, "understanding_upgrades", 1, true)
		and not string.find(replacementSources, "follow_the_pulse", 1, true)
		and not string.find(replacementSources, "steady_hands", 1, true)
)

print(("\n%d failure(s)"):format(failures))
if failures > 0 then error(("Stage D quest content has %d failure(s)"):format(failures)) end
