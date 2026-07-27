-- DailyRewardService — the claim-based daily login streak (Lucky Spin → Daily tab).
--
-- Replaces the old silent login bonus that lived in GoldenCookieService.OnPlayerSetup: the
-- player now claims their reward in the Daily tab instead of it being auto-granted at join.
-- Gating is once per UTC day. The counter advances on every claimed day and never resets: it is
-- "days you came back", presented as a streak. A strict consecutive-day rule punished the UTC
-- boundary itself -- reset lands mid-afternoon in the Americas, so two consecutive *local* days
-- can skip a UTC day and wipe real progress -- and returning after a break should pick up where
-- you left off rather than restart the cycle.
-- Rewards (GC per day, plus the Mythical Celestial goo skin on the final cycle day) come from the
-- shared DailyRewardConfig so client and server agree.
--
-- Profile.Data.Persistent owns LoginStreak / LastLoginDay. Player attributes are replication
-- projections used by the Wheel and Profile controllers, never server decision inputs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local DailyRewardConfig = require(ReplicatedStorage.Shared.DailyRewardConfig)
local GoldenCookieService = require(script.Parent.GoldenCookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)
local WheelService = require(script.Parent.WheelService)

local DailyRewardService = {}

local function currentUtcDay()
	return math.floor(os.time() / 86400)
end

local function getPersistent(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function readInt(persistent, field)
	local value = tonumber(persistent[field])
	return value and math.floor(value) or 0
end

-- Read-only snapshot for the client to render (it can also derive this from the attributes).
function DailyRewardService.GetState(player)
	local persistent = getPersistent(player)
	if not persistent then
		return {
			CanClaim = false,
			Streak = 0,
			PendingStreak = 1,
			DayInCycle = DailyRewardConfig.GetDayInCycle(1),
			LastClaimDay = 0,
			Reason = "NotReady",
		}
	end

	local today = currentUtcDay()
	local lastDay = readInt(persistent, "LastLoginDay")
	local streak = readInt(persistent, "LoginStreak")
	-- The day they'd be ON if they claimed right now (drives the highlighted card). Any unclaimed
	-- day advances the counter, however long the gap was.
	local pendingStreak
	if lastDay == today then
		pendingStreak = math.max(1, streak)
	else
		pendingStreak = streak + 1
	end

	return {
		CanClaim = lastDay ~= today,
		Streak = streak,
		PendingStreak = pendingStreak,
		DayInCycle = DailyRewardConfig.GetDayInCycle(pendingStreak),
		LastClaimDay = lastDay,
	}
end

-- Claims today's reward. Atomic: nothing here yields, so the once-per-day gate and the
-- streak/attribute writes commit together — a double-invoke can't double-claim. Returns a
-- result table (also the RemoteFunction reply to the caller).
function DailyRewardService.Claim(player)
	local persistent = getPersistent(player)
	if not persistent then
		-- The remote is registered before PlayerSetupService finishes loading profiles. Fail
		-- closed so an early invoke cannot claim against zero-like missing projections and then
		-- have setup overwrite the claim, allowing a second reward.
		return { Success = false, Reason = "NotReady" }
	end

	local today = currentUtcDay()
	local lastDay = readInt(persistent, "LastLoginDay")
	local streak = readInt(persistent, "LoginStreak")

	if lastDay == today then
		return {
			Success = false,
			Reason = "AlreadyClaimed",
			Streak = streak,
			DayInCycle = DailyRewardConfig.GetDayInCycle(math.max(1, streak)),
		}
	end

	-- Never resets. A gap of one day or one month both advance by one, so the cycle resumes where
	-- the player left it instead of throwing away everything they had already earned.
	local newStreak = math.max(0, streak) + 1

	local reward = DailyRewardConfig.GetReward(newStreak)
	if type(reward) ~= "table" then
		return { Success = false, Reason = "NoReward" }
	end

	local gc = math.max(0, math.floor(tonumber(reward.Gc) or 0))
	if gc > 0 then
		GoldenCookieService.AddGoldenCookies(player, gc, "daily", { Kind = "Ui", Key = "DailyClaim" })
	end

	local skinGranted = false
	if reward.SkinId then
		skinGranted = WheelService.GrantSkin(player, reward.SkinId)
	end

	-- SECURITY/DATA-INTEGRITY INVARIANT: everything from the live-profile read above through
	-- reward grants, these canonical writes, their projections, and metric recording must remain
	-- yield-free. GC, streak, skins, and BestLoginStreak are all canonical Data.
	-- If any operation here starts yielding (for example, a future badge award), re-check the
	-- live profile after the yield and redesign the mixed-domain transaction before mutating Data.
	persistent.LoginStreak = newStreak
	persistent.LastLoginDay = today
	player:SetAttribute(Attrs.LoginStreak, persistent.LoginStreak)
	player:SetAttribute(Attrs.LastLoginDay, persistent.LastLoginDay)
	PlayerMetricsService.RecordLoginStreak(player, newStreak)

	return {
		Success = true,
		RewardGC = gc,
		SkinId = reward.SkinId,
		SkinGranted = skinGranted,
		Streak = newStreak,
		DayInCycle = DailyRewardConfig.GetDayInCycle(newStreak),
	}
end

function DailyRewardService.Init()
	Net.onInvoke(Net.Names.ClaimDailyReward, function(player)
		return DailyRewardService.Claim(player)
	end)

	print("DailyRewardService initialized")
end

return DailyRewardService
