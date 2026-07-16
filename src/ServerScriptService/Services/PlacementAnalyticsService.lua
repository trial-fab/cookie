-- PlacementAnalyticsService: server-only custom analytics for adoption of the fixed placement
-- controls. The client may report only a small allowlisted action/source pair, and reports are
-- rate-limited before reaching AnalyticsService so exploit traffic cannot flood the event budget.
local AnalyticsService = game:GetService("AnalyticsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net)

local PlacementAnalyticsService = {}

local VALID_ACTIONS = {
	Cancel = true,
	Rotate = true,
	Confirm = true,
	Finish = true,
}
local VALID_SOURCES = {
	Screen = true,
	Keyboard = true,
}
local WINDOW_SECONDS = 10
local MAX_REPORTS_PER_WINDOW = 30
local rateByPlayer = {}

local function acceptReport(player)
	local now = os.clock()
	local rate = rateByPlayer[player]
	if not rate or now - rate.startedAt >= WINDOW_SECONDS then
		rate = { startedAt = now, count = 0 }
		rateByPlayer[player] = rate
	end
	if rate.count >= MAX_REPORTS_PER_WINDOW then
		return false
	end
	rate.count += 1
	return true
end

function PlacementAnalyticsService.Init()
	Net.on(Net.Names.PlacementControlUsed, function(player, action, source)
		if not VALID_ACTIONS[action] or not VALID_SOURCES[source] or not acceptReport(player) then
			return
		end
		if RunService:IsStudio() then
			return
		end
		local ok, analyticsError = pcall(function()
			AnalyticsService:LogCustomEvent(player, "PlacementControlUsed", 1, {
				Action = action,
				Input = source,
			})
		end)
		if not ok then
			warn("Placement analytics failed: " .. tostring(analyticsError))
		end
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		rateByPlayer[player] = nil
	end)
end

return PlacementAnalyticsService
