local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local CookieService = {}
local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local GoldenCookieService = require(ServerScriptService.Services.GoldenCookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local StoryService = require(ServerScriptService.Services.StoryService)
local XpService = require(ServerScriptService.Services.XpService)

local STEAL_RESET_SECONDS = 60
local STEAL_PROTECTION_SECONDS = 300
local MAX_STEAL_PER_WINDOW_RATIO = 0.30
local MAX_STEAL_AMOUNT = 112000
local CLICKING_POWER_UPGRADE_ID = "Clicking Power"
-- Server-side cap on validated manual clicks. ClickDetector events can be spam-fired
-- by exploits far beyond human speed; anything past this rate earns nothing. 20/s is
-- above any legitimate clicking, so real players never hit it.
local MAX_CLICKS_PER_SECOND = 20

local sheetState = {}
local clickWindowByPlayer = {}
local stealProtectionGenerationByPlayer = setmetatable({}, { __mode = "k" })

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

	local cookies = leaderstats:FindFirstChild("Cookies")
	return cookies and cookies:IsA("NumberValue") and cookies or nil
end

local function getRun(player)
	local data = player and PlayerDataService.GetDomain7Data(player)
	local run = type(data) == "table" and data.Run
	return type(run) == "table" and run or nil
end

local function getUpgradeCount(player, upgradeId)
	local run = getRun(player)
	local counts = run and run.UpgradeCounts
	if type(counts) ~= "table" then
		return 0
	end
	return math.max(0, tonumber(counts[upgradeId]) or 0)
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
	if not getRun(player) then
		return nil
	end
	local clickingPowerCount = getUpgradeCount(player, CLICKING_POWER_UPGRADE_ID)
	local cookiesPerClick = getClickPowerMultiplier() ^ clickingPowerCount

	return math.max(1, math.floor(cookiesPerClick + 0.5))
end

function CookieService.RefreshCookiesPerClickDisplay(player)
	local value = player:FindFirstChild("CookiesGainedPerClick")
	local amount = CookieService.GetCookiesPerClick(player)
	if value and value:IsA("IntValue") and amount then
		value.Value = amount
		return true
	end

	return false
end

function CookieService.AddCookies(player, amount, source)
	local run = getRun(player)
	local cookies = getCookiesValue(player)
	amount = tonumber(amount)
	if not run or not cookies or not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
		return false
	end

	local previous = tonumber(run.Cookies) or 0
	local current = math.max(0, previous + amount)
	run.Cookies = current
	cookies.Value = current
	PlayerMetricsService.RecordCookieDelta(player, current - previous, source)
	return true
end

function CookieService.GetCookies(player)
	local run = getRun(player)
	return run and (tonumber(run.Cookies) or 0) or nil
end

function CookieService.HandleClick(player, options)
	options = type(options) == "table" and options or {}
	local automated = options.automated == true

	-- Do not consume rate-limit state before the canonical domain is ready.
	if not getRun(player) then
		return false, 0
	end
	if not automated and not isClickRateAllowed(player) then
		return false, 0
	end

	local perClick = CookieService.GetCookiesPerClick(player)
	local amount = perClick and perClick * getClickEventMultiplier() or 0
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
	local run = getRun(player)
	local cookies = getCookiesValue(player)
	amount = tonumber(amount)
	if not run or not cookies or not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
		return false
	end

	run.Cookies = math.max(0, amount)
	cookies.Value = run.Cookies
	return true
end

function CookieService.GetCanBeStolenFrom(player)
	local run = getRun(player)
	if not run then
		return nil
	end
	return run.CanBeStolenFrom == true
end

function CookieService.SetCanBeStolenFrom(player, enabled)
	local run = getRun(player)
	local projection = player:FindFirstChild("CanBeStolenFrom")
	if not run or not projection or not projection:IsA("BoolValue") then
		return false
	end

	run.CanBeStolenFrom = enabled == true
	projection.Value = run.CanBeStolenFrom
	return true
end

function CookieService.StartStealProtectionTimer(player)
	local protected = CookieService.GetCanBeStolenFrom(player)
	if protected == nil then
		return false
	end
	stealProtectionGenerationByPlayer[player] = (stealProtectionGenerationByPlayer[player] or 0) + 1
	local generation = stealProtectionGenerationByPlayer[player]
	if protected then
		return false
	end

	task.delay(STEAL_PROTECTION_SECONDS, function()
		if stealProtectionGenerationByPlayer[player] ~= generation then
			return
		end
		if player.Parent and CookieService.GetCanBeStolenFrom(player) == false then
			CookieService.SetCanBeStolenFrom(player, true)
		end
	end)
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

	local ownerBalance = CookieService.GetCookies(owner)
	state.ownerCookiesAtWindowStart = ownerBalance == nil and math.huge or ownerBalance

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
	return CookieService.GetCanBeStolenFrom(owner) == false
end

local function markAttackerAsStealer(attacker)
	return CookieService.SetCanBeStolenFrom(attacker, true)
end

local function calculateStealAmount(attacker, owner)
	local attackerCookies = CookieService.GetCookies(attacker)
	local ownerCookies = CookieService.GetCookies(owner)

	if attackerCookies == nil or ownerCookies == nil or ownerCookies <= 0 then
		return 0
	end

	local cookiesPerClick = CookieService.GetCookiesPerClick(attacker)
	if not cookiesPerClick then
		return 0
	end
	local baseSteal = math.max(cookiesPerClick * 2, ownerCookies * 0.000625 + 0.5)

	local attackerCookieCount = math.max(attackerCookies, 2)
	local growthLimit = attackerCookieCount / (10 * math.log(attackerCookieCount))

	local stealAmount = math.min(baseSteal, growthLimit)
	stealAmount = math.floor(math.min(math.max(stealAmount, 2), MAX_STEAL_AMOUNT))

	return math.min(stealAmount, ownerCookies)
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
	-- Prove both canonical Runs are live before touching the theft-window cache or either
	-- projection. This keeps crafted/pre-setup and post-profile-loss clicks fully fail-closed.
	if
		CookieService.GetCookies(attacker) == nil
		or CookieService.GetCookies(owner) == nil
		or CookieService.GetCanBeStolenFrom(attacker) == nil
		or CookieService.GetCanBeStolenFrom(owner) == nil
	then
		return
	end

	local state = resetStealWindowIfNeeded(sheet, owner)

	if not state.canSteal then
		local secondsLeft = math.max(0, math.floor(STEAL_RESET_SECONDS - (os.clock() - state.lastReset)))
		displayIncrease(cookiePart, "Wait " .. secondsLeft .. "s")
		return
	end

	if not markAttackerAsStealer(attacker) then
		return
	end

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
		stealProtectionGenerationByPlayer[player] = nil
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
