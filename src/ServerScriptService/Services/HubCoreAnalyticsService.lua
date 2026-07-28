-- Server-authored adoption event for the one-time Ancient Core cookie sink.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local HubCoreAnalyticsService = {}

function HubCoreAnalyticsService.RecordActivated(player, priceCookies, cookiesRemaining)
	if RunService:IsStudio() then
		return
	end

	local ok, analyticsError = pcall(function()
		AnalyticsService:LogCustomEvent(player, "HubCoreActivated", 1, {
			PriceCookies = tostring(math.max(0, tonumber(priceCookies) or 0)),
			CookiesRemaining = tostring(math.max(0, tonumber(cookiesRemaining) or 0)),
		})
	end)
	if not ok then
		warn("Hub Core analytics failed: " .. tostring(analyticsError))
	end
end

function HubCoreAnalyticsService.Init() end

return HubCoreAnalyticsService
