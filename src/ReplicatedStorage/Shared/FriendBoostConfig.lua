-- Friend Boost numbers. The mechanic itself lives in ServerScriptService.Services.FriendBoostService.
--
-- A player earns this bonus for every friend who is in the server BECAUSE of them -- an accepted
-- invite link or a profile follow-join -- for exactly as long as that friend stays. It is a
-- presence bonus, not an entitlement: nothing about it is persisted or claimable later.

local FriendBoostConfig = {}

FriendBoostConfig.PercentPerFriend = 10
FriendBoostConfig.MaxFriends = 5

-- The bounds the FriendBoost DevTuning registry declares for the two values above, and therefore
-- the largest multiplier this feature can legitimately reach while it is being tuned. Production
-- clamps to the derived ceiling, so these must not sit below what the registry allows or live
-- tuning would be silently neutered (the same relationship WheelConfig has with skin multipliers).
FriendBoostConfig.MaxPercentPerFriend = 50
FriendBoostConfig.MaxFriendCap = 20

-- Friends add rather than compound: five friends is a flat +50%, not 1.10^5. Compounding would
-- make the last friend worth more than the first, which is backwards -- the hard part of this
-- feature is getting the FIRST person to come.
function FriendBoostConfig.ComputeMultiplier(percentPerFriend, maxFriends, friendCount)
	percentPerFriend = math.clamp(tonumber(percentPerFriend) or 0, 0, FriendBoostConfig.MaxPercentPerFriend)
	maxFriends = math.clamp(math.floor(tonumber(maxFriends) or 0), 0, FriendBoostConfig.MaxFriendCap)
	friendCount = math.max(0, math.floor(tonumber(friendCount) or 0))

	return 1 + (percentPerFriend / 100) * math.min(friendCount, maxFriends)
end

-- Defensive ceiling for production math: a Player attribute is the transport for this value, so
-- clamping to the highest reachable multiplier keeps a bad or stale attribute from inflating pay.
function FriendBoostConfig.CeilingMultiplier()
	return 1 + (FriendBoostConfig.MaxPercentPerFriend / 100) * FriendBoostConfig.MaxFriendCap
end

-- How many friends the count above is actually paying for, for HUD copy that would otherwise
-- claim credit for friends past the cap.
function FriendBoostConfig.CountedFriends(maxFriends, friendCount)
	maxFriends = math.clamp(math.floor(tonumber(maxFriends) or 0), 0, FriendBoostConfig.MaxFriendCap)
	return math.min(math.max(0, math.floor(tonumber(friendCount) or 0)), maxFriends)
end

return FriendBoostConfig
