-- Server-authored analytics for the Friend Boost (roadmap decision 6: metrics ship with the
-- feature they measure).
--
-- The loop this has to answer questions about is: invite -> join -> boost. So the two events are
-- the two halves of it:
--
--   FriendJoinAttributed  did the invite actually convert? Split by Invite vs Follow, because
--                         those are two different funnels wearing one mechanic: the in-game
--                         envelope prompt versus someone finding the player on their profile.
--                         If Follow dominates, the invite UI is not the thing bringing players in.
--   FriendBoostChanged    is the reward real? A boost that never leaves +0% means attribution is
--                         failing somewhere; friend counts pinned at the cap mean the cap is low.
--
-- Follows the same shape as the other *AnalyticsService modules: Studio is skipped so test
-- sessions do not pollute real data, and every call is pcall-wrapped because analytics must never
-- be able to fail a join or a production tick.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local FriendBoostAnalyticsService = {}

local function log(player, name, value, fields)
	if RunService:IsStudio() then
		return
	end

	local ok, analyticsError = pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value, fields)
	end)
	if not ok then
		warn("Friend boost analytics failed: " .. tostring(analyticsError))
	end
end

-- Fires on the ARRIVING player, once, when their join is attributed to someone else.
function FriendBoostAnalyticsService.RecordJoinAttributed(player, source)
	log(player, "FriendJoinAttributed", 1, {
		Source = tostring(source),
	})
end

-- Fires on the boosted player whenever their multiplier actually changes, in either direction.
-- `friendCount` is the raw number of linked players present, so a value above the paid count is
-- exactly the signal that the cap is binding.
function FriendBoostAnalyticsService.RecordBoostChanged(player, friendCount, multiplier)
	local percent = math.floor(((tonumber(multiplier) or 1) - 1) * 100 + 0.5)
	log(player, "FriendBoostChanged", math.max(0, tonumber(friendCount) or 0), {
		Percent = tostring(math.max(0, percent)),
	})
end

function FriendBoostAnalyticsService.Init() end

return FriendBoostAnalyticsService
