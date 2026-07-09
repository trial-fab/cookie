local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local SheetService = require(ServerScriptService.Services.SheetService)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)

local AutoclickService = {}

-- IDLE ROUTE (§4c): two independent lines — Power (cookies per auto-click) and
-- Speed (auto-clicks per second, base 2/s). Income/sec = power × speed × the
-- world-event multiplier. The server pays it out over a fixed tick cadence
-- (speed is an economic multiplier here, not a change to the real loop rate).
-- Autoclicks never roll golden-cookie drops (we add cookies directly, bypassing
-- CookieService.HandleClick) and are excluded from offline earnings.
local POWER_UPGRADE_ID = "Autoclicker"
local SPEED_UPGRADE_ID = "Autoclick Speed"
local BASE_SPEED = 2 -- clicks/s before any Autoclick Speed level (matches config EffectText)
local TICK_SECONDS = 0.5
local POPUP_COLOR = Color3.fromRGB(0, 170, 255)
local initialized = false

local function getUpgradeLevel(player, upgradeId)
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	local countValue = upgradeCountData and upgradeCountData:FindFirstChild(upgradeId)
	if not countValue or not countValue:IsA("IntValue") then
		return 0
	end

	local config = UpgradeConfig[upgradeId]
	local maxLevel = config and config.Levels and #config.Levels or 0
	return math.clamp(countValue.Value, 0, maxLevel)
end

-- Cookies per single auto-click (the Power line).
function AutoclickService.GetPower(player)
	local config = UpgradeConfig[POWER_UPGRADE_ID]
	local level = getUpgradeLevel(player, POWER_UPGRADE_ID)
	local levelConfig = config and config.Levels and config.Levels[level]
	local power = levelConfig and tonumber(levelConfig.AutoclickPayout) or 0
	return math.max(0, power)
end

-- Auto-clicks per second (the Speed line); BASE_SPEED until a level is owned.
function AutoclickService.GetSpeed(player)
	local config = UpgradeConfig[SPEED_UPGRADE_ID]
	local level = getUpgradeLevel(player, SPEED_UPGRADE_ID)
	local levelConfig = config and config.Levels and config.Levels[level]
	local speed = levelConfig and tonumber(levelConfig.AutoclickSpeed) or BASE_SPEED
	return math.max(BASE_SPEED, speed)
end

-- Total idle cookies/second, before the per-tick split (excludes the event
-- multiplier so callers/tests can reason about the base rate).
function AutoclickService.GetCookiesPerSecond(player)
	local power = AutoclickService.GetPower(player)
	if power <= 0 then
		return 0
	end
	return power * AutoclickService.GetSpeed(player)
end

function AutoclickService.StepPlayer(player)
	local perSecond = AutoclickService.GetCookiesPerSecond(player)
	if perSecond <= 0 then
		return false, 0
	end

	-- Frenzy/world-event multipliers apply to idle income too (§4c).
	local payout = math.floor(perSecond * TICK_SECONDS * CookieService.GetClickEventMultiplier() + 0.5)
	if payout <= 0 then
		return false, 0
	end

	local added = CookieService.AddCookies(player, payout)
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
