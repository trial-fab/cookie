-- ProductionService: the passive building payout loop.
--
-- Buildings are grouped so identical ones share one CpS evaluation and one carry remainder. The
-- key is (floorId, upgradeId) PLUS which boost fields cover the building, because a field is
-- spatial: two Cookie Banks on the same floor now genuinely earn different amounts when only one
-- of them stands inside a Power field, and they must accrue (and carry) separately.
--
-- Payout cadence is per group, not global. A Speed field pays its group on a proportionally
-- shorter interval and credits the same amount per payout, so the cookies land more often AND add
-- up to the same +50% Power gives -- the two fields differ in feel, not in value (§12.2).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local BoostFieldService = require(ServerScriptService.Services.BoostFieldService)
local BoostFieldEffects = require(ReplicatedStorage.Shared.BoostFieldEffects)
local BuildingSkinService = require(ServerScriptService.Services.BuildingSkinService)
local FriendBoostService = require(ServerScriptService.Services.FriendBoostService)
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
-- Floor on the loop's sleep. Every group's interval is well above it; this only stops a bad
-- schedule from spinning the loop.
local MIN_STEP_SECONDS = 0.5
-- Absorbs float error so a group that is due "now" is not pushed a whole cycle into the future.
local DUE_EPSILON = 1e-3

local runningByPlayer = {}
-- player -> { [groupKey] = { carry, lastPaidAt, basePair } }
local groupStateByPlayer = {}

local function getCanonicalUpgradeCounts(player)
	local data = PlayerDataService.GetDomain7Data(player)
	local run = type(data) == "table" and data.Run
	return type(run) == "table" and type(run.UpgradeCounts) == "table" and run.UpgradeCounts or nil
end

