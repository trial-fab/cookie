local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostFieldService = require(ServerScriptService.Services.BoostFieldService)
local BoostShopService = require(ServerScriptService.Services.BoostShopService)
local CookieService = require(ServerScriptService.Services.CookieService)
local FloorService = require(ServerScriptService.Services.FloorService)
local PlayerDataProjectionAudit = require(ServerScriptService.Services.PlayerDataProjectionAudit)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local SheetService = require(ServerScriptService.Services.SheetService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local WheelService = require(ServerScriptService.Services.WheelService)
local ProductionService = require(ServerScriptService.Services.ProductionService)
local OfflineEarningsService = require(ServerScriptService.Services.OfflineEarningsService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local MusicService = require(ServerScriptService.Services.MusicService)
local SettingsService = require(ServerScriptService.Services.SettingsService)
local StoryService = require(ServerScriptService.Services.StoryService)
local QuestService = require(ServerScriptService.Services.QuestService)
local TitleService = require(ServerScriptService.Services.TitleService)
local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)

local PlayerSetupService = {}
local DEFAULT_DIMENSION = "Earth"

local function createValue(className, name, value, parent)
	local object = Instance.new(className)
	object.Name = name
	object.Value = value
	object.Parent = parent
	return object
end

local function encodeJson(value)
	local ok, result = pcall(function()
		return HttpService:JSONEncode(type(value) == "table" and value or {})
	end)

	return ok and result or "{}"
end

local function createPersistentAttributes(player, persistent)
	-- Domain 4 Data is canonical even during initialization. Normalize each scalar
	-- currency before projecting the exact values that services will subsequently own.
	persistent.Xp = math.max(0, math.floor(tonumber(persistent.Xp) or 0))
	persistent.GoldenCookies = math.max(0, math.floor(tonumber(persistent.GoldenCookies) or 0))
	persistent.Gems = math.max(0, math.floor(tonumber(persistent.Gems) or 0))
	TitleService.SetupPlayer(player, persistent)
	player:SetAttribute(Attrs.Xp, persistent.Xp)
	player:SetAttribute(Attrs.GoldenCookies, persistent.GoldenCookies)
	player:SetAttribute(Attrs.Gems, persistent.Gems)
	player:SetAttribute(Attrs.LoginStreak, tonumber(persistent.LoginStreak) or 0)
	player:SetAttribute(Attrs.LastLoginDay, tonumber(persistent.LastLoginDay) or 0)
	player:SetAttribute(Attrs.LastSeenTimestamp, tonumber(persistent.LastSeenTimestamp) or 0)
	persistent.Achievements = type(persistent.Achievements) == "table" and persistent.Achievements or {}
	player:SetAttribute(Attrs.AchievementsJson, encodeJson(persistent.Achievements))
	player:SetAttribute(Attrs.BuildViewNudgeDisabled, persistent.BuildViewNudgeDisabled == true)
	player:SetAttribute(Attrs.IntroSeen, persistent.IntroSeen == true)
	player:SetAttribute(Attrs.StoryChapter, persistent.StoryChapter or "GooArrival")
	player:SetAttribute(Attrs.StoryStep, persistent.StoryStep or "Meteor")
	player:SetAttribute(Attrs.StoryHealingClicks, tonumber(persistent.StoryHealingClicks) or 0)
	player:SetAttribute(Attrs.MixerUnlocked, persistent.MixerUnlocked == true)
	-- Projects the saved boost-shop charge counts (and normalizes them to the current stack cap).
	BoostShopService.SetupPlayer(player, persistent)
end

local function createPlayerValues(player, data)
	local persistent = data.Persistent or {}

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	createValue("NumberValue", "Cookies", 0, leaderstats)
	createValue("StringValue", "Play Time", "00:00", leaderstats)

	createValue("IntValue", "RealPlayTime", 0, player)
	createValue("BoolValue", "CanBeStolenFrom", false, player)
	createValue("IntValue", "ShieldTime", 0, player)

	local upgradeCountData = Instance.new("Configuration")
	upgradeCountData.Name = "UpgradeCountData"
	upgradeCountData.Parent = player

	createValue("IntValue", "CookiesGainedPerClick", 1, player)
	createPersistentAttributes(player, persistent)
	PlayerDataProjectionAudit.MarkDomain3ProjectionReady(player)
	PlayerDataProjectionAudit.MarkDomain4ProjectionReady(player)
	return PlayerDataService.PrepareDomain7Projections(player)
end

local function startPlaytimeClock(player)
	local playTime = player:WaitForChild("leaderstats"):WaitForChild("Play Time")
	local sessionSeconds = 0

	task.spawn(function()
		while player.Parent do
			task.wait(1)

			local data = PlayerDataService.GetDomain7Data(player)
			local persistent = type(data) == "table" and data.Persistent
			local realPlayTime = player:FindFirstChild("RealPlayTime")
			if type(persistent) ~= "table" or not realPlayTime or not realPlayTime:IsA("IntValue") then
				break
			end

			persistent.RealPlayTime = math.max(0, math.round(tonumber(persistent.RealPlayTime) or 0)) + 1
			realPlayTime.Value = persistent.RealPlayTime
			sessionSeconds += 1
			PlayerMetricsService.RecordSessionDuration(player, sessionSeconds)

			local totalSeconds = persistent.RealPlayTime
			local seconds = totalSeconds % 60
			local hours = math.floor(totalSeconds / 3600)
			local minutes = math.floor((totalSeconds - (hours * 3600)) / 60)

			if totalSeconds >= 3600 then
				playTime.Value = string.format("%02d:%02d", hours, minutes)
			else
				playTime.Value = string.format("%02d:%02d", minutes, seconds)
			end
		end
	end)
end

-- Setup is a staged pipeline and any stage can fail closed. Bailing silently used to leave the
-- player standing in the world with leaderstats but no plot, no buildings, no quests and no
-- character teleport, with nothing in the log saying why. Name the stage, then end the session:
-- their canonical Data is untouched (placement and metric snapshots are both gated on readiness
-- flags this path never sets), so a rejoin is strictly better than an unplayable session.
local function abortSetup(player, stage)
	warn(("PlayerSetupService: %s failed at stage %q; ending the session so they can rejoin.")
		:format(player.Name, stage))
	if player.Parent == Players then
		player:Kick("Your session could not finish loading. Please rejoin.")
	end
end

local function setupPlayer(player)
	print("Setting up player:", player.Name)

	-- A nil `data` means PlayerDataService.Load already warned and kicked, and a missing parent
	-- means they left mid-load. Both are handled elsewhere, so neither is an abort case.
	local data = PlayerDataService.Load(player)
	if not data or player.Parent ~= Players then
		return
	end
	local projectionsPrepared = createPlayerValues(player, data)
	if not projectionsPrepared then
		abortSetup(player, "player value projections")
		return
	end
	local unlockedBuildingsReady = UpgradeService.SetupUnlockedBuildings(player)
	local metricsReady = PlayerMetricsService.SetupPlayer(player)
	if not metricsReady then
		abortSetup(player, "player metrics")
		return
	end
	PlayerDataProjectionAudit.MarkDomain6ProjectionReady(player)
	if not PlayerDataService.CompleteDomain7Setup(player) then
		abortSetup(player, "domain 7 projections")
		return
	end
	CookieService.RefreshCookiesPerClickDisplay(player)
	SettingsService.SetupPlayer(player, data.Persistent or {})
	-- After domain 7, because collection backfill reads the committed floor count.
	-- Music is presentation only: a failure here leaves Orbit Radio silent and
	-- MusicLoaded unset rather than costing the player a session.
	MusicService.SetupPlayer(player, data.Persistent or {})

	-- §7 skin inventory. The services normalize canonical Data first, then publish their
	-- projections. The daily login bonus is no longer auto-granted here — it's a claim-based
	-- reward in the Lucky Spin → Daily tab (DailyRewardService), gated on canonical
	-- LoginStreak/LastLoginDay Data projected by createPersistentAttributes.
	local skinsReady = WheelService.SetupPlayer(player)
	if not unlockedBuildingsReady then
		abortSetup(player, "unlocked buildings")
		return
	end
	if not skinsReady then
		abortSetup(player, "skin inventory")
		return
	end
	PlayerDataProjectionAudit.MarkDomain5ProjectionReady(player)

	startPlaytimeClock(player)
	CookieService.StartStealProtectionTimer(player)

	SheetService.AssignSheet(player)
	FloorService.SetupPlayer(player)
	StoryService.SetupPlayer(player)
	local liveData = PlayerDataService.GetDomain7Data(player)
	local liveRun = type(liveData) == "table" and liveData.Run
	local upgradesReady = liveRun and UpgradeService.SetupPlayer(
		player,
		type(liveRun.Placements) == "table" and liveRun.Placements or { [DEFAULT_DIMENSION] = {} }
	)
	-- Owned gear restoration can yield. Do not continue setup or record CpS against an ended
	-- profile after that wait; later-domain projections remain otherwise unchanged. Leaving
	-- during that yield is ordinary, so it stays a silent return rather than an abort.
	if player.Parent ~= Players then
		return
	end
	if not upgradesReady or not PlayerDataService.GetDomain7Data(player) then
		abortSetup(player, "upgrade restore")
		return
	end
	if not PlayerDataService.MarkPlacementSerializationReady(player) then
		abortSetup(player, "placement serialization")
		return
	end
	if not QuestService.SetupPlayer(player) then
		abortSetup(player, "quests")
		return
	end
	ShieldService.SetupPlayer(player)

	-- §9 offline earnings: run after buildings are placed so GetCps sees them, and after
	-- LastSeenTimestamp is restored. UpgradeService.SetupPlayer can yield while restoring gear,
	-- so OfflineEarningsService re-checks the live profile before reading the PRIOR canonical
	-- timestamp, calculating earnings, and stamping the current value.
	ProductionService.RefreshCps(player)
	OfflineEarningsService.OnPlayerSetup(player)

	-- §12.6: frozen boost fields resume only AFTER the offline claim above. Away-time is paid
	-- against a live CpS snapshot, and a field restored first would be counted in it -- paying for
	-- a boost that was frozen the whole time the player was gone.
	BoostFieldService.RestoreFields(player)
	ProductionService.RefreshCps(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.1)
		UpgradeService.ApplyPlayerCharacterStats(player, character)
		SheetService.TeleportToSheet(player, character)
	end)

	if player.Character then
		UpgradeService.ApplyPlayerCharacterStats(player, player.Character)
		SheetService.TeleportToSheet(player, player.Character)
	end

	-- Developer-product receipts fail closed until every owning gameplay domain has completed
	-- setup. ProcessReceipt may be installed while a join is still yielding through this function.
	PlayerDataService.MarkReceiptProcessingReady(player)
