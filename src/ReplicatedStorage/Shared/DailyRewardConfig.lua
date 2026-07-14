-- DailyRewardConfig — the once-per-UTC-day login streak rewards (Lucky Spin → Daily tab).
--
-- Replaces the old silent login bonus (was in GoldenCookieService.OnPlayerSetup). Rewards
-- are claimed in-tab now, not auto-granted. Rewards are golden cookies per day (GC is the
-- playtime currency — invariant 1; cookies are intentionally NOT awarded here, they would
-- bend the production curve and need sim validation). The final day of the cycle also grants
-- the Mythical Celestial goo skin — the week-streak payoff.
--
-- This module is shared so the client renders exactly the cycle the server (DailyRewardService)
-- awards. Values are a tunable design knob — adjust freely; the gating/streak logic is in
-- DailyRewardService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)

local DailyRewardConfig = {}

DailyRewardConfig.CycleLength = 7

-- One entry per day of the streak cycle. `Gc` = golden cookies awarded that day. The final
-- day additionally grants the Mythical goo skin via `SkinId`.
DailyRewardConfig.Cycle = {
	{ Gc = 10 },
	{ Gc = 12 },
	{ Gc = 15 },
	{ Gc = 18 },
	{ Gc = 22 },
	{ Gc = 26 },
	{ Gc = 30, SkinId = GooSkinConfig.DailySkinId },
}

-- A streak number maps to a 1..CycleLength slot. After a full week the cycle repeats from day
-- 1 while the underlying streak keeps climbing, so day 7 (the mythical) recurs every 7 days.
function DailyRewardConfig.GetDayInCycle(streak)
	streak = math.max(1, math.floor(tonumber(streak) or 1))
	return ((streak - 1) % DailyRewardConfig.CycleLength) + 1
end

-- Reward for the day being claimed (pass the streak AFTER incrementing).
function DailyRewardConfig.GetReward(streak)
	return DailyRewardConfig.Cycle[DailyRewardConfig.GetDayInCycle(streak)]
end

return DailyRewardConfig
