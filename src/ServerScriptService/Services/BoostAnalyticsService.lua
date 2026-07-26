-- Server-authored analytics for the central boost shop (roadmap decision 6: metrics ship with the
-- feature they measure).
--
-- The loop this has to answer questions about is: gems -> charge -> field -> production. So each
-- event carries what the NEXT decision depends on:
--
--   BoostPurchased  did the price land? (gems left after paying tells us whether 40 is a real
--                   choice or the player's whole balance)
--   BoostDropped    is the field being used well? Coverage is the decision the player makes, and a
--                   drop covering 0 buildings is a wasted 40 gems worth knowing about. Gifted
--                   separates the social case, which is the whole reason any-plot exists.
--   BoostExpired    did they get the value? A field that expires while its owner is away is time
--                   they paid for and did not spend.
--
-- Follows the same shape as the other *AnalyticsService modules: Studio is skipped so test sessions
-- do not pollute real data, and every call is pcall-wrapped because analytics must never be able to
-- fail a purchase or a drop.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local BoostAnalyticsService = {}

local function log(player, name, value, fields)
	if RunService:IsStudio() then
		return
	end

	local ok, analyticsError = pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value, fields)
	end)
	if not ok then
		warn("Boost analytics failed: " .. tostring(analyticsError))
	end
end

function BoostAnalyticsService.RecordPurchased(player, itemId, priceGems, gemsRemaining)
	log(player, "BoostPurchased", 1, {
		Item = tostring(itemId),
		PriceGems = tostring(math.max(0, tonumber(priceGems) or 0)),
		GemsRemaining = tostring(math.max(0, tonumber(gemsRemaining) or 0)),
	})
end

-- `coveredBuildings` is the count the field actually landed on, which is the quality of the drop.
function BoostAnalyticsService.RecordDropped(player, itemId, coveredBuildings, floorId, gifted)
	log(player, "BoostDropped", math.max(0, tonumber(coveredBuildings) or 0), {
		Item = tostring(itemId),
		Floor = tostring(floorId),
		-- A gifted field is the social case the any-plot rule exists for; splitting it out is the
		-- only way to tell whether that rule earns its keep.
		Gifted = gifted and "Yes" or "No",
	})
end

-- Fires when a field runs its countdown to zero. `secondsUnused` is non-zero only when the field
-- was destroyed before expiring, which is value the player bought and never received.
function BoostAnalyticsService.RecordExpired(player, itemId, durationSeconds)
	log(player, "BoostExpired", math.max(0, tonumber(durationSeconds) or 0), {
		Item = tostring(itemId),
	})
end

function BoostAnalyticsService.Init() end

return BoostAnalyticsService
