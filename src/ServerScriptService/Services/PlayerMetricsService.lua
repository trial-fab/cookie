local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local PlayerMetricConfig = require(ReplicatedStorage.Shared.PlayerMetricConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local FloorConfig = require(ReplicatedStorage.Shared.FloorConfig)

local PlayerMetricsService = {}

PlayerMetricsService.CookieSources = PlayerMetricConfig.CookieSources

local REPLICATION_INTERVAL_SECONDS = 1
local dirtyByPlayer = setmetatable({}, { __mode = "k" })
local setupReadyByPlayer = setmetatable({}, { __mode = "k" })
local getPlayerData
local initialized = false

local function normalizeMetric(value)
	return math.max(0, tonumber(value) or 0)
end

local function getPersistent(player, requireSetup)
	if requireSetup and setupReadyByPlayer[player] ~= true then
		return nil
	end
	if type(getPlayerData) ~= "function" then
		return nil
	end

	local data = getPlayerData(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function readMetric(persistent, attribute)
	return normalizeMetric(persistent[attribute])
end

local function markDirty(player, attribute)
	local dirty = dirtyByPlayer[player]
	if not dirty then
		dirty = {}
		dirtyByPlayer[player] = dirty
	end
	dirty[attribute] = true
end

-- Canonical Data always changes before its delayed Player-attribute projection is queued.
local function setMetric(player, persistent, attribute, value)
	value = normalizeMetric(value)
	persistent[attribute] = value
	markDirty(player, attribute)
	return value
end

local function addMetric(player, persistent, attribute, amount)
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return readMetric(persistent, attribute)
	end

	return setMetric(player, persistent, attribute, readMetric(persistent, attribute) + amount)
end

-- PlayerDataService supplies its active-profile accessor after both modules have loaded. This
-- avoids a require cycle and, importantly, does not retain a second reference-based authority.
function PlayerMetricsService.ConfigureDataAccess(accessor)
	assert(type(accessor) == "function", "PlayerMetricsService data accessor must be a function")
	getPlayerData = accessor
end

-- Yield-free. Only fields explicitly queued by a canonical metric mutation are published;
-- unqueued mismatches remain visible to PlayerDataProjectionAudit.
function PlayerMetricsService.FlushProjections(player)
	local dirty = dirtyByPlayer[player]
	if not dirty then
		return true
	end

	local persistent = getPersistent(player, true)
	if not persistent then
		dirtyByPlayer[player] = nil
		return false
	end

	dirtyByPlayer[player] = nil
	for attribute in pairs(dirty) do
		player:SetAttribute(attribute, readMetric(persistent, attribute))
	end
	return true
end

function PlayerMetricsService.ForgetPlayer(player)
	setupReadyByPlayer[player] = nil
	dirtyByPlayer[player] = nil
end

function PlayerMetricsService.SetupPlayer(player)
	PlayerMetricsService.ForgetPlayer(player)
	if player.Parent ~= Players then
		return false
	end

	local persistent = getPersistent(player, false)
	local data = type(getPlayerData) == "function" and getPlayerData(player) or nil
	local runData = type(data) == "table" and data.Run
	if not persistent or type(runData) ~= "table" then
		return false
	end

	-- Normalize canonical loaded/fresh values first, then publish the complete scalar set once.
	for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
		persistent[attribute] = normalizeMetric(persistent[attribute])
		player:SetAttribute(attribute, persistent[attribute])
	end

	-- Migration-safe lower bounds for saves created before lifetime metrics. A player cannot
	-- have earned fewer cookies/GC or placed fewer buildings than currently represented by the
	-- existing canonical economy state; unattributable legacy cookies enter the Other bucket.
	-- Corrections use the normal dirty queue so their final projections exercise the same path
	-- as live mutations.
	local currentCookies = math.max(0, tonumber(runData.Cookies) or 0)
	local lifetimeCookies = readMetric(persistent, Attrs.LifetimeCookiesEarned)
	if currentCookies > lifetimeCookies then
		local legacyCookies = currentCookies - lifetimeCookies
		setMetric(player, persistent, Attrs.LifetimeCookiesEarned, currentCookies)
		addMetric(player, persistent, Attrs.OtherCookiesEarned, legacyCookies)
	end

	local currentGolden = math.max(0, tonumber(persistent.GoldenCookies) or 0)
	if currentGolden > readMetric(persistent, Attrs.GoldenCookiesEarned) then
		setMetric(player, persistent, Attrs.GoldenCookiesEarned, currentGolden)
	end

	local currentStreak = tonumber(persistent.LoginStreak) or 0
	if currentStreak > readMetric(persistent, Attrs.BestLoginStreak) then
		setMetric(player, persistent, Attrs.BestLoginStreak, currentStreak)
	end

	local currentBuildings = 0
	local counts = type(runData.UpgradeCounts) == "table" and runData.UpgradeCounts or {}
	for upgradeId, count in pairs(counts) do
		local config = UpgradeConfig[upgradeId]
		if config and config.TemplateKind == "Building" then
			currentBuildings += math.max(0, tonumber(count) or 0)
		end
	end
	if currentBuildings > readMetric(persistent, Attrs.BuildingsPlaced) then
		setMetric(player, persistent, Attrs.BuildingsPlaced, currentBuildings)
	end

	local currentFloors = math.clamp(
		math.floor(tonumber(counts[FloorConfig.ExpansionUpgradeId]) or 0),
		0,
		FloorConfig.UnlockableFloorCount
	)
	if currentFloors > readMetric(persistent, Attrs.LifetimeFloorUnlocks) then
		setMetric(player, persistent, Attrs.LifetimeFloorUnlocks, currentFloors)
	end
	if currentFloors > readMetric(persistent, Attrs.HighestFloorUnlocked) then
		setMetric(player, persistent, Attrs.HighestFloorUnlocked, currentFloors)
	end

	setupReadyByPlayer[player] = true
	PlayerMetricsService.FlushProjections(player)
	return true
end

-- Called after CookieService applies and clamps a balance delta, so metrics record what the
-- player actually gained/lost rather than the requested amount.
function PlayerMetricsService.RecordCookieDelta(player, delta, source)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	delta = tonumber(delta) or 0
	source = source or PlayerMetricConfig.CookieSources.Other

	if delta > 0 then
		local incomeAttribute = PlayerMetricConfig.IncomeAttributeBySource[source]
		if incomeAttribute then
			addMetric(player, persistent, Attrs.LifetimeCookiesEarned, delta)
			addMetric(player, persistent, incomeAttribute, delta)
		end
	elseif delta < 0 then
		local lost = -delta
		if source == PlayerMetricConfig.CookieSources.Purchase or source == PlayerMetricConfig.CookieSources.Shield then
			addMetric(player, persistent, Attrs.CookiesSpent, lost)
		elseif source == PlayerMetricConfig.CookieSources.TheftLoss then
			addMetric(player, persistent, Attrs.CookiesLostToTheft, lost)
		end
	end
	return true
end

function PlayerMetricsService.RecordManualClick(player)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.ManualClicks, 1) ~= nil or false
end

function PlayerMetricsService.RecordBuildingPlaced(player)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.BuildingsPlaced, 1) ~= nil or false
end

