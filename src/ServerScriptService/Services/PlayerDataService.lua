local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local GridPlacement = require(ReplicatedStorage.Shared.GridPlacement)

local PlayerDataService = {}

local DATASTORE_NAME = RunService:IsStudio() and "ClickGamePlayerData_v1_Studio" or "ClickGamePlayerData_v1"
local AUTOSAVE_SECONDS = 60
local MIN_SAVE_INTERVAL_SECONDS = 20
local MAX_RETRIES = 3
local DEFAULT_DIMENSION = "Earth"
local SERVER_SESSION_ID = HttpService:GenerateGUID(false)
local FORCE_SAVE_WAIT_SECONDS = 10

local store = DataStoreService:GetDataStore(DATASTORE_NAME)
local cacheByPlayer = {}
local loadedByPlayer = {}
local savingByPlayer = {}
local lastSaveAtByPlayer = {}
local lastSaveResultByPlayer = {}
local sessionClaimTimeByPlayer = {}

local DEFAULT_RUN_DATA = {
	Cookies = 0,
	CanBeStolenFrom = false,
	ShieldTime = 600,
	UpgradeCounts = {},
	Placements = {
		Earth = {},
	},
}

local DEFAULT_PERSISTENT_DATA = {
	RealPlayTime = 0,
	Xp = 0,
	GoldenCookies = 0,
	OwnedSkins = {},
	EquippedSkins = {},
	LoginStreak = 0,
	LastLoginDay = 0,
	Achievements = {},
	LastSeenTimestamp = 0,
	UnlockedBuildings = {},
	-- Once a player ticks "don't show again" on the Build View nudge we never prompt
	-- them again, across sessions. Defaults false so genuinely new players get nudged.
	BuildViewNudgeDisabled = false,
	-- First-time meteor cutscene gate. Defaults false so a brand-new account plays it once;
	-- Load() force-sets it true for any pre-existing save that predates this field, so only
	-- genuinely new accounts ever see the intro. IntroController flips it via MarkIntroSeen.
	IntroSeen = false,
	StoryChapter = "GooArrival",
	StoryStep = "Meteor",
	StoryHealingClicks = 0,
	-- Whether the alien's dough tool (the "Mixer", formerly "Crumbforge") is unlocked. Old saves
	-- store this under the legacy "CrumbforgeUnlocked" key; Load() migrates it (see rawMixerUnlocked).
	MixerUnlocked = false,
	CompletedStoryChapters = {},
}

local DEFAULT_DATA = {
	Run = DEFAULT_RUN_DATA,
	Persistent = DEFAULT_PERSISTENT_DATA,
}

local migrateUpgradeCounts

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

local function mergeKnownFields(defaults, source)
	local merged = copyDictionary(defaults)

	if type(source) ~= "table" then
		return merged
	end

	for key, value in pairs(source) do
		if type(defaults[key]) == "table" and type(value) == "table" then
			merged[key] = copyDictionary(value)
		elseif defaults[key] ~= nil then
			merged[key] = value
		end
	end

	return merged
end

-- Placements are dimension-keyed ({ Earth = { upgradeId = {...} } }). No legacy flat-format
-- migration: the game is pre-release, so saves only ever use the current shape.
local function normalizePlacements(placements)
	local normalized = copyDictionary(DEFAULT_RUN_DATA.Placements)
	if type(placements) ~= "table" then
		return normalized
	end

	for dimensionName, dimensionPlacements in pairs(placements) do
		if type(dimensionName) == "string" and type(dimensionPlacements) == "table" then
			normalized[dimensionName] = copyDictionary(dimensionPlacements)
		end
	end

	return normalized
end

