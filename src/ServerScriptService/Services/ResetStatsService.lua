local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local FloorService = require(ServerScriptService.Services.FloorService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local Net = require(ReplicatedStorage.Shared.Net)

local ResetStatsService = {}

local lastResetAtByPlayer = {}
local RESET_COOLDOWN_SECONDS = 5
local STEAL_PROTECTION_SECONDS = 300

local function resetUpgradeCounts(player)
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return
	end

	for _, value in ipairs(upgradeCountData:GetChildren()) do
		if value:IsA("IntValue") then
			local config = UpgradeConfig[value.Name]
			value.Value = config and (config.InitialCount or 0) or 0
		end
	end
end

local function startStealProtectionTimer(player, canBeStolenFrom)
	task.delay(STEAL_PROTECTION_SECONDS, function()
		if player.Parent and canBeStolenFrom.Parent == player and not canBeStolenFrom.Value then
			canBeStolenFrom.Value = true
		end
	end)
end

function ResetStatsService.ResetPlayer(player)
	local now = os.clock()
	local lastResetAt = lastResetAtByPlayer[player]
	if lastResetAt and now - lastResetAt < RESET_COOLDOWN_SECONDS then
		return false
	end

	lastResetAtByPlayer[player] = now

	local run = PlayerDataService.ResetRun(player)

	CookieService.SetCookies(player, run and run.Cookies or 0)

	local canBeStolenFrom = player:FindFirstChild("CanBeStolenFrom")
	if canBeStolenFrom and canBeStolenFrom:IsA("BoolValue") then
		canBeStolenFrom.Value = run and run.CanBeStolenFrom or false
		startStealProtectionTimer(player, canBeStolenFrom)
	end

	ShieldService.SetTime(player, run and run.ShieldTime or 600)
	ShieldService.SetEnabled(player, true)
	resetUpgradeCounts(player)
	-- Floor ownership is Run progression: reset to Ground before buildings are
	-- resynchronized, destroying every Ground/floor placement with no relocation/refund.
	FloorService.ResetPlayer(player)
	-- Relock all buildings (store silhouettes return). Cleared before SyncPlayerUpgrades
	-- so its backfill — which only re-marks still-owned buildings — leaves it empty.
	UpgradeService.ClearUnlockedBuildings(player)
	CookieService.RefreshCookiesPerClickDisplay(player)
	UpgradeService.SyncPlayerUpgrades(player)
	PlayerDataService.UpdateFromPlayerValues(player)

	return true
end

function ResetStatsService.Init()
	Net.on(Net.Names.ResetStats, function(player)
		ResetStatsService.ResetPlayer(player)
	end)

	print("ResetStatsService initialized")
end

return ResetStatsService
