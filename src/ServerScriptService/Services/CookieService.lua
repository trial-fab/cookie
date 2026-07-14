local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CookieService = {}
local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local GoldenCookieService = require(ServerScriptService.Services.GoldenCookieService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local StoryService = require(ServerScriptService.Services.StoryService)
local XpService = require(ServerScriptService.Services.XpService)

local STEAL_RESET_SECONDS = 60
local MAX_STEAL_PER_WINDOW_RATIO = 0.30
local MAX_STEAL_AMOUNT = 112000
local CLICKING_POWER_UPGRADE_ID = "Clicking Power"
-- Server-side cap on validated manual clicks. ClickDetector events can be spam-fired
-- by exploits far beyond human speed; anything past this rate earns nothing. 20/s is
-- above any legitimate clicking, so real players never hit it.
local MAX_CLICKS_PER_SECOND = 20

local sheetState = {}
local clickWindowByPlayer = {}

local function isClickRateAllowed(player)
	local now = os.clock()
	local window = clickWindowByPlayer[player]
	if not window or now - window.startedAt >= 1 then
		clickWindowByPlayer[player] = { startedAt = now, count = 1 }
		return true
	end

	window.count += 1
	return window.count <= MAX_CLICKS_PER_SECOND
end

local function getCookiesValue(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return nil
	end

	return leaderstats:FindFirstChild("Cookies")
end

local function getUpgradeCount(player, upgradeId)
	local upgradeCountData = player:FindFirstChild("UpgradeCountData")
	if not upgradeCountData then
		return 0
	end

	local countValue = upgradeCountData:FindFirstChild(upgradeId)
	if countValue and countValue:IsA("IntValue") then
		return math.max(0, countValue.Value)
	end

	return 0
end

local function getClickPowerMultiplier()
	local config = UpgradeConfig[CLICKING_POWER_UPGRADE_ID]
	local multiplier = config and config.ClickPowerMultiplier
	if type(multiplier) == "number" and multiplier > 0 then
		return multiplier
	end

	return 1
end

local function multiplyNumericAttributes(multiplier, container)
	for _, value in pairs(container:GetAttributes()) do
		if typeof(value) == "number" then
			multiplier *= value
		end
	end

	return multiplier
end

local function multiplyNumericValues(multiplier, container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("NumberValue") or child:IsA("IntValue") then
			multiplier *= child.Value
		end
	end

	return multiplier
end

local function getClickEventMultiplier()
	local worldEventMultipliers = ReplicatedStorage:FindFirstChild("WorldEventMultipliers")
	if not worldEventMultipliers then
		return 1
	end

	local multiplier = 1
	multiplier = multiplyNumericAttributes(multiplier, worldEventMultipliers)
	multiplier = multiplyNumericValues(multiplier, worldEventMultipliers)

	return math.max(0, multiplier)
end

-- Public accessor so AutoclickService can apply the same world-event/frenzy
-- multiplier to idle income (autoclicks still never roll golden-cookie drops).
function CookieService.GetClickEventMultiplier()
	return getClickEventMultiplier()
end

function CookieService.GetCookiesPerClick(player)
	local clickingPowerCount = getUpgradeCount(player, CLICKING_POWER_UPGRADE_ID)
	local cookiesPerClick = getClickPowerMultiplier() ^ clickingPowerCount

	return math.max(1, math.floor(cookiesPerClick + 0.5))
end

function CookieService.RefreshCookiesPerClickDisplay(player)
	local value = player:FindFirstChild("CookiesGainedPerClick")
	if value and value:IsA("IntValue") then
		value.Value = CookieService.GetCookiesPerClick(player)
		return true
	end

	return false
end

function CookieService.AddCookies(player, amount, source)
	local cookies = getCookiesValue(player)
	if not cookies then
		return false
	end

	local previous = cookies.Value
	cookies.Value = math.max(0, previous + amount)
	PlayerMetricsService.RecordCookieDelta(player, cookies.Value - previous, source)
	return true
end

function CookieService.HandleClick(player, options)
	options = type(options) == "table" and options or {}
	local automated = options.automated == true

	if not automated and not isClickRateAllowed(player) then
		return false, 0
	end

	local amount = CookieService.GetCookiesPerClick(player) * getClickEventMultiplier()
	if amount <= 0 then
		return false, 0
	end

	local cookieSource = automated and PlayerMetricsService.CookieSources.Autoclick or PlayerMetricsService.CookieSources.Manual
	local added = CookieService.AddCookies(player, amount, cookieSource)
	if added and not automated then
		PlayerMetricsService.RecordManualClick(player)
		-- §6: golden-cookie drop rolls fire only for validated manual clicks.
		-- Autoclicks pass automated = true and never reach this branch.
		GoldenCookieService.RollClickDrop(player)
		XpService.AwardClick(player)
		StoryService.OnCookieClicked(player)
	end

	return added, amount
end

function CookieService.SetCookies(player, amount)
	local cookies = getCookiesValue(player)
	if not cookies then
		return false
	end

	cookies.Value = math.max(0, amount)
	return true
end

local function displayIncrease(cookiePart, text, textColor)
	if not cookiePart or not cookiePart:IsA("BasePart") then
		return
	end

	local billboardGui = cookiePart:FindFirstChild("BillboardGui")
	if not billboardGui or not billboardGui:IsA("BillboardGui") then
		return
	end

	Net.fireAll(Net.Names.CookieIncrease, {
		CookiePart = cookiePart,
		Text = tostring(text),
		TextColor = typeof(textColor) == "Color3" and textColor or nil,
		StartOffset = Vector3.new(math.random(-5, 5), 0, math.random(-5, 5)),
	})
end
CookieService.DisplayIncrease = displayIncrease

local function getSheetOwner(sheet)
	local ownerValue = sheet:FindFirstChild("SheetOwner")
	if not ownerValue or not ownerValue:IsA("ObjectValue") then
		return nil
	end

	return ownerValue.Value
end

local function isCharacterAlive(player)
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function getSheetState(sheet)
	if sheetState[sheet] then
		return sheetState[sheet]
	end

	sheetState[sheet] = {
		stolenThisWindow = 0,
		ownerCookiesAtWindowStart = math.huge,
		canSteal = true,
		lastReset = os.clock(),
	}

	return sheetState[sheet]
end

local function resetStealWindowIfNeeded(sheet, owner)
	local state = getSheetState(sheet)
	local now = os.clock()

	if now - state.lastReset < STEAL_RESET_SECONDS then
		return state
	end

	state.lastReset = now
	state.stolenThisWindow = 0
	state.canSteal = true

	local ownerCookies = getCookiesValue(owner)
	state.ownerCookiesAtWindowStart = ownerCookies and ownerCookies.Value or math.huge

	return state
end

local function markStealAmount(sheet, amount)
	local state = getSheetState(sheet)
	state.stolenThisWindow += amount

	if state.ownerCookiesAtWindowStart == math.huge then
		return
	end

	local maxWindowSteal = state.ownerCookiesAtWindowStart * MAX_STEAL_PER_WINDOW_RATIO
	if state.stolenThisWindow >= maxWindowSteal then
		state.canSteal = false
	end
end

local function isOwnerProtected(owner)
	local canBeStolenFrom = owner:FindFirstChild("CanBeStolenFrom")
	return canBeStolenFrom and canBeStolenFrom:IsA("BoolValue") and not canBeStolenFrom.Value
end

local function markAttackerAsStealer(attacker)
	local canBeStolenFrom = attacker:FindFirstChild("CanBeStolenFrom")
	if canBeStolenFrom and canBeStolenFrom:IsA("BoolValue") then
		canBeStolenFrom.Value = true
	end
end

local function calculateStealAmount(attacker, owner)
	local attackerCookies = getCookiesValue(attacker)
	local ownerCookies = getCookiesValue(owner)

	if not attackerCookies or not ownerCookies or ownerCookies.Value <= 0 then
		return 0
	end

	local cookiesPerClick = CookieService.GetCookiesPerClick(attacker)
	local baseSteal = math.max(cookiesPerClick * 2, ownerCookies.Value * 0.000625 + 0.5)

	local attackerCookieCount = math.max(attackerCookies.Value, 2)
	local growthLimit = attackerCookieCount / (10 * math.log(attackerCookieCount))

	local stealAmount = math.min(baseSteal, growthLimit)
	stealAmount = math.floor(math.min(math.max(stealAmount, 2), MAX_STEAL_AMOUNT))

	return math.min(stealAmount, ownerCookies.Value)
end

local function handleOwnerClick(cookiePart, owner)
	local added, amount = CookieService.HandleClick(owner, { automated = false })
	if added then
		displayIncrease(cookiePart, "+" .. NumberFormat.abbreviate(amount))
	end
end

local function handleStealClick(cookiePart, sheet, attacker, owner)
	if not isCharacterAlive(attacker) then
		return
	end

	local state = resetStealWindowIfNeeded(sheet, owner)

	if not state.canSteal then
		local secondsLeft = math.max(0, math.floor(STEAL_RESET_SECONDS - (os.clock() - state.lastReset)))
		displayIncrease(cookiePart, "Wait " .. secondsLeft .. "s")
		return
	end

	markAttackerAsStealer(attacker)

	if isOwnerProtected(owner) then
		displayIncrease(cookiePart, "Protected")
		return
	end

	local stealAmount = calculateStealAmount(attacker, owner)
	if stealAmount <= 0 then
		return
	end

	local gainedAmount = math.floor(stealAmount * 0.8)

	CookieService.AddCookies(attacker, gainedAmount, PlayerMetricsService.CookieSources.Theft)
	CookieService.AddCookies(owner, -stealAmount, PlayerMetricsService.CookieSources.TheftLoss)
	markStealAmount(sheet, stealAmount)

	displayIncrease(cookiePart, "*stolen* " .. NumberFormat.abbreviate(stealAmount))
end

local function connectCookie(sheet)
	local cookiePart = sheet:FindFirstChild("Cookie")
	if not cookiePart or not cookiePart:IsA("BasePart") then
		warn("Cookie sheet missing Cookie part: " .. sheet:GetFullName())
		return
	end

	local clickDetector = cookiePart:FindFirstChildOfClass("ClickDetector")
	if not clickDetector then
		warn("Cookie part missing ClickDetector: " .. cookiePart:GetFullName())
		return
	end

	clickDetector.MouseClick:Connect(function(player)
		local owner = getSheetOwner(sheet)

		if not owner then
			return
		end

		if player == owner then
			handleOwnerClick(cookiePart, owner)
		else
			handleStealClick(cookiePart, sheet, player, owner)
		end
	end)
end

function CookieService.Init()
	Net.event(Net.Names.CookieIncrease)

	Players.PlayerRemoving:Connect(function(player)
		clickWindowByPlayer[player] = nil
	end)

	local cookieSheetsFolder = Workspace:WaitForChild("CookieSheets")

	for _, sheet in ipairs(cookieSheetsFolder:GetChildren()) do
		connectCookie(sheet)
	end

	cookieSheetsFolder.ChildAdded:Connect(function(sheet)
		task.wait()
		connectCookie(sheet)
	end)

	print("CookieService initialized")
end

return CookieService
