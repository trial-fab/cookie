local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ProfileStore = require(script.Parent.Parent.Vendor.ProfileStore)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local FloorConfig = require(ReplicatedStorage.Shared.FloorConfig)
local FloorGeometry = require(ReplicatedStorage.Shared.FloorGeometry)
local PlayerMetricConfig = require(ReplicatedStorage.Shared.PlayerMetricConfig)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)
local PlayerDataProjectionAudit = require(script.Parent.PlayerDataProjectionAudit)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local PlayerDataService = {}

local PRODUCTION_STORE_NAME = "ClickGamePlayerData_v2"
local STUDIO_STORE_NAME = "ClickGamePlayerData_v2_Studio"
local KEY_PREFIX = "player_"
local AUTOSAVE_SECONDS = 60
local LOAD_TIMEOUT_SECONDS = 120
local FORCE_SAVE_WAIT_SECONDS = 10
local DEFAULT_DIMENSION = FloorConfig.DimensionId
local CURRENT_SCHEMA_VERSION = 1
local SAVE_GENERATION_METADATA_KEY = "ClickGameSaveGeneration"

local DEFAULT_RUN_DATA = {
	Cookies = 0,
	CanBeStolenFrom = false,
	ShieldTime = 600,
	UpgradeCounts = {},
	PlacementSchemaVersion = FloorConfig.PlacementSchemaVersion,
	Placements = {
		Earth = {
			Ground = {},
		},
	},
}

local DEFAULT_PERSISTENT_DATA = {
	RealPlayTime = 0,
	Xp = 0,
	GoldenCookies = 0,
	OwnedSkins = {},
	EquippedSkins = {},
	OwnedGooSkins = {},
	SelectedGooSkin = "Goo::Default",
	LoginStreak = 0,
	LastLoginDay = 0,
	Achievements = {},
	LastSeenTimestamp = 0,
	UnlockedBuildings = {},
	-- Only explicit player choices are stored. Missing keys continue to use device-aware client
	-- defaults, so first joining on mobile does not permanently change the desktop experience.
	Settings = {},
	-- Once a player ticks "don't show again" on the Build View nudge we never prompt
	-- them again, across sessions. Defaults false so genuinely new players get nudged.
	BuildViewNudgeDisabled = false,
	IntroSeen = false,
	StoryChapter = "GooArrival",
	StoryStep = "Meteor",
	StoryHealingClicks = 0,
	MixerUnlocked = false,
	CompletedStoryChapters = {},
}

for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
	DEFAULT_PERSISTENT_DATA[attribute] = 0
end

local PROFILE_TEMPLATE = {
	SchemaVersion = CURRENT_SCHEMA_VERSION,
	Run = DEFAULT_RUN_DATA,
	Persistent = DEFAULT_PERSISTENT_DATA,
}

-- MIGRATIONS[n] upgrades a schema-n profile to schema n+1. Additive fields need no
-- migration because Reconcile fills them after versioned migrations have succeeded.
local MIGRATIONS = {}

local playerStore
local profilesByPlayer = {}
local expectedSessionEndByPlayer = {}
local confirmedSaveGenerationByProfile = {}
local domain7ReadyByPlayer = setmetatable({}, { __mode = "k" })
local placementSerializationReadyByPlayer = setmetatable({}, { __mode = "k" })

local function copyDictionary(source)
	local result = {}
	for key, value in pairs(source) do
		if type(value) == "table" then
			result[key] = copyDictionary(value)
		else
			result[key] = value
		end
	end
	return result
end

