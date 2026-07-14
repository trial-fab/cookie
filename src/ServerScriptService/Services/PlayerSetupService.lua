local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local SheetService = require(ServerScriptService.Services.SheetService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local WheelService = require(ServerScriptService.Services.WheelService)
local ProductionService = require(ServerScriptService.Services.ProductionService)
local OfflineEarningsService = require(ServerScriptService.Services.OfflineEarningsService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local StoryService = require(ServerScriptService.Services.StoryService)
local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)

local PlayerSetupService = {}
local STEAL_PROTECTION_SECONDS = 300
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
	player:SetAttribute(Attrs.Xp, tonumber(persistent.Xp) or 0)
	player:SetAttribute(Attrs.GoldenCookies, tonumber(persistent.GoldenCookies) or 0)
	player:SetAttribute(Attrs.LoginStreak, tonumber(persistent.LoginStreak) or 0)
	player:SetAttribute(Attrs.LastLoginDay, tonumber(persistent.LastLoginDay) or 0)
	player:SetAttribute(Attrs.LastSeenTimestamp, tonumber(persistent.LastSeenTimestamp) or 0)
	player:SetAttribute(Attrs.OwnedSkinsJson, encodeJson(persistent.OwnedSkins))
	player:SetAttribute(Attrs.EquippedSkinsJson, encodeJson(persistent.EquippedSkins))
	player:SetAttribute(Attrs.AchievementsJson, encodeJson(persistent.Achievements))
	player:SetAttribute(Attrs.UnlockedBuildingsJson, encodeJson(persistent.UnlockedBuildings))
	player:SetAttribute(Attrs.BuildViewNudgeDisabled, persistent.BuildViewNudgeDisabled == true)
	player:SetAttribute(Attrs.IntroSeen, persistent.IntroSeen == true)
	player:SetAttribute(Attrs.StoryChapter, persistent.StoryChapter or "GooArrival")
	player:SetAttribute(Attrs.StoryStep, persistent.StoryStep or "Meteor")
	player:SetAttribute(Attrs.StoryHealingClicks, tonumber(persistent.StoryHealingClicks) or 0)
	player:SetAttribute(Attrs.MixerUnlocked, persistent.MixerUnlocked == true)
end

local function createPlayerValues(player, data)
	local run = data.Run or data
	local persistent = data.Persistent or {}

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	createValue("NumberValue", "Cookies", run.Cookies or 0, leaderstats)
	createValue("StringValue", "Play Time", "00:00", leaderstats)

	createValue("IntValue", "RealPlayTime", persistent.RealPlayTime or 0, player)
	createValue("BoolValue", "CanBeStolenFrom", run.CanBeStolenFrom or false, player)
	createValue("IntValue", "ShieldTime", run.ShieldTime or 600, player)

	local upgradeCountData = Instance.new("Configuration")
	upgradeCountData.Name = "UpgradeCountData"
	upgradeCountData.Parent = player

	if type(run.UpgradeCounts) == "table" then
		for upgradeName, count in pairs(run.UpgradeCounts) do
			createValue("IntValue", tostring(upgradeName), tonumber(count) or 0, upgradeCountData)
		end
	end

	createValue("IntValue", "CookiesGainedPerClick", CookieService.GetCookiesPerClick(player), player)
	createPersistentAttributes(player, persistent)
end

local function startPlaytimeClock(player)
	local realPlayTime = player:WaitForChild("RealPlayTime")
	local playTime = player:WaitForChild("leaderstats"):WaitForChild("Play Time")
	local sessionSeconds = 0

	task.spawn(function()
		while player.Parent do
			task.wait(1)

			realPlayTime.Value += 1
			sessionSeconds += 1
			PlayerMetricsService.RecordSessionDuration(player, sessionSeconds)

			local totalSeconds = realPlayTime.Value
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

local function startStealProtectionTimer(player)
	local canBeStolenFrom = player:FindFirstChild("CanBeStolenFrom")
	if not canBeStolenFrom or not canBeStolenFrom:IsA("BoolValue") or canBeStolenFrom.Value then
		return
	end

	task.delay(STEAL_PROTECTION_SECONDS, function()
		if player.Parent and canBeStolenFrom.Parent == player and not canBeStolenFrom.Value then
			canBeStolenFrom.Value = true
		end
	end)
end

local function setupPlayer(player)
	print("Setting up player:", player.Name)

	local data = PlayerDataService.Load(player)
	local run = data.Run or data

	createPlayerValues(player, data)
	PlayerMetricsService.SetupPlayer(player, data.Persistent or {}, run)

	-- §7 skin inventory. Runs after createPlayerValues so the skin attributes already
	-- exist. The daily login bonus is no longer auto-granted here — it's a claim-based
	-- reward in the Lucky Spin → Daily tab (DailyRewardService), gated on the
	-- LoginStreak/LastLoginDay attributes that createPersistentAttributes seeded.
	WheelService.SetupPlayer(player, data.Persistent or {})

	startPlaytimeClock(player)
	startStealProtectionTimer(player)

	SheetService.AssignSheet(player)
	StoryService.SetupPlayer(player)
	UpgradeService.SetupPlayer(
		player,
		type(run.Placements) == "table" and run.Placements or { [DEFAULT_DIMENSION] = {} }
	)
	ShieldService.SetupPlayer(player)

	-- §9 offline earnings: run after buildings are placed (UpgradeService.SetupPlayer
	-- is synchronous) so GetCps sees them, and after the persistent LastSeenTimestamp
	-- attribute is restored so we read the PRIOR session's value before stamping.
	ProductionService.RefreshCps(player)
	OfflineEarningsService.OnPlayerSetup(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.1)
		UpgradeService.ApplyPlayerCharacterStats(player, character)
		SheetService.TeleportToSheet(player, character)
	end)

	if player.Character then
		UpgradeService.ApplyPlayerCharacterStats(player, player.Character)
		SheetService.TeleportToSheet(player, player.Character)
	end
end

-- Client-driven "don't show the Build View nudge again" toggle. The attribute is the
-- single source of truth; PlayerDataService.UpdateFromPlayerValues reads it back so the
-- choice persists across sessions. One-way (only ever disables) so a stray client can
-- never re-enable nagging — and idempotent, so re-sends are harmless.
local function setupRemotes()
	Net.on(Net.Names.DisableBuildViewNudge, function(player)
		player:SetAttribute(Attrs.BuildViewNudgeDisabled, true)
	end)

	-- Client fires this once the first-time meteor cutscene finishes. One-way and idempotent
	-- (only ever sets true), mirroring DisableBuildViewNudge: a stray client can never un-see
	-- the intro, and re-sends are harmless. UpdateFromPlayerValues persists the attribute.
	Net.on(Net.Names.MarkIntroSeen, function(player)
		player:SetAttribute(Attrs.IntroSeen, true)
	end)
end

function PlayerSetupService.Init()
	setupRemotes()

	Players.PlayerAdded:Connect(setupPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	print("PlayerSetupService initialized")
end

return PlayerSetupService