local function getCanonicalProductionContext(player, buildingId, upgradeCounts, powerFieldMultiplier, friendMultiplier)
	return {
		GooMultiplier = GooSkinService.GetBestMultiplier(player),
		BuildingMultiplier = BuildingSkinService.GetProductionMultiplier(player, buildingId),
		UpgradeCounts = upgradeCounts,
		-- Spatial, so it belongs to the group rather than the player: ProductionFormula folds it in
		-- as its own breakdown source so the HUD cannot describe a different number than we pay.
		PowerFieldMultiplier = powerFieldMultiplier,
		-- Presence-based, so a caller pricing a window the friend was not present for (offline
		-- earnings) passes 1 rather than the live value.
		FriendMultiplier = friendMultiplier,
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

	-- Read once per pass, not once per building: a plot has at most one field of each type.
	local coverage = BoostFieldEffects.GetCoverage(sheet)

	local groups = {}
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and getBuildingOwner(child) == player then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
			if config and config.TemplateKind == "Building" then
				local floorId = FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId))
				local basePair = floorId .. "\0" .. upgradeId
				local outputMultiplier, frequencyMultiplier =
					BoostFieldEffects.Apply(coverage, floorId, child:GetPivot().Position)
				-- The multipliers themselves discriminate the group, so buildings only split apart
				-- when their earnings actually differ -- and two fields of unequal strength would
				-- separate correctly without this key learning anything about field types.
				local key = ("%s\0%s\0%s"):format(basePair, tostring(outputMultiplier), tostring(frequencyMultiplier))
				local group = groups[key]
				if not group then
					group = {
						upgradeId = upgradeId,
						floorId = floorId,
						basePair = basePair,
						buildings = {},
						powerMultiplier = outputMultiplier,
						speedMultiplier = frequencyMultiplier,
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

-- How often this group pays. A Speed field shortens the interval by exactly the strength factor,
-- and the payout below multiplies elapsed time by the same factor, so each payout is worth an
-- ordinary tick and they simply arrive more often.
local function getGroupInterval(group)
	return PRODUCTION_TICK_SECONDS / group.speedMultiplier
end

-- A group appearing for the first time inherits the accrual clock of its siblings on the same
-- (floor, building) pair. Dropping a field SPLITS an existing group, and without this the covered
-- buildings would silently restart their clock and lose everything accrued since the last payout.
-- The oldest sibling is chosen so the split never costs the player time; the buildings are disjoint
-- across the split, so nothing can be paid twice.
--
-- With no sibling at all this is a genuinely new (floor, building) pair, and it starts one interval
-- in arrears so its first payout lands on the next tick -- the behaviour a fixed 10s loop has
-- always had for a newly placed building.
local function inheritLastPaidAt(state, group, now, interval)
	local inherited = nil
	for _, entry in pairs(state) do
		if entry.basePair == group.basePair and (inherited == nil or entry.lastPaidAt < inherited) then
			inherited = entry.lastPaidAt
		end
	end
	return inherited or (now - interval)
end

local function getGroupState(player)
	local state = groupStateByPlayer[player]
	if not state then
		state = {}
		groupStateByPlayer[player] = state
	end
	return state
end

-- Pays every group whose interval has elapsed and returns the cookies gained, the per-building
-- payload, and how long until the soonest group is next due.
local function computeTick(player, now)
	local upgradeCounts = getCanonicalUpgradeCounts(player)
	local groups = upgradeCounts and getPlacedBuildingGroups(player) or nil
	if not groups then
		groupStateByPlayer[player] = {}
		return 0, {}, PRODUCTION_TICK_SECONDS
	end

	-- Sampled once for the whole pass, like field coverage: a friend who arrives or leaves
	-- mid-window changes the rate from the next payout rather than partway through this one.
	local friendMultiplier = FriendBoostService.GetMultiplier(player)

	local state = getGroupState(player)
	local totalCookies = 0
	local payload = {}
	local nextDueIn = PRODUCTION_TICK_SECONDS

	for key, group in pairs(groups) do
		local interval = getGroupInterval(group)
		local entry = state[key]
		if not entry then
			-- Inheritance must run BEFORE stale keys are pruned: the sibling a split group needs to
			-- inherit from is precisely the key that just stopped existing.
			entry = {
				carry = 0,
				lastPaidAt = inheritLastPaidAt(state, group, now, interval),
				basePair = group.basePair,
			}
			state[key] = entry
		end

		local elapsed = now - entry.lastPaidAt
		if elapsed + DUE_EPSILON >= interval then
			local config = UpgradeConfig[group.upgradeId]
			-- Coverage is sampled here, at payout time, and applies to the whole elapsed window. A
			-- field that expired part-way through that window therefore boosts (or stops boosting)
			-- at most one interval more than it strictly should -- always in the player's favour,
			-- and never leaving a payout split ambiguously across two rates.
			local cpsPerBuilding = ProductionFormula.GetCps(
				player,
				group.upgradeId,
				config,
				group.floorId,
				getCanonicalProductionContext(
					player,
					group.upgradeId,
					upgradeCounts,
					group.powerMultiplier,
					friendMultiplier
				)
			)
			local rawCookies = #group.buildings * cpsPerBuilding * elapsed * group.speedMultiplier + entry.carry
			local cookiesGained = getWholeCookiesFromCarry(rawCookies)

			entry.carry = rawCookies - cookiesGained
			entry.lastPaidAt = now

			if cookiesGained ~= 0 then
				totalCookies += cookiesGained
				distributeEarnings(group.buildings, cookiesGained, payload)
			end
			nextDueIn = math.min(nextDueIn, interval)
		else
			nextDueIn = math.min(nextDueIn, interval - elapsed)
		end
	end

	-- Prune only now that every surviving group has taken what it needed from the old state.
	for key in pairs(state) do
		if not groups[key] then
			state[key] = nil
		end
	end

	return totalCookies, payload, nextDueIn
end

-- `options.FriendMultiplier` prices production as if the Friend Boost were something else, which
-- is how OfflineEarningsService values away time at 1 without the boost having to be special-cased
-- anywhere inside the formula.
function ProductionService.GetCps(player, options)
	local upgradeCounts = getCanonicalUpgradeCounts(player)
	if not upgradeCounts then
		return 0
	end
	local groups = getPlacedBuildingGroups(player)
	if not groups then
		return 0
	end

	local overrideFriendMultiplier = type(options) == "table" and tonumber(options.FriendMultiplier) or nil
	local friendMultiplier = overrideFriendMultiplier or FriendBoostService.GetMultiplier(player)
	local totalCps = 0
	for _, group in pairs(groups) do
		local config = UpgradeConfig[group.upgradeId]
		-- Speed multiplies frequency rather than output, so it belongs here (income per second is
		-- genuinely higher) but not inside the per-building CpS the breakdown explains.
		totalCps += #group.buildings
			* group.speedMultiplier
			* ProductionFormula.GetCps(
				player,
				group.upgradeId,
				config,
				group.floorId,
				getCanonicalProductionContext(
					player,
					group.upgradeId,
					upgradeCounts,
					group.powerMultiplier,
					friendMultiplier
				)
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
	groupStateByPlayer[player] = groupStateByPlayer[player] or {}
	ProductionRateObserver.ObservePlayer(player)

	task.spawn(function()
		-- The loop sleeps until the soonest group is due rather than on a fixed cadence, which is
		-- what lets a Speed-covered group pay faster than the rest of the plot. With no fields in
		-- play every group is on the base interval, so this is the original 10s tick exactly.
		local waitSeconds = PRODUCTION_TICK_SECONDS
		while runningByPlayer[player] and player.Parent do
			task.wait(waitSeconds)

			if not runningByPlayer[player] or not player.Parent then
				break
			end

			local cookiesGained, payload, nextDueIn = computeTick(player, os.clock())
			waitSeconds = math.max(MIN_STEP_SECONDS, nextDueIn)

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
	groupStateByPlayer[player] = nil
end

function ProductionService.Init()
	-- Pre-create the server->client push channel so a client that boots first finds it
	-- immediately instead of hanging at WaitForChild until the first production tick.
	Net.event(Net.Names.ProductionEarnings)
	ProductionRateObserver.Init(ProductionService.RefreshCps)

	-- A dropped or expired field changes this player's CpS immediately. Without this the HUD keeps
	-- showing the old rate until the next tick, which on a 10s cadence reads as the boost having
	-- done nothing.
	BoostFieldService.OnFieldsChanged(function(player)
		if player and player.Parent then
			ProductionService.RefreshCps(player)
		end
	end)

	-- A friend arriving or leaving changes this player's rate the moment it happens, and on a 10s
	-- cadence a stale HUD is exactly how a boost reads as having done nothing.
	FriendBoostService.OnChanged(function(player)
		if player and player.Parent then
			ProductionService.RefreshCps(player)
		end
	end)

	Players.PlayerAdded:Connect(startPlayerLoop)
	Players.PlayerRemoving:Connect(stopPlayerLoop)

	for _, player in ipairs(Players:GetPlayers()) do
		startPlayerLoop(player)
	end

	print("ProductionService initialized")
end

return ProductionService
