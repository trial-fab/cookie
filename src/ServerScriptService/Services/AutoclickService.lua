local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local SheetService = require(ServerScriptService.Services.SheetService)
local AutoclickFormula = require(ReplicatedStorage.Shared.AutoclickFormula)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)

local AutoclickService = {}

-- IDLE ROUTE (§4c): two independent lines — Power (cookies per auto-click) and
-- Speed (auto-clicks per second, base 2/s). Income/sec = power × speed × the
-- world-event multiplier. The server pays it out over a fixed tick cadence
-- (speed is an economic multiplier here, not a change to the real loop rate).
-- Autoclicks never roll golden-cookie drops (we add cookies directly, bypassing
-- CookieService.HandleClick) and are excluded from offline earnings.
local TICK_SECONDS = 0.5
local POPUP_COLOR = Color3.fromRGB(0, 170, 255)
local initialized = false

-- Cookies per single auto-click (the Power line).
function AutoclickService.GetPower(player)
	return AutoclickFormula.GetPower(player)
end

-- Auto-clicks per second (the Speed line); BASE_SPEED until a level is owned.
function AutoclickService.GetSpeed(player)
	return AutoclickFormula.GetSpeed(player)
end

-- Total idle cookies/second, before the per-tick split (excludes the event
-- multiplier so callers/tests can reason about the base rate).
function AutoclickService.GetCookiesPerSecond(player)
	return AutoclickFormula.GetBaseCps(player)
end

function AutoclickService.StepPlayer(player)
	local perSecond = AutoclickFormula.GetLiveCps(player)
	if perSecond <= 0 then
		return false, 0
	end

	-- Frenzy/world-event multipliers are included in the shared live formula.
	local payout = math.floor(perSecond * TICK_SECONDS + 0.5)
	if payout <= 0 then
		return false, 0
	end

	local added = CookieService.AddCookies(player, payout, PlayerMetricsService.CookieSources.Autoclick)
	if added then
		local sheet = SheetService.GetPlayerSheet(player)
		local cookie = sheet and sheet:FindFirstChild("Cookie")
		if cookie and cookie:IsA("BasePart") then
			CookieService.DisplayIncrease(cookie, "+" .. NumberFormat.abbreviate(payout), POPUP_COLOR)
		end
	end

	return added, payout
end

function AutoclickService.Init()
	if initialized then
		return
	end
	initialized = true

	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				AutoclickService.StepPlayer(player)
			end
		end
	end)

	print("AutoclickService initialized")
end

return AutoclickService
