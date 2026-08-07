-- Thin production orchestrator for the universal protocol-v2 quest system.
-- Gameplay services publish committed outcomes through NotifyDomain; this module
-- owns composition, fresh quest persistence, validated client ingress, and transport.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local BoostShopConfig = require(Shared.BoostShopConfig)
local Net = require(Shared.Net)
local QuestProtocol = require(Shared.Quest.QuestProtocol)
local QuestSchema = require(Shared.Quest.QuestSchema)
local QuestEngine = require(Shared.Quest.QuestEngine)
local DomainEvents = require(Shared.Quest.DomainEvents)
local UiObservations = require(Shared.Quest.UiObservations)
local Manifest = require(Shared.Quest.Content.Manifest)
local RewardRegistry = require(Shared.Quest.Rewards.Registry)
local StoryConfig = require(Shared.StoryConfig)
local UpgradeConfig = require(Shared.UpgradeConfig)
local UpgradePricing = require(Shared.UpgradePricing)

local GemService = require(script.Parent.GemService)
local GooSkinService = require(script.Parent.GooSkinService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestAnalyticsService = require(script.Parent.QuestAnalyticsService)
local QuestEffectRunner = require(script.Parent.Quest.QuestEffectRunner)
local QuestEventRouter = require(script.Parent.Quest.QuestEventRouter)
local QuestFactProvider = require(script.Parent.Quest.QuestFactProvider)
local QuestPersistence = require(script.Parent.Quest.QuestPersistence)
local QuestProtocolServer = require(script.Parent.Quest.QuestProtocolServer)
local QuestSessionOutbox = require(script.Parent.Quest.QuestSessionOutbox)

local QuestService = {}

local OBSERVATION_LIMIT = 30
local OBSERVATION_WINDOW_SECONDS = 10
local CONTROL_INTENT_LIMIT = 12
local CONTROL_INTENT_WINDOW_SECONDS = 10
local PROGRESS_PUBLISH_INTERVAL_SECONDS = 0.2

local router
local persistence
local factProvider
local protocolServer
local observationRateByPlayer = setmetatable({}, { __mode = "k" })
local controlRateByPlayer = setmetatable({}, { __mode = "k" })
local buildingPurchasePendingByPlayer = setmetatable({}, { __mode = "k" })
local lastPublishAtByPlayer = setmetatable({}, { __mode = "k" })
local pendingPublishTokenByPlayer = setmetatable({}, { __mode = "k" })
local presentationMetrics = { ImmediatePublishes = 0, DeferredPublishes = 0, CoalescedUpdates = 0 }

local function timestamp()
	return os.time()
end

local function countUpgrade(player, upgradeId)
	local data = PlayerDataService.Get(player)
	local run = type(data) == "table" and data.Run
	local counts = type(run) == "table" and run.UpgradeCounts
	return math.clamp(math.floor(tonumber(type(counts) == "table" and counts[upgradeId]) or 0), 0, 1000000000)
end

local function cookieBalance(player)
	local data = PlayerDataService.Get(player)
	local run = type(data) == "table" and data.Run
	return math.max(0, tonumber(type(run) == "table" and run.Cookies) or 0)
end

local function allowRate(bucketByPlayer, player, limit, windowSeconds)
	local now = os.clock()
	local state = bucketByPlayer[player]
	if not state or now - state.StartedAt >= windowSeconds then
		state = { StartedAt = now, Count = 0 }
		bucketByPlayer[player] = state
	end
	if state.Count >= limit then return false end
	state.Count += 1
	return true
end

local function allowObservation(player)
	return allowRate(observationRateByPlayer, player, OBSERVATION_LIMIT, OBSERVATION_WINDOW_SECONDS)
end

local function allowControlIntent(player)
	return allowRate(controlRateByPlayer, player, CONTROL_INTENT_LIMIT, CONTROL_INTENT_WINDOW_SECONDS)
end

local function ensureProtocolSession(player)
	local outbox = protocolServer and protocolServer.Outbox
	if not outbox then return false end
	if not outbox:GetSession(player) then
		protocolServer:BeginSession(player)
	end
	return true
end

local function publishCurrent(player, context, transitions)
	if not ensureProtocolSession(player) then return false end
	local facts = factProvider:Build(player, context, { Kind = "FullReconcile", Timestamp = timestamp() })
	local envelope, problem = protocolServer:Publish(player, context.State, facts, transitions or {})
	if envelope == nil and problem ~= "waiting for Ready" then
		warn("Quest protocol publish failed: " .. tostring(problem))
	end
	if envelope ~= nil then lastPublishAtByPlayer[player] = os.clock() end
	return envelope ~= nil or problem == "waiting for Ready"
end

local function publishImmediate(player, context, transitions)
	pendingPublishTokenByPlayer[player] = nil
	presentationMetrics.ImmediatePublishes += 1
	return publishCurrent(player, context, transitions)
end

local function scheduleProgressPublish(player)
	if pendingPublishTokenByPlayer[player] then
		presentationMetrics.CoalescedUpdates += 1
		return true
	end
	local token = {}
	pendingPublishTokenByPlayer[player] = token
	local elapsed = os.clock() - (lastPublishAtByPlayer[player] or 0)
	task.delay(math.max(0, PROGRESS_PUBLISH_INTERVAL_SECONDS - elapsed), function()
		if pendingPublishTokenByPlayer[player] ~= token then return end
		pendingPublishTokenByPlayer[player] = nil
		if player.Parent ~= Players then return end
		local latest = persistence:Load(player, "Presentation")
		if latest then
			presentationMetrics.DeferredPublishes += 1
			publishCurrent(player, latest, {})
		end
	end)
	return true
end

local function executeReward(player, _, effect)
	local rewardKind = RewardRegistry.Get(effect.RewardKind)
	if not rewardKind then return false end
	return rewardKind.Execute({
		AddGems = function(target, amount)
			return GemService.AddGems(target, amount, "quest-v2:" .. effect.ReceiptId, {
				Kind = "Ui",
				Key = "QuestReward",
				SuppressPresentation = true,
			}) ~= nil
		end,
		GrantGooSkin = function(target, skinId)
			if GooSkinService.IsOwned(target, skinId) then return true end
			if GooSkinService.GrantSkin(target, skinId) then return true end
			return GooSkinService.IsOwned(target, skinId)
		end,
	}, player, effect.Params, effect) == true
end

local function executeAnalytics(player, effect, elapsed)
	local definition = Manifest.DefinitionsById[effect.DefinitionId]
	local arcId = definition and definition.ArcId or "unknown"
	if effect.AnalyticsKind == "StepCompleted" then
		QuestAnalyticsService.RecordStepCompleted(player, arcId, effect.DefinitionId, effect.StepId, elapsed)
	elseif effect.AnalyticsKind == "QuestCompleted" then
		QuestAnalyticsService.RecordQuestCompleted(player, arcId, effect.DefinitionId)
	elseif effect.AnalyticsKind == "RewardGranted" then
		QuestAnalyticsService.RecordRewardGranted(
			player,
			arcId,
			effect.DefinitionId,
			tonumber(effect.Params and effect.Params.Amount) or 0
		)
	end
end

function QuestService.NotifyDomain(player, eventKind, payload, causeTimestamp)
	if not router then return false, "quest router is not initialized" end
	return router:NotifyDomain(player, eventKind, payload, causeTimestamp or timestamp())
end

function QuestService.SetupPlayer(player)
	if not router or not ensureProtocolSession(player) then return false end
	return router:SetupPlayer(player, timestamp())
end

function QuestService.ResetForDevelopment(player)
	if not router or not ensureProtocolSession(player) then return false end
	buildingPurchasePendingByPlayer[player] = nil
	observationRateByPlayer[player] = nil
	controlRateByPlayer[player] = nil
	lastPublishAtByPlayer[player] = nil
	pendingPublishTokenByPlayer[player] = nil
	-- A development reset starts a genuinely new logical timeline. Reusing the
	-- old session would make client transition dedupe and monotonic visual
	-- high-water state survive against freshly reset authoritative state.
	router:ClearPlayer(player)
	protocolServer:BeginSession(player)
	protocolServer:Ready(player, QuestProtocol.ReadyRequest())
	return router:ResetPlayer(player, timestamp())
end

function QuestService.ReconcileForDevelopment(player, causeTimestamp)
	return router and router:DeveloperCheck(player, causeTimestamp or timestamp()) or false
end

-- Read-only view of committed arc completion for other services (Orbit Radio's
-- encounter eligibility). Canonical Data only: never the client envelope, and never
-- a reason to publish or mutate quest state.
function QuestService.IsArcCompleted(player, arcId)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent or nil
	local state = type(persistent) == "table" and persistent.UniversalQuestState or nil
	local completed = type(state) == "table" and state.CompletedArcIds or nil
	return type(completed) == "table" and type(arcId) == "string" and completed[arcId] == true
end

function QuestService.GetPerformanceMeasurements()
	return {
		Router = router and router:GetMeasurements() or {},
		Protocol = protocolServer and protocolServer:GetMetrics() or {},
		Presentation = {
			ImmediatePublishes = presentationMetrics.ImmediatePublishes,
			DeferredPublishes = presentationMetrics.DeferredPublishes,
			CoalescedUpdates = presentationMetrics.CoalescedUpdates,
		},
	}
end

function QuestService.OnStoryStepChanged(player, storyStep)
	return QuestService.NotifyDomain(player, "StoryAdvanced", { StoryStep = storyStep })
end

function QuestService.OnIntroCompleted(player)
	return QuestService.NotifyDomain(player, "IntroCompleted", {})
end

function QuestService.OnHealingCelebrationStarted(player)
	return QuestService.NotifyDomain(player, "HealingProgressChanged", {
		AcceptedClicks = StoryConfig.HEALING_CLICKS,
		SequenceCompleted = true,
	})
end

function QuestService.OnManualCookieClick(player, acceptedHealingClicks)
	if type(acceptedHealingClicks) ~= "number" then return false end
	return QuestService.NotifyDomain(player, "HealingProgressChanged", {
		AcceptedClicks = math.clamp(math.floor(acceptedHealingClicks), 0, 1000000),
		SequenceCompleted = false,
	})
end

function QuestService.BeginBuildingPurchase(player, upgradeId)
	if type(upgradeId) ~= "string" then return false end
	buildingPurchasePendingByPlayer[player] = upgradeId
	return true
end

function QuestService.CancelBuildingPurchase(player, upgradeId)
	if buildingPurchasePendingByPlayer[player] ~= upgradeId then return false end
	buildingPurchasePendingByPlayer[player] = nil
	return QuestService.NotifyDomain(player, "CookieBalanceChanged", {
		Balance = cookieBalance(player),
		Source = "PurchaseCancelled",
		CommitState = "Committed",
	})
end

function QuestService.OnBuildingPlaced(player, upgradeId, floorId)
	if type(upgradeId) ~= "string" then return false end
	buildingPurchasePendingByPlayer[player] = nil
	return QuestService.NotifyDomain(player, "BuildingPlaced", {
		UpgradeId = upgradeId,
		Count = countUpgrade(player, upgradeId),
		FloorId = floorId,
	})
end

function QuestService.OnBuildingSold(player, upgradeId, soldCount)
	if type(upgradeId) ~= "string" then return false end
	return QuestService.NotifyDomain(player, "BuildingSold", {
		UpgradeId = upgradeId,
		Count = countUpgrade(player, upgradeId),
		SoldCount = math.max(1, math.floor(tonumber(soldCount) or 1)),
	})
end

function QuestService.OnCookieBalanceChanged(player, source)
	local pending = source == "PendingPurchase" or source == "Refund" and buildingPurchasePendingByPlayer[player] ~= nil
	return QuestService.NotifyDomain(player, "CookieBalanceChanged", {
		Balance = cookieBalance(player),
		Source = type(source) == "string" and source or "Other",
		CommitState = pending and (source == "Refund" and "RefundPending" or "PendingPurchase") or "Committed",
	})
end

function QuestService.OnUpgradePurchased(player, upgradeId)
	if type(upgradeId) ~= "string" then return false end
	return QuestService.NotifyDomain(player, "UpgradePurchased", {
		UpgradeId = upgradeId,
		Count = countUpgrade(player, upgradeId),
	})
end

local function onObservation(player, observation)
	if not allowObservation(player) or not UiObservations.IsAllowed(observation) then return end
	QuestService.NotifyDomain(player, "UiObservation", { Observation = observation })
end

local function onPreference(player, hidden)
	if type(hidden) ~= "boolean" or not allowControlIntent(player) then return end
	local context = persistence:Load(player, "Preference")
	if not context then return end
	context.State.HideCompleted = hidden
	persistence:Save(player, context)
	publishImmediate(player, context, {})
end

local function onSelection(player, instanceId)
	if type(instanceId) ~= "string" or #instanceId == 0 or #instanceId > 160 or not allowControlIntent(player) then return end
	local context = persistence:Load(player, "Selection")
	if not context then return end
	local selected, changed = QuestEngine.select(Manifest, context.State, instanceId)
	if not changed then return end
	context.State = selected
	persistence:Save(player, context)
	publishImmediate(player, context, {})
end

function QuestService.Init()
	persistence = QuestPersistence.new({
		GetData = PlayerDataService.Get,
		Schema = QuestSchema,
		Content = Manifest,
	})
	factProvider = QuestFactProvider.new({
		Content = Manifest,
		UpgradeConfig = UpgradeConfig,
		BoostShopConfig = BoostShopConfig,
		GetUpgradeCost = function(config, count)
			return UpgradePricing.GetCost(config, count) or tonumber(config.BaseCost)
		end,
	})
	local outbox = QuestSessionOutbox.new({
		Protocol = QuestProtocol,
		NewSessionId = function(player)
			return ("%d:%s"):format(player.UserId, HttpService:GenerateGUID(false))
		end,
		SendEnvelope = function(player, envelope)
			Net.fireClient(Net.Names.QuestEnvelopeV2, player, envelope)
		end,
		OnDiagnostic = function(player, diagnostic)
			warn(("Quest protocol diagnostic for %s: %s"):format(player.Name, tostring(diagnostic.Kind)))
		end,
	})
	protocolServer = QuestProtocolServer.new({ Protocol = QuestProtocol, Outbox = outbox, Content = Manifest })
	local effectRunner = QuestEffectRunner.new({
		Engine = QuestEngine,
		Enabled = true,
		ExecuteReward = executeReward,
		ExecuteAnalytics = executeAnalytics,
	})
	router = QuestEventRouter.new({
		Content = Manifest,
		DomainEvents = DomainEvents,
		Engine = QuestEngine,
		EffectRunner = effectRunner,
		LoadContext = function(player, reason) return persistence:Load(player, reason) end,
		SaveContext = function(player, context, transitions, reason)
			if not persistence:Save(player, context) then return false end
			if reason == "Incremental" and #transitions == 0 then
				return scheduleProgressPublish(player)
			end
			return publishImmediate(player, context, transitions)
		end,
		BuildFacts = function(player, context, cause) return factProvider:Build(player, context, cause) end,
	})

	Net.event(Net.Names.QuestEnvelopeV2)
	Net.on(Net.Names.QuestReadyV2, function(player, request)
		ensureProtocolSession(player)
		protocolServer:Ready(player, request)
	end)
	Net.on(Net.Names.QuestObservationV2, onObservation)
	Net.on(Net.Names.QuestPreferenceV2, onPreference)
	Net.on(Net.Names.QuestSelectV2, onSelection)

	local function beginPlayer(player)
		if player.Parent == Players then ensureProtocolSession(player) end
	end
	Players.PlayerAdded:Connect(beginPlayer)
	for _, player in ipairs(Players:GetPlayers()) do beginPlayer(player) end
	Players.PlayerRemoving:Connect(function(player)
		observationRateByPlayer[player] = nil
		controlRateByPlayer[player] = nil
		buildingPurchasePendingByPlayer[player] = nil
		lastPublishAtByPlayer[player] = nil
		pendingPublishTokenByPlayer[player] = nil
		if router then router:ClearPlayer(player) end
		if protocolServer then protocolServer:ClearPlayer(player) end
	end)
	print("QuestService initialized (protocol v2)")
end

return QuestService
