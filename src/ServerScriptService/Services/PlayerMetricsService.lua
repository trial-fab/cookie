local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local PlayerMetricConfig = require(ReplicatedStorage.Shared.PlayerMetricConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local FloorConfig = require(ReplicatedStorage.Shared.FloorConfig)

local PlayerMetricsService = {}

PlayerMetricsService.CookieSources = PlayerMetricConfig.CookieSources

local REPLICATION_INTERVAL_SECONDS = 1
local valuesByPlayer = {}
local dirtyByPlayer = {}
local initialized = false

local function readMetric(player, attribute)
	local values = valuesByPlayer[player]
	if values and typeof(values[attribute]) == "number" then
		return math.max(0, values[attribute])
	end

	local value = player:GetAttribute(attribute)
	return typeof(value) == "number" and math.max(0, value) or 0
end

local function setMetric(player, attribute, value, replicateNow)
	value = math.max(0, tonumber(value) or 0)
	local values = valuesByPlayer[player]
	if not values then
		values = {}
		valuesByPlayer[player] = values
	end
	values[attribute] = value

	if replicateNow then
		player:SetAttribute(attribute, value)
	else
		local dirty = dirtyByPlayer[player]
		if not dirty then
			dirty = {}
			dirtyByPlayer[player] = dirty
		end
		dirty[attribute] = true
	end
	return value
end

local function addMetric(player, attribute, amount)
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return readMetric(player, attribute)
	end

	local total = readMetric(player, attribute) + amount
	return setMetric(player, attribute, total, false)
end

local function flushPlayer(player)
	local dirty = dirtyByPlayer[player]
	local values = valuesByPlayer[player]
	if not dirty or not values or not player.Parent then
		return
	end

	dirtyByPlayer[player] = nil
	for attribute in pairs(dirty) do
		player:SetAttribute(attribute, values[attribute] or 0)
	end
end

function PlayerMetricsService.SetupPlayer(player, persistentData, runData)
	persistentData = type(persistentData) == "table" and persistentData or {}
	runData = type(runData) == "table" and runData or {}
	valuesByPlayer[player] = {}
	dirtyByPlayer[player] = nil
	for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
		setMetric(player, attribute, persistentData[attribute], true)
	end

	-- Migration-safe lower bounds for saves created before lifetime metrics. A
	-- player cannot have earned fewer cookies/GC or placed fewer buildings than
	-- they currently own; unattributable legacy cookies enter the Other bucket.
	local currentCookies = math.max(0, tonumber(runData.Cookies) or 0)
	local lifetimeCookies = readMetric(player, Attrs.LifetimeCookiesEarned)
	if currentCookies > lifetimeCookies then
		local legacyCookies = currentCookies - lifetimeCookies
		setMetric(player, Attrs.LifetimeCookiesEarned, currentCookies, true)
		addMetric(player, Attrs.OtherCookiesEarned, legacyCookies)
	end

	local currentGolden = math.max(0, tonumber(persistentData.GoldenCookies) or 0)
	setMetric(
		player,
		Attrs.GoldenCookiesEarned,
		math.max(readMetric(player, Attrs.GoldenCookiesEarned), currentGolden),
		true
	)
	setMetric(
		player,
		Attrs.BestLoginStreak,
		math.max(readMetric(player, Attrs.BestLoginStreak), tonumber(persistentData.LoginStreak) or 0),
		true
	)

	local currentBuildings = 0
	local counts = type(runData.UpgradeCounts) == "table" and runData.UpgradeCounts or {}
	for upgradeId, count in pairs(counts) do
		local config = UpgradeConfig[upgradeId]
		if config and config.TemplateKind == "Building" then
			currentBuildings += math.max(0, tonumber(count) or 0)
		end
	end
	setMetric(
		player,
		Attrs.BuildingsPlaced,
		math.max(readMetric(player, Attrs.BuildingsPlaced), currentBuildings),
		true
	)
	local currentFloors = math.clamp(
		math.floor(tonumber(counts[FloorConfig.ExpansionUpgradeId]) or 0),
		0,
		FloorConfig.UnlockableFloorCount
	)
	setMetric(
		player,
		Attrs.LifetimeFloorUnlocks,
		math.max(readMetric(player, Attrs.LifetimeFloorUnlocks), currentFloors),
		true
	)
	setMetric(
		player,
		Attrs.HighestFloorUnlocked,
		math.max(readMetric(player, Attrs.HighestFloorUnlocked), currentFloors),
		true
	)
	flushPlayer(player)
end

function PlayerMetricsService.WritePersistentData(player, persistentData)
	for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
		persistentData[attribute] = readMetric(player, attribute)
	end
end

-- Called after CookieService applies and clamps a balance delta, so metrics
-- record what the player actually gained/lost rather than the requested amount.
function PlayerMetricsService.RecordCookieDelta(player, delta, source)
	delta = tonumber(delta) or 0
	source = source or PlayerMetricConfig.CookieSources.Other

	if delta > 0 then
		local incomeAttribute = PlayerMetricConfig.IncomeAttributeBySource[source]
		if incomeAttribute then
			addMetric(player, Attrs.LifetimeCookiesEarned, delta)
			addMetric(player, incomeAttribute, delta)
		end
	elseif delta < 0 then
		local lost = -delta
		if source == PlayerMetricConfig.CookieSources.Purchase or source == PlayerMetricConfig.CookieSources.Shield then
			PlayerMetricsService.RecordCookiesSpent(player, lost)
		elseif source == PlayerMetricConfig.CookieSources.TheftLoss then
			addMetric(player, Attrs.CookiesLostToTheft, lost)
		end
	end
end

function PlayerMetricsService.RecordManualClick(player)
	addMetric(player, Attrs.ManualClicks, 1)
end

function PlayerMetricsService.RecordBuildingPlaced(player)
	addMetric(player, Attrs.BuildingsPlaced, 1)
end

function PlayerMetricsService.RecordFloorUnlocked(player, floorOrder)
	floorOrder = math.max(0, math.floor(tonumber(floorOrder) or 0))
	if floorOrder <= 0 then
		return
	end
	addMetric(player, Attrs.LifetimeFloorUnlocks, 1)
	if floorOrder > readMetric(player, Attrs.HighestFloorUnlocked) then
		setMetric(player, Attrs.HighestFloorUnlocked, floorOrder, false)
	end
end

function PlayerMetricsService.RecordBonusFloorBuildingPlaced(player)
	addMetric(player, Attrs.BonusFloorBuildingsPlaced, 1)
end

function PlayerMetricsService.RecordCookiesSpent(player, amount)
	addMetric(player, Attrs.CookiesSpent, amount)
end

function PlayerMetricsService.RecordCps(player, cps)
	cps = math.max(0, tonumber(cps) or 0)
	if cps > readMetric(player, Attrs.HighestCps) then
		setMetric(player, Attrs.HighestCps, cps, false)
	end
end

function PlayerMetricsService.RecordGoldenCookiesEarned(player, amount, source)
	amount = tonumber(amount) or 0
	if amount <= 0 or source == "refund" or source == "test" then
		return
	end
	addMetric(player, Attrs.GoldenCookiesEarned, amount)
end

function PlayerMetricsService.RecordGoldenCookiesSpent(player, amount)
	addMetric(player, Attrs.GoldenCookiesSpent, amount)
end

function PlayerMetricsService.RecordWheelSpin(player)
	addMetric(player, Attrs.WheelSpins, 1)
end

function PlayerMetricsService.RecordLoginStreak(player, streak)
	streak = math.max(0, math.floor(tonumber(streak) or 0))
	if streak > readMetric(player, Attrs.BestLoginStreak) then
		setMetric(player, Attrs.BestLoginStreak, streak, false)
	end
end

function PlayerMetricsService.RecordSessionDuration(player, durationSeconds)
	durationSeconds = math.max(0, math.floor(tonumber(durationSeconds) or 0))
	if durationSeconds > readMetric(player, Attrs.LongestSessionSeconds) then
		setMetric(player, Attrs.LongestSessionSeconds, durationSeconds, false)
	end
end

function PlayerMetricsService.Init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerRemoving:Connect(function(player)
		flushPlayer(player)
		-- PlayerDataService's forced leave-save may yield. Keep the authoritative
		-- cache alive until that handler has had ample time to serialize it.
		task.delay(30, function()
			valuesByPlayer[player] = nil
			dirtyByPlayer[player] = nil
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(REPLICATION_INTERVAL_SECONDS)
			for player in pairs(dirtyByPlayer) do
				flushPlayer(player)
			end
		end
	end)
end

return PlayerMetricsService
