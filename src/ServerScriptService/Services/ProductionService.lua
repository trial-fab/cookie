local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local BuildingSkinService = require(ServerScriptService.Services.BuildingSkinService)
local GooSkinService = require(ServerScriptService.Services.GooSkinService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local ProductionRateObserver = require(ServerScriptService.Services.ProductionRateObserver)
local SheetService = require(ServerScriptService.Services.SheetService)
local AutoclickFormula = require(ReplicatedStorage.Shared.AutoclickFormula)
local ProductionFormula = require(ReplicatedStorage.Shared.ProductionFormula)
local FloorConfig = require(ReplicatedStorage.Shared.FloorConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Attrs = require(ReplicatedStorage.Shared.Attrs)

local ProductionService = {}

local PRODUCTION_TICK_SECONDS = 10

local runningByPlayer = {}
local carryByPlayer = {}

local function getCanonicalUpgradeCounts(player)
	local data = PlayerDataService.GetDomain7Data(player)
	local run = type(data) == "table" and data.Run
	return type(run) == "table" and type(run.UpgradeCounts) == "table" and run.UpgradeCounts or nil
end

local function getCanonicalProductionContext(player, buildingId, upgradeCounts)
	return {
		GooMultiplier = GooSkinService.GetBestMultiplier(player),
		BuildingMultiplier = BuildingSkinService.GetProductionMultiplier(player, buildingId),
		UpgradeCounts = upgradeCounts,
	}
end

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

local function getPlacedBuildingGroups(player)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet or getSheetOwner(sheet) ~= player then
		return nil
	end

	local groups = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and getBuildingOwner(child) == player then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
			if config and config.TemplateKind == "Building" then
				local floorId = FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId))
				local key = floorId .. "\0" .. upgradeId
				local group = groups[key]
				if not group then
					group = {
						upgradeId = upgradeId,
						floorId = floorId,
						buildings = {},
					}
					groups[key] = group
				end
				table.insert(group.buildings, child)
			end
		end
	end

	return groups
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
	local upgradeCounts = getCanonicalUpgradeCounts(player)
	if not upgradeCounts then
		carryByPlayer[player] = {}
		return 0, {}
	end
	local groups = getPlacedBuildingGroups(player)
	if not groups then
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

	for key in pairs(playerCarry) do
		if not groups[key] then
			playerCarry[key] = nil
		end
	end

	for key, group in pairs(groups) do
		local config = UpgradeConfig[group.upgradeId]
		local placedCount = #group.buildings
		local cpsPerBuilding = ProductionFormula.GetCps(
			player,
			group.upgradeId,
			config,
			group.floorId,
			getCanonicalProductionContext(player, group.upgradeId, upgradeCounts)
		)
		local rawCookies = placedCount * cpsPerBuilding * elapsedSeconds + (playerCarry[key] or 0)
		local cookiesGained = getWholeCookiesFromCarry(rawCookies)

		playerCarry[key] = rawCookies - cookiesGained

		if cookiesGained ~= 0 then
			totalCookies += cookiesGained
			distributeEarnings(group.buildings, cookiesGained, payload)
		end
	end

	return totalCookies, payload
end

function ProductionService.GetCps(player)
	local upgradeCounts = getCanonicalUpgradeCounts(player)
	if not upgradeCounts then
		return 0
	end
	local groups = getPlacedBuildingGroups(player)
	if not groups then
		return 0
	end

	local totalCps = 0
	for _, group in pairs(groups) do
		local config = UpgradeConfig[group.upgradeId]
		totalCps += #group.buildings
			* ProductionFormula.GetCps(
				player,
				group.upgradeId,
				config,
				group.floorId,
				getCanonicalProductionContext(player, group.upgradeId, upgradeCounts)
			)
	end

	return totalCps
end

-- Replicate total in-session passive CpS to clients: placed-building production
-- plus autoclick income. GetCps intentionally remains buildings-only because
-- OfflineEarningsService excludes autoclicks from away-time rewards.
function ProductionService.RefreshCps(player)
	local upgradeCounts = getCanonicalUpgradeCounts(player)
	local autoclickCps = upgradeCounts
		and AutoclickFormula.GetLiveCps(player, { UpgradeCounts = upgradeCounts })
		or 0
	local liveCps = ProductionService.GetCps(player) + autoclickCps
	player:SetAttribute(Attrs.Cps, liveCps)
	PlayerMetricsService.RecordCps(player, liveCps)
end

local function startPlayerLoop(player)
	if runningByPlayer[player] then
		return
	end

	runningByPlayer[player] = true
	carryByPlayer[player] = carryByPlayer[player] or {}
	ProductionRateObserver.ObservePlayer(player)

	task.spawn(function()
		while runningByPlayer[player] and player.Parent do
			task.wait(PRODUCTION_TICK_SECONDS)

			if not runningByPlayer[player] or not player.Parent then
				break
			end

			local cookiesGained, payload = computeTick(player, PRODUCTION_TICK_SECONDS)
			if cookiesGained ~= 0 then
				CookieService.AddCookies(player, cookiesGained, PlayerMetricsService.CookieSources.Building)
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
	ProductionRateObserver.Init(ProductionService.RefreshCps)

	Players.PlayerAdded:Connect(startPlayerLoop)
	Players.PlayerRemoving:Connect(stopPlayerLoop)

	for _, player in ipairs(Players:GetPlayers()) do
		startPlayerLoop(player)
	end

	print("ProductionService initialized")
end

return ProductionService
