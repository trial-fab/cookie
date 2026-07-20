local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
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

local function getCanonicalContext(player)
	local data = PlayerDataService.GetDomain7Data(player)
	local run = type(data) == "table" and data.Run
	local counts = type(run) == "table" and run.UpgradeCounts
	return type(counts) == "table" and { UpgradeCounts = counts } or nil
end

-- Cookies per single auto-click (the Power line).
function AutoclickService.GetPower(player)
	local context = getCanonicalContext(player)
	return context and AutoclickFormula.GetPower(player, context) or 0
end

-- Auto-clicks per second (the Speed line); BASE_SPEED until a level is owned.
function AutoclickService.GetSpeed(player)
	local context = getCanonicalContext(player)
	return context and AutoclickFormula.GetSpeed(player, context) or 0
end

-- Total idle cookies/second, before the per-tick split (excludes the event
-- multiplier so callers/tests can reason about the base rate).
function AutoclickService.GetCookiesPerSecond(player)
	local context = getCanonicalContext(player)
	return context and AutoclickFormula.GetBaseCps(player, context) or 0
end

function AutoclickService.StepPlayer(player)
	local context = getCanonicalContext(player)
	if not context then
		return false, 0
	end
	local perSecond = AutoclickFormula.GetLiveCps(player, context)
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
