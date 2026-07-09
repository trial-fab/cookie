-- OfflineEarningsService — the day-1 → day-2 retention hook (spec §9).
--
-- On rejoin a player is granted 50% of their CpS for the time they were away,
-- capped at 8h (extended to 12h/24h by the §4c "Offline Earnings" upgrades), and
-- shown a "While you were away…" claim popup. The cookies are granted server-side
-- via CookieService; the popup is purely informational (a Phase 7 "double your
-- away earnings" booster can later attach to it).
--
-- LastSeenTimestamp bookkeeping (the load-bearing detail): PlayerDataService
-- persists `LastSeenTimestamp`, restored onto the player as an attribute by
-- PlayerSetupService BEFORE this service runs — so on join the attribute still
-- holds the PRIOR session's leave time. We read that prior value once in
-- OnPlayerSetup, then begin stamping os.time() into it on a short loop (and on
-- leave) so the next save records when this session ended. Stamping is gated
-- behind `processedByPlayer` so a slow DataStore load can never let the loop
-- overwrite the prior value before OnPlayerSetup has read it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local ProductionService = require(ServerScriptService.Services.ProductionService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local Net = require(ReplicatedStorage.Shared.Net)

local OfflineEarningsService = {}

local LAST_SEEN_ATTRIBUTE = "LastSeenTimestamp"
local OFFLINE_RATE = 0.5 -- §9: 50% of CpS while away.
local BASE_CAP_HOURS = 8 -- §9 base cap; §4c "Offline Earnings" upgrades extend it.
local MIN_AWAY_SECONDS = 60 -- below this nothing meaningful baked; skip the popup.
local STAMP_INTERVAL_SECONDS = 10 -- keep the saved LastSeenTimestamp within this of "now".

local processedByPlayer = {}

-- Cap = base 8h + the §4c OfflineCapHours effects (4h then 12h → 8/12/24h total).
local function getOfflineCapSeconds(player)
	local extraHours = UpgradeService.GetEffectTotal(player, "OfflineCapHours") or 0
	return (BASE_CAP_HOURS + math.max(0, extraHours)) * 3600
end

local function stamp(player)
	player:SetAttribute(LAST_SEEN_ATTRIBUTE, os.time())
end

-- Called from PlayerSetupService.setupPlayer AFTER UpgradeService.SetupPlayer (so
-- placed buildings already count toward GetCps) and after the persistent
-- attributes are restored. Returns a summary table for callers/tests.
function OfflineEarningsService.OnPlayerSetup(player)
	-- Read the PRIOR timestamp before anything advances it.
	local lastSeen = player:GetAttribute(LAST_SEEN_ATTRIBUTE)
	lastSeen = typeof(lastSeen) == "number" and math.floor(lastSeen) or 0

	local now = os.time()
	local cps = ProductionService.GetCps(player)
	local result = { Amount = 0, AwaySeconds = 0, Capped = false, Cps = cps }

	if lastSeen > 0 and now > lastSeen then
		local capSeconds = getOfflineCapSeconds(player)
		local rawAway = now - lastSeen
		local awaySeconds = math.min(rawAway, capSeconds)
		local earned = math.floor(cps * OFFLINE_RATE * awaySeconds)

		if earned > 0 and awaySeconds >= MIN_AWAY_SECONDS then
			CookieService.AddCookies(player, earned)
			result.Amount = earned
			result.AwaySeconds = awaySeconds
			result.Capped = rawAway > capSeconds

			Net.fireClient(Net.Names.OfflineEarningsClaim, player, {
				Amount = earned,
				AwaySeconds = awaySeconds,
				Capped = result.Capped,
				CapHours = capSeconds / 3600,
				Cps = cps,
			})
		end
	end

	-- This player is now live: advance the stamp and let the loop keep it fresh.
	processedByPlayer[player] = true
	stamp(player)
	return result
end

local function startStampLoop()
	task.spawn(function()
		while true do
			task.wait(STAMP_INTERVAL_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				if processedByPlayer[player] then
					stamp(player)
				end
			end
		end
	end)
end

function OfflineEarningsService.Init()
	-- Pre-create the server->client push channel so a client that boots first finds it
	-- immediately instead of hanging at WaitForChild until the first claim fires.
	Net.event(Net.Names.OfflineEarningsClaim)

	Players.PlayerRemoving:Connect(function(player)
		if processedByPlayer[player] then
			-- Final mark so the forced leave-save persists ~now as last-seen.
			stamp(player)
		end
		processedByPlayer[player] = nil
	end)

	startStampLoop()
	print("OfflineEarningsService initialized")
end

return OfflineEarningsService
