-- Server-authored analytics for the one-time autoclick onboarding gate.
local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local AutoclickerAnalyticsService = {}

function AutoclickerAnalyticsService.RecordUnlocked(player, cost)
	if RunService:IsStudio() then
		return
	end

	local ok, analyticsError = pcall(function()
		AnalyticsService:LogCustomEvent(player, "AutoclickerUnlocked", 1, {
			Cost = tostring(math.max(0, tonumber(cost) or 0)),
		})
	end)
	if not ok then
		warn("Autoclicker analytics failed: " .. tostring(analyticsError))
	end
end

function AutoclickerAnalyticsService.Init() end

return AutoclickerAnalyticsService
