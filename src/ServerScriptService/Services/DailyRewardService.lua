-- DailyRewardService — the claim-based daily login streak (Lucky Spin → Daily tab).
--
-- Replaces the old silent login bonus that lived in GoldenCookieService.OnPlayerSetup: the
-- player now claims their reward in the Daily tab instead of it being auto-granted at join.
-- Gating is once per UTC day; consecutive days grow the streak, a missed day resets it.
-- Rewards (GC per day, plus a Mythical building skin on the final cycle day) come from the
-- shared DailyRewardConfig so client and server agree.
--
-- Persistence is free: the LoginStreak / LastLoginDay attributes this reads and writes are
-- already in PlayerDataService's persistent partition and seeded by PlayerSetupService's
-- createPersistentAttributes, so nothing extra needs saving.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local DailyRewardConfig = require(ReplicatedStorage.Shared.DailyRewardConfig)
local GoldenCookieService = require(script.Parent.GoldenCookieService)
local WheelService = require(script.Parent.WheelService)

local DailyRewardService = {}

local function currentUtcDay()
	return math.floor(os.time() / 86400)
end

local function readInt(player, attr)
	local value = player:GetAttribute(attr)
	return typeof(value) == "number" and math.floor(value) or 0
end

-- Read-only snapshot for the client to render (it can also derive this from the attributes).
function DailyRewardService.GetState(player)
	local today = currentUtcDay()
	local lastDay = readInt(player, Attrs.LastLoginDay)
	local streak = readInt(player, Attrs.LoginStreak)
	-- The day they'd be ON if they claimed right now (drives the highlighted card).
	local pendingStreak
	if lastDay == today then
		pendingStreak = math.max(1, streak)
	elseif lastDay == today - 1 then
		pendingStreak = streak + 1
	else
		pendingStreak = 1
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
	local today = currentUtcDay()
	local lastDay = readInt(player, Attrs.LastLoginDay)
	local streak = readInt(player, Attrs.LoginStreak)

	if lastDay == today then
		return {
			Success = false,
			Reason = "AlreadyClaimed",
			Streak = streak,
			DayInCycle = DailyRewardConfig.GetDayInCycle(math.max(1, streak)),
		}
	end

	local newStreak
	if lastDay == today - 1 then
		newStreak = streak + 1
	else
		newStreak = 1
	end

	local reward = DailyRewardConfig.GetReward(newStreak)
	if type(reward) ~= "table" then
		return { Success = false, Reason = "NoReward" }
	end

	local gc = math.max(0, math.floor(tonumber(reward.Gc) or 0))
	if gc > 0 then
		GoldenCookieService.AddGoldenCookies(player, gc, "daily")
	end

	local skinGranted = false
	if reward.SkinId then
		skinGranted = WheelService.GrantSkin(player, reward.SkinId)
	end

	player:SetAttribute(Attrs.LoginStreak, newStreak)
	player:SetAttribute(Attrs.LastLoginDay, today)

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