function PlayerMetricsService.RecordAutoclickerUnlocked(player)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.LifetimeAutoclickerUnlocks, 1) ~= nil or false
end

function PlayerMetricsService.RecordFloorUnlocked(player, floorOrder)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	floorOrder = math.max(0, math.floor(tonumber(floorOrder) or 0))
	if floorOrder <= 0 then
		return false
	end
	addMetric(player, persistent, Attrs.LifetimeFloorUnlocks, 1)
	if floorOrder > readMetric(persistent, Attrs.HighestFloorUnlocked) then
		setMetric(player, persistent, Attrs.HighestFloorUnlocked, floorOrder)
	end
	return true
end

function PlayerMetricsService.RecordBonusFloorBuildingPlaced(player)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.BonusFloorBuildingsPlaced, 1) ~= nil or false
end

function PlayerMetricsService.RecordCookiesSpent(player, amount)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.CookiesSpent, amount) ~= nil or false
end

function PlayerMetricsService.RecordCps(player, cps)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	cps = math.max(0, tonumber(cps) or 0)
	if cps > readMetric(persistent, Attrs.HighestCps) then
		setMetric(player, persistent, Attrs.HighestCps, cps)
	end
	return true
end

function PlayerMetricsService.RecordGoldenCookiesEarned(player, amount, source)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	amount = tonumber(amount) or 0
	if amount <= 0 or source == "refund" or source == "test" then
		return false
	end
	addMetric(player, persistent, Attrs.GoldenCookiesEarned, amount)
	return true
end

function PlayerMetricsService.RecordGoldenCookiesSpent(player, amount)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.GoldenCookiesSpent, amount) ~= nil or false
end

function PlayerMetricsService.RecordGemsEarned(player, amount, source)
	local persistent = getPersistent(player, true)
	if not persistent or source == "test" then
		return false
	end
	return addMetric(player, persistent, Attrs.GemsEarned, amount) ~= nil
end

function PlayerMetricsService.RecordGemsSpent(player, amount)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.GemsSpent, amount) ~= nil or false
end

function PlayerMetricsService.RecordWheelSpin(player)
	local persistent = getPersistent(player, true)
	return persistent and addMetric(player, persistent, Attrs.WheelSpins, 1) ~= nil or false
end

function PlayerMetricsService.RecordLoginStreak(player, streak)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	streak = math.max(0, math.floor(tonumber(streak) or 0))
	if streak > readMetric(persistent, Attrs.BestLoginStreak) then
		setMetric(player, persistent, Attrs.BestLoginStreak, streak)
	end
	return true
end

function PlayerMetricsService.RecordSessionDuration(player, durationSeconds)
	local persistent = getPersistent(player, true)
	if not persistent then
		return false
	end

	durationSeconds = math.max(0, math.floor(tonumber(durationSeconds) or 0))
	if durationSeconds > readMetric(persistent, Attrs.LongestSessionSeconds) then
		setMetric(player, persistent, Attrs.LongestSessionSeconds, durationSeconds)
	end
	return true
end

function PlayerMetricsService.Init()
	if initialized then
		return
	end
	initialized = true

	Players.PlayerRemoving:Connect(function(player)
		PlayerMetricsService.FlushProjections(player)
		PlayerMetricsService.ForgetPlayer(player)
	end)

	task.spawn(function()
		while true do
			task.wait(REPLICATION_INTERVAL_SECONDS)
			for player in pairs(dirtyByPlayer) do
				PlayerMetricsService.FlushProjections(player)
			end
		end
	end)
end

return PlayerMetricsService