end

-- Client-driven "don't show the Build View nudge again" toggle. Profile.Data is canonical;
-- the attribute is its client-facing projection. One-way (only ever disables) so a stray
-- client can never re-enable nagging, and idempotent so re-sends are harmless.
local function setupRemotes()
	Net.on(Net.Names.DisableBuildViewNudge, function(player)
		local data = PlayerDataService.Get(player)
		local persistent = type(data) == "table" and data.Persistent
		if type(persistent) ~= "table" then
			return
		end

		persistent.BuildViewNudgeDisabled = true
		player:SetAttribute(Attrs.BuildViewNudgeDisabled, persistent.BuildViewNudgeDisabled)
	end)

	-- Legacy fallback for a non-story intro completion. The active Chapter 1 path advances
	-- through StoryAction("RubbleCleared") instead. Never allow this fallback to construct
	-- IntroSeen=true while the persisted story step is still Meteor.
	Net.on(Net.Names.MarkIntroSeen, function(player)
		StoryService.MarkIntroSeen(player)
	end)
end

function PlayerSetupService.Init()
	setupRemotes()

	Players.PlayerAdded:Connect(setupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		-- Spawned, not called: setupPlayer yields on the profile load, and every service Init
		-- after this one in Server.server.lua -- MonetizationService, which installs
		-- MarketplaceService.ProcessReceipt, among them -- would otherwise sit behind a
		-- DataStore round-trip for a player who was already in the server.
		task.spawn(setupPlayer, player)
	end

	print("PlayerSetupService initialized")
end

return PlayerSetupService
