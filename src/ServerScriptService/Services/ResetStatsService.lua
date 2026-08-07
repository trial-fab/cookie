local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BoostFieldService = require(ServerScriptService.Services.BoostFieldService)
local BoostShopService = require(ServerScriptService.Services.BoostShopService)
local CookieService = require(ServerScriptService.Services.CookieService)
local FloorService = require(ServerScriptService.Services.FloorService)
local GemService = require(ServerScriptService.Services.GemService)
local GooSkinService = require(ServerScriptService.Services.GooSkinService)
local MusicService = require(ServerScriptService.Services.MusicService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local QuestService = require(ServerScriptService.Services.QuestService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local StoryService = require(ServerScriptService.Services.StoryService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local GooSkinConfig = require(game:GetService("ReplicatedStorage").Shared.GooSkinConfig)

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
	-- Decision 16's approved exception: Orbit Radio's library survives the wipe
	-- untouched (it lives in Persistent, which ResetRun never replaces). Only the
	-- current-run grants narrow back to Ground, so this is a republish, not a reset.
	MusicService.OnRunReset(player)

	return true
end

function ResetStatsService.ResetOnboardingForDevelopment(player)
	if
		not (RunService:IsStudio() or player.UserId == game.CreatorId)
		or not PlayerDataService.GetDomain7Data(player)
		or not UpgradeService.IsUnlockedBuildingsReady(player)
	then
		return false
	end

	-- These canonical persistent mutations are grouped without yielding. World/projection
	-- resynchronization happens afterward through the existing run-reset path.
	if
		not StoryService.ResetForDevelopment(player)
		or GemService.SetGems(player, 0) == nil
		-- Charges bought with those test gems go with them, so a dev reset returns the player to
		-- a clean pre-purchase state instead of leaving stock behind. Fields already dropped go
		-- too, or the reset leaves a boost running that nothing in the profile paid for.
		or not BoostShopService.ClearCharges(player)
		or not BoostFieldService.ClearFields(player)
	then
		return false
	end
	-- The opening capstone is earned progression, not a paid entitlement.
	GooSkinService.RevokeEarnedSkinForDevelopment(player, GooSkinConfig.OpeningQuestSkinId)
	-- Unlike a rebirth, a dev reset rewinds the story timeline itself, so the
	-- encounters that revealed the intro and milestone music have to go with it or
	-- those cues can never be earned again in this profile.
	MusicService.ResetForDevelopment(player)
	if not ResetStatsService.ResetPlayer(player) then
		return false
	end
	-- Reconcile only after story/run/currency/charges are clean, otherwise a quest
	-- reset would immediately backfill from the pre-reset canonical state.
	return QuestService.ResetForDevelopment(player)
end

function ResetStatsService.Init()
	print("ResetStatsService initialized (public reset disabled)")
end

return ResetStatsService
