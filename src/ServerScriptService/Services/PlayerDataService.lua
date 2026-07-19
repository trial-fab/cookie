local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
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
local SettingsConfig = require(ReplicatedStorage.Shared.SettingsConfig)
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
local cacheByPlayer = {}
local expectedSessionEndByPlayer = {}
local confirmedSaveGenerationByProfile = {}

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

local function validateUpgradeCounts(data)
	local run = type(data) == "table" and data.Run
	if type(run) ~= "table" then
		return
	end
	if type(run.UpgradeCounts) ~= "table" then
		run.UpgradeCounts = {}
		return
	end

	for upgradeId, config in pairs(UpgradeConfig) do
		if config.Levels and run.UpgradeCounts[upgradeId] ~= nil then
			run.UpgradeCounts[upgradeId] = math.clamp(
				tonumber(run.UpgradeCounts[upgradeId]) or 0,
				0,
				#config.Levels
			)
		end
	end
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

local function decodeJsonTable(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(value)
	end)
	return ok and type(decoded) == "table" and decoded or nil
end

local function projectionsAreReady(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	return leaderstats ~= nil
		and leaderstats:FindFirstChild("Cookies") ~= nil
		and player:FindFirstChild("RealPlayTime") ~= nil
		and player:FindFirstChild("CanBeStolenFrom") ~= nil
		and player:FindFirstChild("ShieldTime") ~= nil
		and player:FindFirstChild("UpgradeCountData") ~= nil
end

-- This function is deliberately yield-free. ProfileStore dispatches OnSave listeners with
-- task.spawn and immediately continues its save path, so yielding here would make the final
-- snapshot race the DataStore transform. Explicit saves also call this before Profile:Save().
local function snapshotPlayer(player, data)
	if not data or not projectionsAreReady(player) then
		return data
	end

	data.Run = type(data.Run) == "table" and data.Run or copyDictionary(DEFAULT_RUN_DATA)
	data.Persistent = type(data.Persistent) == "table" and data.Persistent
		or copyDictionary(DEFAULT_PERSISTENT_DATA)

	local run = data.Run
	local persistent = data.Persistent
	local leaderstats = player:FindFirstChild("leaderstats")
	local cookies = leaderstats and leaderstats:FindFirstChild("Cookies")
	local realPlayTime = player:FindFirstChild("RealPlayTime")
	local canBeStolenFrom = player:FindFirstChild("CanBeStolenFrom")
	local shieldTime = player:FindFirstChild("ShieldTime")
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")

	if cookies then
		run.Cookies = cookies.Value
	end
	if realPlayTime then
		persistent.RealPlayTime = realPlayTime.Value
	end

	local xp = player:GetAttribute(Attrs.Xp)
	if typeof(xp) == "number" then
		persistent.Xp = math.max(0, math.floor(xp))
	end
	if canBeStolenFrom then
		run.CanBeStolenFrom = canBeStolenFrom.Value
	end
	if shieldTime then
		run.ShieldTime = shieldTime.Value
	end

	if upgradeCountData then
		run.UpgradeCounts = {}
		for _, value in ipairs(upgradeCountData:GetChildren()) do
			if value:IsA("IntValue") then
				run.UpgradeCounts[value.Name] = value.Value
			end
		end
	end

	local buildingPlacements = serializeBuildingPlacements(player)
	if buildingPlacements then
		run.Placements = type(run.Placements) == "table" and run.Placements
			or copyDictionary(DEFAULT_RUN_DATA.Placements)
		run.PlacementSchemaVersion = FloorConfig.PlacementSchemaVersion
		run.Placements[DEFAULT_DIMENSION] = buildingPlacements
	end

	local goldenCookies = player:GetAttribute(Attrs.GoldenCookies)
	if typeof(goldenCookies) == "number" then
		persistent.GoldenCookies = goldenCookies
	end
	local loginStreak = player:GetAttribute(Attrs.LoginStreak)
	if typeof(loginStreak) == "number" then
		persistent.LoginStreak = loginStreak
	end
	local lastLoginDay = player:GetAttribute(Attrs.LastLoginDay)
	if typeof(lastLoginDay) == "number" then
		persistent.LastLoginDay = lastLoginDay
	end
	local lastSeenTimestamp = player:GetAttribute(Attrs.LastSeenTimestamp)
	if typeof(lastSeenTimestamp) == "number" then
		persistent.LastSeenTimestamp = lastSeenTimestamp
	end
	local buildViewNudgeDisabled = player:GetAttribute(Attrs.BuildViewNudgeDisabled)
	if typeof(buildViewNudgeDisabled) == "boolean" then
		persistent.BuildViewNudgeDisabled = buildViewNudgeDisabled
	end
	local introSeen = player:GetAttribute(Attrs.IntroSeen)
	if typeof(introSeen) == "boolean" then
		persistent.IntroSeen = introSeen
	end
	local storyChapter = player:GetAttribute(Attrs.StoryChapter)
	if typeof(storyChapter) == "string" then
		persistent.StoryChapter = storyChapter
	end
	local storyStep = player:GetAttribute(Attrs.StoryStep)
	if typeof(storyStep) == "string" then
		persistent.StoryStep = storyStep
	end
	local storyHealingClicks = player:GetAttribute(Attrs.StoryHealingClicks)
	if typeof(storyHealingClicks) == "number" then
		persistent.StoryHealingClicks = math.max(0, math.floor(storyHealingClicks))
	end
	local mixerUnlocked = player:GetAttribute(Attrs.MixerUnlocked)
	if typeof(mixerUnlocked) == "boolean" then
		persistent.MixerUnlocked = mixerUnlocked
	end

	persistent.OwnedSkins = decodeJsonTable(player:GetAttribute(Attrs.OwnedSkinsJson)) or persistent.OwnedSkins
	persistent.EquippedSkins = decodeJsonTable(player:GetAttribute(Attrs.EquippedSkinsJson)) or persistent.EquippedSkins
	persistent.OwnedGooSkins = decodeJsonTable(player:GetAttribute(Attrs.OwnedGooSkinsJson))
		or persistent.OwnedGooSkins
	local selectedGooSkin = player:GetAttribute(Attrs.SelectedGooSkinId)
	if typeof(selectedGooSkin) == "string" then
		persistent.SelectedGooSkin = selectedGooSkin
	end
	persistent.Achievements = decodeJsonTable(player:GetAttribute(Attrs.AchievementsJson)) or persistent.Achievements
	persistent.UnlockedBuildings = decodeJsonTable(player:GetAttribute(Attrs.UnlockedBuildingsJson))
		or persistent.UnlockedBuildings
	persistent.Settings = type(persistent.Settings) == "table" and persistent.Settings or {}
	for _, attribute in ipairs(SettingsConfig.StoredAttributes) do
		local value = player:GetAttribute(attribute)
		if type(value) == "boolean" then
			persistent.Settings[attribute] = value
		else
			persistent.Settings[attribute] = nil
		end
	end
	PlayerMetricsService.WritePersistentData(player, persistent)
	validateUpgradeCounts(data)

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
		cacheByPlayer[player] = nil
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
	validateUpgradeCounts(data)
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
	cacheByPlayer[player] = data
	confirmedSaveGenerationByProfile[profile] = readSavedGeneration(profile)
	return data
end

function PlayerDataService.Get(player)
	return cacheByPlayer[player]
end

function PlayerDataService.UpdateFromPlayerValues(player)
	return snapshotPlayer(player, cacheByPlayer[player])
end

function PlayerDataService.ResetRun(player)
	local data = cacheByPlayer[player]
	if not data then
		return nil
	end

	data.Run = copyDictionary(DEFAULT_RUN_DATA)
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
		cacheByPlayer[player] = nil
		expectedSessionEndByPlayer[player] = nil
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

	if typeof(player:GetAttribute(Attrs.LastSeenTimestamp)) == "number" then
		player:SetAttribute(Attrs.LastSeenTimestamp, os.time())
	end
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

return PlayerDataService