local function migrateFlatData(data)
	local migrated = copyDictionary(DEFAULT_DATA)
	if type(data) ~= "table" then
		return migrated
	end

	migrated.Run = mergeKnownFields(DEFAULT_RUN_DATA, {
		Cookies = data.Cookies,
		CanBeStolenFrom = data.CanBeStolenFrom,
		ShieldTime = data.ShieldTime,
		UpgradeCounts = data.UpgradeCounts,
	})
	migrated.Run.Placements = normalizePlacements(data.Placements)

	migrated.Persistent = mergeKnownFields(DEFAULT_PERSISTENT_DATA, {
		RealPlayTime = data.RealPlayTime,
		Xp = data.Xp,
		GoldenCookies = data.GoldenCookies,
		OwnedSkins = data.OwnedSkins,
		EquippedSkins = data.EquippedSkins,
		LoginStreak = data.LoginStreak,
		LastLoginDay = data.LastLoginDay,
		Achievements = data.Achievements,
		LastSeenTimestamp = data.LastSeenTimestamp or data.lastSeenTimestamp,
		UnlockedBuildings = data.UnlockedBuildings,
	})

	return migrated
end

local function mergeDefaults(data)
	if type(data) ~= "table" then
		return copyDictionary(DEFAULT_DATA)
	end

	if type(data.Run) ~= "table" and type(data.Persistent) ~= "table" then
		return migrateFlatData(data)
	end

	local merged = copyDictionary(DEFAULT_DATA)
	merged.Run = mergeKnownFields(DEFAULT_RUN_DATA, data.Run)
	merged.Run.Placements = normalizePlacements(data.Run and data.Run.Placements)
	merged.Persistent = mergeKnownFields(DEFAULT_PERSISTENT_DATA, data.Persistent)

	return merged
end

local function getKey(player)
	return "player_" .. player.UserId
end

local function getSaveTimestamp()
	return DateTime.now().UnixTimestampMillis
end

local function createSaveBlob(data, saveTime)
	local blob = mergeDefaults(data)
	migrateUpgradeCounts(blob)
	blob.sessionId = SERVER_SESSION_ID
	blob.lastSaveTime = saveTime
	return blob
end

local function hasNewerLiveSession(currentValue, sessionClaimTime)
	if type(currentValue) ~= "table" then
		return false
	end

	local currentSessionId = currentValue.sessionId
	local currentLastSaveTime = tonumber(currentValue.lastSaveTime)
	if type(currentSessionId) ~= "string" or not currentLastSaveTime then
		return false
	end

	return currentSessionId ~= SERVER_SESSION_ID and currentLastSaveTime >= sessionClaimTime
end