local function normalizePlacements(placements, schemaVersion)
	local normalized = copyDictionary(DEFAULT_RUN_DATA.Placements)
	if tonumber(schemaVersion) ~= FloorConfig.PlacementSchemaVersion or type(placements) ~= "table" then
		return normalized
	end

	for dimensionName, dimensionPlacements in pairs(placements) do
		if type(dimensionName) == "string" and type(dimensionPlacements) == "table" then
			local normalizedDimension = {}
			for _, floor in ipairs(FloorConfig.GetDefinitions()) do
				local floorPlacements = dimensionPlacements[floor.Id]
				if type(floorPlacements) == "table" then
					normalizedDimension[floor.Id] = copyDictionary(floorPlacements)
				end
			end
			normalizedDimension[FloorConfig.GroundFloorId] = normalizedDimension[FloorConfig.GroundFloorId] or {}
			normalized[dimensionName] = normalizedDimension
		end
	end

	return normalized
end

local function normalizeIntValue(value)
	local number = tonumber(value) or 0
	if number ~= number or number == math.huge or number == -math.huge then
		return 0
	end
	return math.round(number)
end

local function normalizeUpgradeCounts(data, preserveUnknown)
	local run = type(data) == "table" and data.Run
	if type(run) ~= "table" then
		return false
	end

	local source = type(run.UpgradeCounts) == "table" and run.UpgradeCounts or {}
	local normalized = {}
	if preserveUnknown then
		for upgradeId, value in pairs(source) do
			normalized[tostring(upgradeId)] = normalizeIntValue(value)
		end
	end

	for upgradeId, config in pairs(UpgradeConfig) do
		local sourceValue = source[upgradeId]
		local value
		if sourceValue == nil then
			value = normalizeIntValue(config.InitialCount or 0)
		elseif config.Levels then
			-- Preserve the legacy order: configured levels were numerically clamped first,
			-- then coerced by their IntValue projection (including +infinity -> max level).
			value = normalizeIntValue(math.clamp(tonumber(sourceValue) or 0, 0, #config.Levels))
		else
			value = normalizeIntValue(sourceValue)
		end
		normalized[upgradeId] = value
	end
	run.UpgradeCounts = normalized
	return true
end

local function getProjectionValue(player, parentName, valueName, className)
	local parent = parentName and player:FindFirstChild(parentName) or player
	local value = parent and parent:FindFirstChild(valueName)
	return value and value:IsA(className) and value or nil
end

local function reconcileUpgradeCountProjection(player, counts)
	local container = player:FindFirstChild("UpgradeCountData")
	if not container then
		return false
	end

	local remaining = {}
	for upgradeId in pairs(counts) do
		remaining[upgradeId] = true
	end
	for _, child in ipairs(container:GetChildren()) do
		local expected = counts[child.Name]
		if expected == nil or not child:IsA("IntValue") or remaining[child.Name] ~= true then
			child:Destroy()
		else
			child.Value = expected
			remaining[child.Name] = nil
		end
	end
	for upgradeId in pairs(remaining) do
		local value = Instance.new("IntValue")
		value.Name = upgradeId
		value.Value = counts[upgradeId]
		value.Parent = container
	end
	return true
end

local function getDomain7Projections(player)
	local cookies = getProjectionValue(player, "leaderstats", "Cookies", "NumberValue")
	local realPlayTime = getProjectionValue(player, nil, "RealPlayTime", "IntValue")
	local canBeStolenFrom = getProjectionValue(player, nil, "CanBeStolenFrom", "BoolValue")
	local shieldTime = getProjectionValue(player, nil, "ShieldTime", "IntValue")
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if
		not cookies
		or not realPlayTime
		or not canBeStolenFrom
		or not shieldTime
		or not upgradeCountData
		or not upgradeCountData:IsA("Configuration")
	then
		return nil
	end
	return cookies, realPlayTime, canBeStolenFrom, shieldTime
end

local function projectDomain7(player, data)
	local run = type(data) == "table" and data.Run
	local persistent = type(data) == "table" and data.Persistent
	if type(run) ~= "table" or type(persistent) ~= "table" then
		return false
	end

	local cookies, realPlayTime, canBeStolenFrom, shieldTime = getDomain7Projections(player)
	if not cookies then
		return false
	end

	-- Match the coercion formerly performed by NumberValue/IntValue before the save bridge
	-- copied projections back into Data. Do not invent a non-negative or MaxCount clamp: only
	-- leveled upgrades have the legacy [0, #Levels] load clamp.
	run.Cookies = tonumber(run.Cookies) or 0
	run.CanBeStolenFrom = run.CanBeStolenFrom == true
	run.ShieldTime = normalizeIntValue(run.ShieldTime == nil and DEFAULT_RUN_DATA.ShieldTime or run.ShieldTime)
	persistent.RealPlayTime = normalizeIntValue(persistent.RealPlayTime)
	normalizeUpgradeCounts(data, true)

	cookies.Value = run.Cookies
	realPlayTime.Value = persistent.RealPlayTime
	canBeStolenFrom.Value = run.CanBeStolenFrom
	shieldTime.Value = run.ShieldTime
	return reconcileUpgradeCountProjection(player, run.UpgradeCounts)
end

local function migrate(data)
	local version = tonumber(data.SchemaVersion) or 1
	if version % 1 ~= 0 or version < 1 then
		return false, "profile has an invalid schema version"
	end
	if version > CURRENT_SCHEMA_VERSION then
		return false,
			("profile is schema v%d but this server only knows v%d"):format(version, CURRENT_SCHEMA_VERSION)
	end

	while version < CURRENT_SCHEMA_VERSION do
		local step = MIGRATIONS[version]
		if not step then
			return false, ("no migration from schema v%d"):format(version)
		end
		local ok, problem = pcall(step, data)
		if not ok then
			return false, ("migration from schema v%d failed: %s"):format(version, tostring(problem))
		end
		version += 1
		data.SchemaVersion = version
	end
	data.SchemaVersion = version

	return true
end

local function getKey(player)
	return KEY_PREFIX .. player.UserId
end

local function canAccessDataStores()
	if not RunService:IsStudio() then
		return true
	end

	return pcall(function()
		DataStoreService:GetDataStore("__ClickGameProfileStoreProbe"):GetAsync("__probe")
	end)
end

local function configureStore()
	if playerStore then
		return
	end

	local storeName = RunService:IsStudio() and STUDIO_STORE_NAME or PRODUCTION_STORE_NAME
	local store = ProfileStore.New(storeName, PROFILE_TEMPLATE)
	if RunService:IsStudio() and not canAccessDataStores() then
		warn("PlayerDataService: Studio without DataStore access; using ProfileStore.Mock (nothing persists).")
		store = store.Mock
	end
	playerStore = store
end

local function getPlayerSheet(player)
	local cookieSheets = Workspace:FindFirstChild("CookieSheets")
	if not cookieSheets then
		return nil
	end

	for _, sheet in ipairs(cookieSheets:GetChildren()) do
		local owner = sheet:FindFirstChild("SheetOwner")
		if owner and owner:IsA("ObjectValue") and owner.Value == player then
			return sheet
		end
	end

	return nil
end

local function serializeBuildingPlacements(player)
	local sheet = getPlayerSheet(player)
	if not sheet then
		return nil
	end

	local placements = copyDictionary(DEFAULT_RUN_DATA.Placements[DEFAULT_DIMENSION])
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			if type(upgradeId) == "string" then
				local floorId = FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId))
				local surface = FloorGeometry.GetSurface(sheet, floorId)
				if surface then
					local boundingCFrame = child:GetBoundingBox()
					local relative = surface.originCFrame:ToObjectSpace(boundingCFrame)
					local _, rotationY = relative:ToOrientation()
					rotationY = tonumber(child:GetAttribute(Attrs.PlacementRotationY)) or rotationY
					placements[floorId] = placements[floorId] or {}
					placements[floorId][upgradeId] = placements[floorId][upgradeId] or {}
					table.insert(placements[floorId][upgradeId], {
						X = relative.X,
						Y = relative.Y,
						Z = relative.Z,
						RY = rotationY,
					})
				end
			end
		end
	end

	return placements
end

-- This function is deliberately yield-free. ProfileStore dispatches OnSave listeners with
-- task.spawn and immediately continues its save path, so yielding here would make the final
-- snapshot race the DataStore transform. Explicit saves also call this before Profile:Save().
local function snapshotPlayer(player, data)
	if type(data) ~= "table" or type(data.Run) ~= "table" then
		return data
	end

	local run = data.Run

	-- Placement is the sole permanent projection-to-Data exception. Its readiness is purposely
	-- independent of all non-placement Values: loaded placement Data is retained during setup,
	-- and reset closes this gate before its potentially yielding world resynchronization.
	local buildingPlacements = placementSerializationReadyByPlayer[player]
		and serializeBuildingPlacements(player)
		or nil
	if buildingPlacements then
		run.Placements = type(run.Placements) == "table" and run.Placements
			or copyDictionary(DEFAULT_RUN_DATA.Placements)
		run.PlacementSchemaVersion = FloorConfig.PlacementSchemaVersion
		run.Placements[DEFAULT_DIMENSION] = buildingPlacements
	end

	-- Publish only canonical metric fields that are legitimately queued before comparing any
	-- converted projection. This keeps normal one-second lag quiet without masking unqueued
	-- attribute/Data mismatches. Every periodic, explicit, leave, and shutdown save reaches this
	-- shared yield-free snapshot path.
	PlayerMetricsService.FlushProjections(player)
	PlayerDataProjectionAudit.Check(player, data)

	return data
end

local function readSavedGeneration(profile)
	local keyInfo = profile.KeyInfo
	if not keyInfo then
		return 0
	end
	local ok, metadata = pcall(function()
		return keyInfo:GetMetadata()
	end)
	if not ok or type(metadata) ~= "table" then
		return 0
	end
	return tonumber(metadata[SAVE_GENERATION_METADATA_KEY]) or 0
end

local function cleanupPlayer(player, profile)
	if profilesByPlayer[player] == profile then
		profilesByPlayer[player] = nil
		domain7ReadyByPlayer[player] = nil
		placementSerializationReadyByPlayer[player] = nil
		PlayerMetricsService.ForgetPlayer(player)
		PlayerDataProjectionAudit.ForgetPlayer(player)
	end
	confirmedSaveGenerationByProfile[profile] = nil
	local expected = expectedSessionEndByPlayer[player]
	expectedSessionEndByPlayer[player] = nil
	if not expected and player.Parent == Players then
		player:Kick("Your data session ended. Please rejoin.")
	end
end

local function prepareProfile(profile)
	local migrationOk, migrationProblem = migrate(profile.Data)
	if not migrationOk then
		return false, migrationProblem
	end

	profile:Reconcile()
	if type(profile.RobloxMetaData) ~= "table" then
		profile.RobloxMetaData = {}
	end
	local data = profile.Data
	if profile.SessionLoadCount == 1 then
		data.Persistent.IntroSeen = false
		data.Persistent.StoryChapter = DEFAULT_PERSISTENT_DATA.StoryChapter
		data.Persistent.StoryStep = DEFAULT_PERSISTENT_DATA.StoryStep
		data.Persistent.StoryHealingClicks = DEFAULT_PERSISTENT_DATA.StoryHealingClicks
		data.Persistent.MixerUnlocked = false
	end
	local loadedPlacementSchemaVersion = data.Run.PlacementSchemaVersion
	data.Run.Placements = normalizePlacements(data.Run.Placements, loadedPlacementSchemaVersion)
	data.Run.PlacementSchemaVersion = FloorConfig.PlacementSchemaVersion
	normalizeUpgradeCounts(data, true)
	return true
end

function PlayerDataService.Load(player)
	configureStore()
	local loadStartedAt = os.clock()
	local profile = playerStore:StartSessionAsync(getKey(player), {
		Cancel = function()
			return player.Parent ~= Players or os.clock() - loadStartedAt >= LOAD_TIMEOUT_SECONDS
		end,
	})

	if not profile then
		if player.Parent == Players then
			player:Kick("Your data failed to load. Please rejoin in a minute — no progress has been lost.")
		end
		return nil
	end

	profile:AddUserId(player.UserId)
	profile.OnSessionEnd:Connect(function()
		cleanupPlayer(player, profile)
	end)
	local prepareCallOk, profileOk, profileProblem = pcall(prepareProfile, profile)
	if not prepareCallOk or not profileOk then
		local problem = prepareCallOk and profileProblem or profileOk
		warn(("PlayerDataService: %s profile rejected: %s"):format(player.Name, tostring(problem or "unknown")))
		expectedSessionEndByPlayer[player] = true
		profile:EndSession()
		if player.Parent == Players then
			player:Kick("Your save data is from a newer version of the game. Please rejoin later.")
		end
		return nil
	end

	local data = profile.Data
	profile.OnSave:Connect(function()
		-- Yield-free by contract; see snapshotPlayer.
		snapshotPlayer(player, profile.Data)
	end)
	profile.OnAfterSave:Connect(function()
		if profile:IsActive() then
			confirmedSaveGenerationByProfile[profile] = readSavedGeneration(profile)
		end
	end)

	if player.Parent ~= Players then
		expectedSessionEndByPlayer[player] = true
		profile:EndSession()
		return nil
	end

	profilesByPlayer[player] = profile
	confirmedSaveGenerationByProfile[profile] = readSavedGeneration(profile)
	return data
end

function PlayerDataService.Get(player)
	local profile = profilesByPlayer[player]
	if not profile or not profile:IsActive() then
		return nil
	end
	return profile.Data
end

-- Domain 7 is deliberately gated separately from the active-profile accessor because earlier
-- canonical domains finish setup before Run projections and metrics are ready. Public Run reads
-- and mutations must use this accessor so pre-setup and post-session-loss calls fail closed.
function PlayerDataService.GetDomain7Data(player)
	if domain7ReadyByPlayer[player] ~= true then
		return nil
	end
	local data = PlayerDataService.Get(player)
	if type(data) ~= "table" or type(data.Run) ~= "table" or type(data.Persistent) ~= "table" then
		return nil
	end
	return data
end

function PlayerDataService.PrepareDomain7Projections(player)
	domain7ReadyByPlayer[player] = nil
	local data = PlayerDataService.Get(player)
	return data ~= nil and projectDomain7(player, data) or false
end

function PlayerDataService.CompleteDomain7Setup(player)
	local data = PlayerDataService.Get(player)
	if not data or not projectDomain7(player, data) then
		return false
	end
	domain7ReadyByPlayer[player] = true
	PlayerDataProjectionAudit.MarkDomain7ProjectionReady(player)
	return true
end

function PlayerDataService.MarkPlacementSerializationReady(player)
	if not PlayerDataService.GetDomain7Data(player) then
		return false
	end
	placementSerializationReadyByPlayer[player] = true
	return true
end

-- LastSeenTimestamp is canonical Data. Callers may reach this after a yielded setup path or
-- stamp-loop wait, so re-check the live profile immediately before mutating it. Project only
-- after Data holds the exact value that will be saved.
function PlayerDataService.SetLastSeenTimestamp(player, timestamp)
	local profile = profilesByPlayer[player]
	if not profile or not profile:IsActive() then
		return false
	end

	local persistent = type(profile.Data) == "table" and profile.Data.Persistent
	local numericTimestamp = tonumber(timestamp)
	if type(persistent) ~= "table" or not numericTimestamp then
		return false
	end

	persistent.LastSeenTimestamp = math.floor(numericTimestamp)
	player:SetAttribute(Attrs.LastSeenTimestamp, persistent.LastSeenTimestamp)
	return true
end

function PlayerDataService.UpdateFromPlayerValues(player)
	return snapshotPlayer(player, PlayerDataService.Get(player))
end

function PlayerDataService.ResetRun(player)
	local data = PlayerDataService.GetDomain7Data(player)
	-- Validate every required projection before swapping the canonical table. Replacement,
	-- normalization, and reprojection then complete in one yield-free turn.
	if not data or not getDomain7Projections(player) then
		return nil
	end

	placementSerializationReadyByPlayer[player] = nil
	data.Run = copyDictionary(DEFAULT_RUN_DATA)
	-- A reset intentionally constructs a fresh Run. Known definitions receive their current
	-- InitialCount defaults; unknown IDs preserved across ordinary loads are not resurrected at
	-- zero by the former Value read-back bridge.
	normalizeUpgradeCounts(data, false)
	if not projectDomain7(player, data) then
		return nil
	end
	return data.Run
end

function PlayerDataService.Save(player, force)
	local profile = profilesByPlayer[player]
	if not profile or not profile:IsActive() then
		return false
	end

	snapshotPlayer(player, profile.Data)
	local generation = (tonumber(profile.RobloxMetaData[SAVE_GENERATION_METADATA_KEY]) or 0) + 1
	profile.RobloxMetaData[SAVE_GENERATION_METADATA_KEY] = generation
	profile:Save()

	if force ~= true then
		return true
	end

	local deadline = os.clock() + FORCE_SAVE_WAIT_SECONDS
	while os.clock() < deadline do
		if (confirmedSaveGenerationByProfile[profile] or 0) >= generation then
			return true
		end
		if not profile:IsActive() then
			return false
		end
		task.wait()
	end
	return false
end

function PlayerDataService.Forget(player)
	local profile = profilesByPlayer[player]
	if not profile then
		expectedSessionEndByPlayer[player] = nil
		domain7ReadyByPlayer[player] = nil
		placementSerializationReadyByPlayer[player] = nil
		PlayerMetricsService.ForgetPlayer(player)
		PlayerDataProjectionAudit.ForgetPlayer(player)
		return
	end

	snapshotPlayer(player, profile.Data)
	expectedSessionEndByPlayer[player] = true
	profile:EndSession()
end

local function endPlayerSession(player)
	local profile = profilesByPlayer[player]
	if not profile or not profile:IsActive() then
		return
	end

	-- Stage A leave-ordering protection: stamp canonical Data and its projection before the
	-- final snapshot and before EndSession releases the profile lock. Do not rely on the later
	-- OfflineEarningsService PlayerRemoving listener or on listener ordering.
	PlayerDataService.SetLastSeenTimestamp(player, os.time())
	snapshotPlayer(player, profile.Data)
	expectedSessionEndByPlayer[player] = true
	profile:EndSession()
end

local function startAutosaveLoop()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				-- Save requests are independent, so one slow DataStore call cannot stall another player.
				task.spawn(PlayerDataService.Save, player, false)
			end
		end
	end)
end

function PlayerDataService.Init()
	configureStore()
	Players.PlayerRemoving:Connect(endPlayerSession)

	-- ProfileStore owns the shutdown wait. This sweep synchronously snapshots every live
	-- projection before asking each profile to perform its final, session-releasing save.
	game:BindToClose(function()
		local loadedPlayers = {}
		for player in pairs(profilesByPlayer) do
			table.insert(loadedPlayers, player)
		end
		for _, player in ipairs(loadedPlayers) do
			endPlayerSession(player)
		end
	end)

	startAutosaveLoop()
	print("PlayerDataService initialized (ProfileStore)")
end

-- PlayerMetricsService must validate every read/mutation against this active-profile contract,
-- but must not require this module or retain Profile.Data references of its own.
PlayerMetricsService.ConfigureDataAccess(PlayerDataService.Get)

return PlayerDataService
