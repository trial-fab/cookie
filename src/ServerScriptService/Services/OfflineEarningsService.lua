-- OfflineEarningsService — the day-1 → day-2 retention hook (spec §9).
--
-- On rejoin a player is granted 50% of their CpS for the time they were away,
-- capped at 8h (extended to 12h/24h by the §4c "Offline Earnings" upgrades), and
-- shown a "While you were away…" claim popup. The cookies are granted server-side
-- via CookieService; the popup is purely informational (a Phase 7 "double your
-- away earnings" booster can later attach to it).
--
-- LastSeenTimestamp bookkeeping (the load-bearing detail): Profile.Data.Persistent owns the
-- timestamp, and PlayerSetupService projects its prior-session value before this service runs.
-- OnPlayerSetup reads the PRIOR canonical value once, calculates/grants offline earnings, then
-- stamps the current time into Data and projects it. The short loop and leave path keep Data
-- fresh for saves. Stamping is gated behind `processedByPlayer` so the loop can never overwrite
-- the prior value before OnPlayerSetup has read it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local ProductionService = require(ServerScriptService.Services.ProductionService)
local UpgradeService = require(ServerScriptService.Services.UpgradeService)
local Net = require(ReplicatedStorage.Shared.Net)

local OfflineEarningsService = {}

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
	return PlayerDataService.SetLastSeenTimestamp(player, os.time())
end

-- Called from PlayerSetupService.setupPlayer AFTER UpgradeService.SetupPlayer (so
-- placed buildings already count toward GetCps) and after the persistent
-- attributes are restored. Returns a summary table for callers/tests.
function OfflineEarningsService.OnPlayerSetup(player)
	-- UpgradeService.SetupPlayer can yield while restoring owned gear. Re-fetch canonical Data
	-- here so a player who left during that wait cannot receive earnings or mutate an ended
	-- profile. Read the PRIOR timestamp before anything advances it.
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	if player.Parent ~= Players or type(persistent) ~= "table" then
		return { Amount = 0, AwaySeconds = 0, Capped = false, Cps = 0, Reason = "NotReady" }
	end
	local lastSeen = tonumber(persistent.LastSeenTimestamp)
	lastSeen = lastSeen and math.floor(lastSeen) or 0

	local now = os.time()
	local cps = ProductionService.GetCps(player)
	local result = { Amount = 0, AwaySeconds = 0, Capped = false, Cps = cps }

	if lastSeen > 0 and now > lastSeen then
		local capSeconds = getOfflineCapSeconds(player)
		local rawAway = now - lastSeen
		local awaySeconds = math.min(rawAway, capSeconds)
		local earned = math.floor(cps * OFFLINE_RATE * awaySeconds)

		if earned > 0 and awaySeconds >= MIN_AWAY_SECONDS then
			CookieService.AddCookies(player, earned, PlayerMetricsService.CookieSources.Offline)
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
	if not stamp(player) then
		processedByPlayer[player] = nil
	end
	return result
end

local function startStampLoop()
	task.spawn(function()
		while true do
			task.wait(STAMP_INTERVAL_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				if processedByPlayer[player] then
					-- The interval wait yielded; SetLastSeenTimestamp re-checks the live profile.
					if not stamp(player) then
						processedByPlayer[player] = nil
					end
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
