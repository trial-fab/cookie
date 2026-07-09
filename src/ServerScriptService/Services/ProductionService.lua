local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local SheetService = require(ServerScriptService.Services.SheetService)
local ProductionFormula = require(ReplicatedStorage.Shared.ProductionFormula)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)

local ProductionService = {}

local PRODUCTION_TICK_SECONDS = 10

local runningByPlayer = {}
local carryByPlayer = {}

local function getSheetOwner(sheet)
	local ownerValue = sheet and sheet:FindFirstChild("SheetOwner")
	if ownerValue and ownerValue:IsA("ObjectValue") then
		return ownerValue.Value
	end

	return nil
end

local function getBuildingOwner(building)
	local ownerValue = building:FindFirstChild("Owner")
	if ownerValue and ownerValue:IsA("ObjectValue") then
		return ownerValue.Value
	end

	return nil
end

local function getPlacedBuildingsByType(player)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet or getSheetOwner(sheet) ~= player then
		return nil
	end

	local buildingsByType = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and getBuildingOwner(child) == player then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
			if config and config.TemplateKind == "Building" then
				buildingsByType[upgradeId] = buildingsByType[upgradeId] or {}
				table.insert(buildingsByType[upgradeId], child)
			end
		end
	end

	return buildingsByType
end

local function getWholeCookiesFromCarry(carry)
	if carry >= 0 then
		return math.floor(carry)
	end

	return math.ceil(carry)
end

local function distributeEarnings(buildings, totalAmount, payload)
	local count = #buildings
	if count <= 0 or totalAmount == 0 then
		return
	end

	local sign = totalAmount < 0 and -1 or 1
	local remaining = math.abs(totalAmount)
	local baseAmount = math.floor(remaining / count)
	local extra = remaining % count

	for index, building in ipairs(buildings) do
		local amount = baseAmount
		if index <= extra then
			amount += 1
		end

		if amount ~= 0 then
			table.insert(payload, {
				Building = building,
				Amount = amount * sign,
			})
		end
	end
end

local function computeTick(player, elapsedSeconds)
	local buildingsByType = getPlacedBuildingsByType(player)
	if not buildingsByType then
		carryByPlayer[player] = {}
		return 0, {}
	end

	local playerCarry = carryByPlayer[player]
	if not playerCarry then
		playerCarry = {}
		carryByPlayer[player] = playerCarry
	end

	local totalCookies = 0
	local payload = {}

	for upgradeId in pairs(playerCarry) do
		if not buildingsByType[upgradeId] then
			playerCarry[upgradeId] = nil
		end
	end

	for upgradeId, buildings in pairs(buildingsByType) do
		local config = UpgradeConfig[upgradeId]
		local placedCount = #buildings
		local cpsPerBuilding = ProductionFormula.GetCps(player, upgradeId, config)
		local rawCookies = placedCount * cpsPerBuilding * elapsedSeconds + (playerCarry[upgradeId] or 0)
		local cookiesGained = getWholeCookiesFromCarry(rawCookies)

		playerCarry[upgradeId] = rawCookies - cookiesGained

		if cookiesGained ~= 0 then
			totalCookies += cookiesGained
			distributeEarnings(buildings, cookiesGained, payload)
		end
	end

	return totalCookies, payload
end

function ProductionService.GetCps(player)
	local buildingsByType = getPlacedBuildingsByType(player)
	if not buildingsByType then
		return 0
	end

	local totalCps = 0
	for upgradeId, buildings in pairs(buildingsByType) do
		local config = UpgradeConfig[upgradeId]
		totalCps += #buildings * ProductionFormula.GetCps(player, upgradeId, config)
	end

	return totalCps
end

-- Replicate the player's live CpS to the client (§9 HUD metric). A plain
-- attribute replicates automatically; the CpsHud controller reads it. Refreshed
-- every production tick and on demand after placement/setup.
function ProductionService.RefreshCps(player)
	player:SetAttribute(Attrs.Cps, ProductionService.GetCps(player))
end

local function startPlayerLoop(player)
	if runningByPlayer[player] then
		return
	end

	runningByPlayer[player] = true
	carryByPlayer[player] = carryByPlayer[player] or {}

	task.spawn(function()
		while runningByPlayer[player] and player.Parent do
			task.wait(PRODUCTION_TICK_SECONDS)

			if not runningByPlayer[player] or not player.Parent then
				break
			end

			local cookiesGained, payload = computeTick(player, PRODUCTION_TICK_SECONDS)
			if cookiesGained ~= 0 then
				CookieService.AddCookies(player, cookiesGained)
			end

			if #payload > 0 then
				Net.fireClient(Net.Names.ProductionEarnings, player, payload)
			end

			ProductionService.RefreshCps(player)
		end
	end)
end

local function stopPlayerLoop(player)
	runningByPlayer[player] = nil
	carryByPlayer[player] = nil
end

function ProductionService.Init()
	-- Pre-create the server->client push channel so a client that boots first finds it
	-- immediately instead of hanging at WaitForChild until the first production tick.
	Net.event(Net.Names.ProductionEarnings)

	Players.PlayerAdded:Connect(startPlayerLoop)
	Players.PlayerRemoving:Connect(stopPlayerLoop)

	for _, player in ipairs(Players:GetPlayers()) do
		startPlayerLoop(player)
	end

	print("ProductionService initialized")
end

return ProductionService