-- §4a consolidation (2026-06-11): the per-level building upgrades ("Granny
-- Upgrade 1/2") became one leveled entry ("Granny Upgrades") whose count = levels
-- owned. Old saves carry the legacy ids; fold each owned legacy level into the new
-- entry's count so equipped multipliers survive, then drop the legacy keys.
local function buildLegacyUpgradeMap()
	local map = {}
	for upgradeId, config in pairs(UpgradeConfig) do
		if config.TemplateKind == "BuildingUpgrade" and type(config.TargetBuilding) == "string" and config.Levels then
			for level = 1, #config.Levels do
				map[config.TargetBuilding .. " Upgrade " .. level] = upgradeId
			end
		end
	end
	return map
end

local function migrateLegacyLeveledUtilityCounts(counts)
	local legacyLevels = {
		["Offline Earnings I"] = { UpgradeId = "Offline Earnings", Level = 1 },
		["Offline Earnings II"] = { UpgradeId = "Offline Earnings", Level = 2 },
		["Base Expansion I"] = { UpgradeId = "Base Expansion", Level = 1 },
		["Base Expansion II"] = { UpgradeId = "Base Expansion", Level = 2 },
	}

	for legacyId, target in pairs(legacyLevels) do
		local owned = counts[legacyId]
		if owned ~= nil then
			if (tonumber(owned) or 0) > 0 then
				counts[target.UpgradeId] = math.max(tonumber(counts[target.UpgradeId]) or 0, target.Level)
			end
			counts[legacyId] = nil
		end
	end
end

function migrateUpgradeCounts(data)
	local run = type(data) == "table" and data.Run
	if type(run) ~= "table" or type(run.UpgradeCounts) ~= "table" then
		return
	end

	local counts = run.UpgradeCounts
	migrateLegacyLeveledUtilityCounts(counts)

	for legacyId, newId in pairs(buildLegacyUpgradeMap()) do
		local owned = counts[legacyId]
		if owned ~= nil then
			if (tonumber(owned) or 0) > 0 then
				counts[newId] = (tonumber(counts[newId]) or 0) + 1
			end
			counts[legacyId] = nil
		end
	end

	-- Never let folded counts exceed available level counts.
	for upgradeId, config in pairs(UpgradeConfig) do
		if config.Levels and counts[upgradeId] ~= nil then
			local maxLevels = config.Levels and #config.Levels or 0
			counts[upgradeId] = math.clamp(tonumber(counts[upgradeId]) or 0, 0, maxLevels)
		end
	end
end

local function withRetries(actionName, callback)
	local lastError

	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(callback)
		if ok then
			return true, result
		end

		lastError = result
		warn(actionName .. " failed, attempt " .. attempt .. ": " .. tostring(result))
		task.wait(attempt)
	end

	return false, lastError
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
	local base = sheet and sheet:FindFirstChild("Base")
	if not sheet or not base or not base:IsA("BasePart") then
		return nil
	end

	local placements = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			if type(upgradeId) == "string" then
				local boundingCFrame = child:GetBoundingBox()
				-- Store relative to the fixed inner-edge anchor so positions survive the
				-- Base growing outward (matches getSavedBuildingCFrame on load).
				local anchor = GridPlacement.getPlacementAnchorCFrame(base)
				local relative = anchor:ToObjectSpace(boundingCFrame)
				local _, rotationY = relative:ToOrientation()
				rotationY = tonumber(child:GetAttribute(Attrs.PlacementRotationY)) or rotationY
				placements[upgradeId] = placements[upgradeId] or {}
				table.insert(placements[upgradeId], {
					X = relative.X,
					Y = relative.Y,
					Z = relative.Z,
					RY = rotationY,
				})
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

	if ok and type(decoded) == "table" then
		return decoded
	end

	return nil
end

-- True when the raw save already carried an IntroSeen flag (any session since the field
-- shipped). Reads the un-merged currentValue, where a missing field is genuinely absent --
-- after mergeDefaults it would always read back as the `false` default.
local function rawHasIntroSeen(currentValue)
	return type(currentValue) == "table"
		and type(currentValue.Persistent) == "table"
		and type(currentValue.Persistent.IntroSeen) == "boolean"
end

local function rawHasStoryProgress(currentValue)
	local persistent = type(currentValue) == "table" and currentValue.Persistent
	return type(persistent) == "table"
		and type(persistent.StoryStep) == "string"
		-- Accept either the new MixerUnlocked field or the legacy CrumbforgeUnlocked one, so
		-- existing saves keep their story progress through the rename.
		and (type(persistent.MixerUnlocked) == "boolean" or type(persistent.CrumbforgeUnlocked) == "boolean")
end

-- The Mixer unlock as written by an existing save, preferring the current key but falling back to
-- the legacy "Crumbforge" name so already-unlocked players keep the tool through the rename.
-- Reads the raw pre-merge value (mergeKnownFields would drop the unknown legacy key).
local function rawMixerUnlocked(currentValue)
	local persistent = type(currentValue) == "table" and currentValue.Persistent
	if type(persistent) ~= "table" then
		return nil
	end
	if type(persistent.MixerUnlocked) == "boolean" then
		return persistent.MixerUnlocked
	end
	if type(persistent.CrumbforgeUnlocked) == "boolean" then
		return persistent.CrumbforgeUnlocked
	end
	return nil
end

local function rawIntroWasSeen(currentValue)
	local persistent = type(currentValue) == "table" and currentValue.Persistent
	return type(persistent) == "table" and persistent.IntroSeen == true
end

function PlayerDataService.Load(player)
	local claimTime = getSaveTimestamp()
	-- Captured inside the UpdateAsync transform (the only place we see the pre-merge value):
	-- a brand-new account has currentValue == nil; a pre-IntroSeen save has no IntroSeen field.
	local isBrandNewAccount = false
	local hadIntroSeen = false
	local hadStoryProgress = false
	local introWasSeen = false
	local legacyMixerUnlocked = nil
	local ok, result = withRetries("Load data for " .. player.Name, function()
		return store:UpdateAsync(getKey(player), function(currentValue)
			isBrandNewAccount = currentValue == nil
			hadIntroSeen = rawHasIntroSeen(currentValue)
			hadStoryProgress = rawHasStoryProgress(currentValue)
			introWasSeen = rawIntroWasSeen(currentValue)
			legacyMixerUnlocked = rawMixerUnlocked(currentValue)
			return createSaveBlob(currentValue, claimTime)
		end)
	end)

	local data
	if ok then
		data = mergeDefaults(result)
		sessionClaimTimeByPlayer[player] = claimTime
	else
		-- Load failed after retries: the session runs on defaults, but saving stays
		-- DISABLED (loadedByPlayer is never set) so an autosave can't overwrite the
		-- player's real data with an empty blob during a DataStore outage. Outside
		-- Studio the player is kicked so they don't sink time into unsaveable progress.
		data = mergeDefaults(nil)
		sessionClaimTimeByPlayer[player] = claimTime
		warn("Load failed for " .. player.Name .. "; saving disabled for this session")
		if not RunService:IsStudio() then
			task.defer(function()
				player:Kick("Your data failed to load. Please rejoin in a minute — no progress has been lost.")
			end)
		end
	end

	-- Carry the Mixer unlock forward from the legacy "CrumbforgeUnlocked" save key (mergeDefaults
	-- drops unknown keys, so the raw value captured above is the only place it survives). The
	-- legacy-complete block below may still force it true for pre-story saves.
	if legacyMixerUnlocked ~= nil then
		data.Persistent.MixerUnlocked = legacyMixerUnlocked
	end

	-- Only genuinely new accounts should see the meteor intro. An existing save that predates
	-- the IntroSeen field (legacy pre-release players) is treated as already-seen so it never
	-- replays for them. A failed load (ok == false) is also treated as already-seen -- never
	-- play the cutscene over data we couldn't read.
	if not isBrandNewAccount and not hadIntroSeen then
		data.Persistent.IntroSeen = true
	end

	-- Compatibility for saves created before Chapter 1 had granular story fields. Those
	-- players may already have IntroSeen=true, but mergeDefaults would otherwise inject the
	-- new "Meteor" default and unexpectedly force them into the cinematic with a Scriptable
	-- camera. Existing saves without story progress are treated as complete; testers can use
	-- the Studio "Replay Chapter 1" button when they intentionally want the full sequence.
	-- Also repair the short-lived bad state produced by the first story build:
	-- IntroSeen=true + StoryStep="Meteor" is impossible in the intended flow.
	local hasAccidentalMeteorState = data.Persistent.IntroSeen == true
		and data.Persistent.StoryStep == "Meteor"
	if (not isBrandNewAccount and not hadStoryProgress) or introWasSeen and hasAccidentalMeteorState or not ok then
		data.Persistent.IntroSeen = true
		data.Persistent.StoryChapter = "GooArrival"
		data.Persistent.StoryStep = "Complete"
		data.Persistent.StoryHealingClicks = 5
		data.Persistent.MixerUnlocked = true
	end

	migrateUpgradeCounts(data)

	cacheByPlayer[player] = data
	-- Only a successful load arms saving; a defaulted session must never write.
	loadedByPlayer[player] = ok or nil
	-- If the player left while the load was yielding, PlayerRemoving already ran
	-- Forget(); don't resurrect their cache entry (player-keyed tables would leak).
	if player.Parent == nil then
		PlayerDataService.Forget(player)
		return data
	end
	return data
end

function PlayerDataService.Get(player)
	return cacheByPlayer[player]
end

function PlayerDataService.UpdateFromPlayerValues(player)
	local data = cacheByPlayer[player]
	if not data then
		return nil
	end

	data.Run = data.Run or copyDictionary(DEFAULT_RUN_DATA)
	data.Persistent = data.Persistent or copyDictionary(DEFAULT_PERSISTENT_DATA)

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

	run.UpgradeCounts = {}
	if upgradeCountData then
		for _, value in ipairs(upgradeCountData:GetChildren()) do
			if value:IsA("IntValue") then
				run.UpgradeCounts[value.Name] = value.Value
			end
		end
	end
	local buildingPlacements = serializeBuildingPlacements(player)
	if buildingPlacements then
		run.Placements = run.Placements or copyDictionary(DEFAULT_RUN_DATA.Placements)
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
	persistent.Achievements = decodeJsonTable(player:GetAttribute(Attrs.AchievementsJson)) or persistent.Achievements
	persistent.UnlockedBuildings = decodeJsonTable(player:GetAttribute(Attrs.UnlockedBuildingsJson)) or persistent.UnlockedBuildings

	return data
end

function PlayerDataService.ResetRun(player)
	local data = cacheByPlayer[player]
	if not data then
		return nil
	end

	data.Run = copyDictionary(DEFAULT_RUN_DATA)
	data.Persistent = mergeKnownFields(DEFAULT_PERSISTENT_DATA, data.Persistent)
	return data.Run
end

function PlayerDataService.Save(player, force)
	if not loadedByPlayer[player] then
		return false
	end

	if savingByPlayer[player] then
		if force then
			local waitStartedAt = os.clock()
			while savingByPlayer[player] and os.clock() - waitStartedAt < FORCE_SAVE_WAIT_SECONDS do
				task.wait()
			end

			return lastSaveResultByPlayer[player] == true
		end

		return false
	end

	local now = os.clock()
	local lastSaveAt = lastSaveAtByPlayer[player]
	if not force and lastSaveAt and now - lastSaveAt < MIN_SAVE_INTERVAL_SECONDS then
		return false
	end

	local data = PlayerDataService.UpdateFromPlayerValues(player)
	if not data then
		return false
	end

	savingByPlayer[player] = true
	lastSaveResultByPlayer[player] = nil

	local saveTime = getSaveTimestamp()
	local sessionClaimTime = sessionClaimTimeByPlayer[player] or 0
	local saveBlob = createSaveBlob(data, saveTime)
	local staleConflict
	local ok, savedBlob = withRetries("Save data for " .. player.Name, function()
		return store:UpdateAsync(getKey(player), function(currentValue)
			if hasNewerLiveSession(currentValue, sessionClaimTime) then
				staleConflict = {
					sessionId = currentValue.sessionId,
					lastSaveTime = currentValue.lastSaveTime,
				}
				return nil
			end

			return saveBlob
		end)
	end)
	local didWrite = ok and type(savedBlob) == "table" and savedBlob.sessionId == SERVER_SESSION_ID and savedBlob.lastSaveTime == saveTime

	if didWrite then
		lastSaveAtByPlayer[player] = os.clock()
		sessionClaimTimeByPlayer[player] = saveTime
	elseif staleConflict then
		warn(
			"Refused stale save for "
				.. player.Name
				.. ": data is owned by newer live session "
				.. tostring(staleConflict.sessionId)
				.. " at "
				.. tostring(staleConflict.lastSaveTime)
				.. ". Persistent data remains protected; stale Run data was not written."
		)
	end

	lastSaveResultByPlayer[player] = didWrite
	savingByPlayer[player] = nil
	return didWrite
end

function PlayerDataService.Forget(player)
	cacheByPlayer[player] = nil
	loadedByPlayer[player] = nil
	savingByPlayer[player] = nil
	lastSaveAtByPlayer[player] = nil
	lastSaveResultByPlayer[player] = nil
	sessionClaimTimeByPlayer[player] = nil
end

local function startAutosaveLoop()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)

			for _, player in ipairs(Players:GetPlayers()) do
				-- Spawned so one player's slow/retrying save can't starve the others
				-- past the autosave cadence (Save() is already re-entrancy guarded).
				task.spawn(PlayerDataService.Save, player, false)
			end
		end
	end)
end

function PlayerDataService.Init()
	Players.PlayerRemoving:Connect(function(player)
		PlayerDataService.Save(player, true)
		PlayerDataService.Forget(player)
	end)

	game:BindToClose(function()
		-- Save everyone in parallel and wait for all to finish: sequential saves
		-- (each up to MAX_RETRIES with backoff) would overrun the ~30s shutdown budget.
		local pending = 0
		for _, player in ipairs(Players:GetPlayers()) do
			pending += 1
			task.spawn(function()
				PlayerDataService.Save(player, true)
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait(0.1)
		end
	end)

	startAutosaveLoop()
	print("PlayerDataService initialized")
end

return PlayerDataService
