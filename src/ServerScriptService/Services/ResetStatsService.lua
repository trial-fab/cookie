local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local FloorService = require(ServerScriptService.Services.FloorService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local Net = require(ReplicatedStorage.Shared.Net)

local ResetStatsService = {}

local lastResetAtByPlayer = {}
local RESET_COOLDOWN_SECONDS = 5

function ResetStatsService.ResetPlayer(player)
	if not PlayerDataService.GetDomain7Data(player) or not UpgradeService.IsUnlockedBuildingsReady(player) then
		return false
	end

	local now = os.clock()
	local lastResetAt = lastResetAtByPlayer[player]
	if lastResetAt and now - lastResetAt < RESET_COOLDOWN_SECONDS then
		return false
	end

	lastResetAtByPlayer[player] = now

	local run = PlayerDataService.ResetRun(player)
	if not run then
		return false
	end

	-- ResetRun has already installed and projected the complete new canonical Run without
	-- yielding. Invalidate any pre-reset protection timer so it cannot mutate this new Run early.
	CookieService.StartStealProtectionTimer(player)
	ShieldService.SetEnabled(player, true)
	-- Floor ownership is Run progression: reset to Ground before buildings are
	-- resynchronized, destroying every Ground/floor placement with no relocation/refund.
	FloorService.ResetPlayer(player)
	-- Relock all buildings (store silhouettes return). Cleared before SyncPlayerUpgrades
	-- so its backfill — which only re-marks still-owned buildings — leaves it empty.
	UpgradeService.ClearUnlockedBuildings(player)
	CookieService.RefreshCookiesPerClickDisplay(player)
	if not UpgradeService.SyncPlayerUpgrades(player) then
		return false
	end
	if not PlayerDataService.MarkPlacementSerializationReady(player) then
		return false
	end
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
