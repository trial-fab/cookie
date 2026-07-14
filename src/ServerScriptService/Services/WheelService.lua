-- WheelService — the GC sink and skin economy (economy-rebalance-spec §7).
--
-- A spin costs 75 GC (the only golden-cookie sink). The deduct-and-roll is a
-- single atomic, non-yielding transaction so a player can never spin without
-- paying or pay without spinning. Rewards are cosmetics only: building skins
-- (multiplier-bearing) and limited cosmetic buildings. Duplicates auto-convert
-- to a 30 GC refund. One skin equips per building type; equipped skins feed the
-- ×skinMult layer of the production formula (the single sanctioned crossover,
-- invariant 2 — capped at ×1.5).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WheelConfig = require(ReplicatedStorage.Shared.WheelConfig)
local GoldenCookieService = require(script.Parent.GoldenCookieService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)
local Net = require(ReplicatedStorage.Shared.Net)

local WheelService = {}

local EQUIPPED_SKIN_DATA = "EquippedSkinData"
local OWNED_SKINS_ATTRIBUTE = "OwnedSkinsJson"
local EQUIPPED_SKINS_ATTRIBUTE = "EquippedSkinsJson"

local random = Random.new()

-- Server-side mirrors of each player's inventory, seeded from persistent data in
-- SetupPlayer. The JSON attributes (read back by PlayerDataService at save time)
-- are kept in lockstep with these tables.
local ownedByPlayer = {}
local equippedByPlayer = {}

local function encodeJson(value)
	local ok, result = pcall(function()
		return HttpService:JSONEncode(type(value) == "table" and value or {})
	end)
	return ok and result or "{}"
end

local function decodeJson(value)
	if type(value) ~= "table" then
		return {}
	end
	return value
end

-- ── Per-player skin-multiplier values (read by ProductionFormula) ────────────

local function getEquippedSkinDataFolder(player)
	local folder = player:FindFirstChild(EQUIPPED_SKIN_DATA)
	if folder then
		return folder
	end

	folder = Instance.new("Configuration")
	folder.Name = EQUIPPED_SKIN_DATA
	folder.Parent = player
	return folder
end

local function setBuildingSkinMultiplier(player, buildingId, multiplier)
	local folder = getEquippedSkinDataFolder(player)
	local value = folder:FindFirstChild(buildingId)

	if multiplier <= 1 then
		-- ×1 contributes nothing; drop the value so the folder only holds real skins.
		if value then
			value:Destroy()
		end
		return
	end

	if not value or not value:IsA("NumberValue") then
		if value then
			value:Destroy()
		end
		value = Instance.new("NumberValue")
		value.Name = buildingId
		value.Parent = folder
	end

	value.Value = multiplier
end

local function rebuildEquippedSkinData(player)
	local folder = getEquippedSkinDataFolder(player)
	folder:ClearAllChildren()

	for buildingId, skinId in pairs(equippedByPlayer[player] or {}) do
		local multiplier = WheelConfig.GetSkinMultiplier(skinId)
		if multiplier > 1 then
			setBuildingSkinMultiplier(player, buildingId, multiplier)
		end
	end
end

-- ── Attribute sync ───────────────────────────────────────────────────────────

local function syncOwnedAttribute(player)
	player:SetAttribute(OWNED_SKINS_ATTRIBUTE, encodeJson(ownedByPlayer[player] or {}))
end

local function syncEquippedAttribute(player)
	player:SetAttribute(EQUIPPED_SKINS_ATTRIBUTE, encodeJson(equippedByPlayer[player] or {}))
end

local function fireInventoryChanged(player)
	Net.fireClient(Net.Names.SkinInventoryChanged, player, ownedByPlayer[player] or {}, equippedByPlayer[player] or {})
end

-- ── Setup / teardown ─────────────────────────────────────────────────────────

function WheelService.SetupPlayer(player, persistent)
	persistent = type(persistent) == "table" and persistent or {}

	local owned = {}
	for skinId, value in pairs(decodeJson(persistent.OwnedSkins)) do
		if value and WheelConfig.GetSkinDef(skinId) then
			owned[skinId] = true
		end
	end

	local equipped = {}
	for buildingId, skinId in pairs(decodeJson(persistent.EquippedSkins)) do
		local def = WheelConfig.GetSkinDef(skinId)
		-- Only restore equips that are still owned and still match their building.
		if def and not def.IsLimited and def.BuildingId == buildingId and owned[skinId] then
			equipped[buildingId] = skinId
		end
	end

	ownedByPlayer[player] = owned
	equippedByPlayer[player] = equipped

	rebuildEquippedSkinData(player)
	syncOwnedAttribute(player)
	syncEquippedAttribute(player)
end

local function forgetPlayer(player)
	ownedByPlayer[player] = nil
	equippedByPlayer[player] = nil
end

-- ── Equip ────────────────────────────────────────────────────────────────────

-- Equips (or, with skinId nil, unequips) a skin for its building. Only one skin
-- per building type — equipping replaces the current one. Validates ownership and
-- that the skin actually belongs to the building.
function WheelService.EquipSkin(player, buildingId, skinId)
	local equipped = equippedByPlayer[player]
	local owned = ownedByPlayer[player]
	if not equipped or not owned then
		return false
	end

	if skinId == nil then
		if buildingId == nil then
			return false
		end
		if equipped[buildingId] == nil then
			return false
		end
		equipped[buildingId] = nil
		setBuildingSkinMultiplier(player, buildingId, 1)
		syncEquippedAttribute(player)
		fireInventoryChanged(player)
		return true
	end

	local def = WheelConfig.GetSkinDef(skinId)
	if not def or def.IsLimited or not def.BuildingId then
		return false
	end

	if buildingId ~= nil and buildingId ~= def.BuildingId then
		return false
	end

	if not owned[skinId] then
		return false
	end

	local targetBuilding = def.BuildingId
	equipped[targetBuilding] = skinId
	setBuildingSkinMultiplier(player, targetBuilding, WheelConfig.GetSkinMultiplier(skinId))
	syncEquippedAttribute(player)
	fireInventoryChanged(player)
	return true
end

-- ── Grant ────────────────────────────────────────────────────────────────────

-- Adds a skin to a player's owned inventory (idempotent). Returns true if newly granted,
-- false if already owned / unknown / player not set up. Used by Spin and by
-- DailyRewardService (the day-7 mythical reward) so granting stays in one place.
function WheelService.GrantSkin(player, skinId)
	local owned = ownedByPlayer[player]
	if not owned or type(skinId) ~= "string" or not WheelConfig.GetSkinDef(skinId) then
		return false
	end
	if owned[skinId] then
		return false
	end

	owned[skinId] = true
	syncOwnedAttribute(player)
	fireInventoryChanged(player)
	return true
end

-- ── Spin ─────────────────────────────────────────────────────────────────────

local function rollReward()
	local rarityId = WheelConfig.RollRarity(random)

	if rarityId == WheelConfig.LimitedRarityId then
		local pool = WheelConfig.LimitedBuildings
		local buildingName = pool[random:NextInteger(1, #pool)]
		return WheelConfig.MakeLimitedSkinId(buildingName)
	end

	local buildings = WheelConfig.EligibleBuildings
	local buildingId = buildings[random:NextInteger(1, #buildings)]
	return WheelConfig.MakeSkinId(buildingId, rarityId)
end

-- Atomic spin transaction: deduct 75 GC, roll, then award the skin or refund a
-- duplicate. Nothing in this function yields, so the deduct and the award commit
-- together. Returns a result table (also fired to the client via SpinResult).
function WheelService.Spin(player)
	local owned = ownedByPlayer[player]
	if not owned then
		return { Success = false, Reason = "NotReady" }
	end

	if not GoldenCookieService.TrySpend(player, WheelConfig.SpinCost) then
		return { Success = false, Reason = "NotEnoughGoldenCookies" }
	end
	PlayerMetricsService.RecordWheelSpin(player)

	local skinId = rollReward()
	local def = WheelConfig.GetSkinDef(skinId)

	local result = {
		Success = true,
		SkinId = skinId,
		RarityId = def and def.RarityId,
		BuildingId = def and def.BuildingId,
		DisplayName = def and def.DisplayName,
		Multiplier = def and def.Multiplier,
		IsLimited = def and def.IsLimited or false,
		IsDuplicate = false,
		RefundGC = 0,
	}

	if owned[skinId] then
		result.IsDuplicate = true
		result.RefundGC = WheelConfig.DuplicateRefundGC
		GoldenCookieService.AddGoldenCookies(player, WheelConfig.DuplicateRefundGC, "refund")
	else
		WheelService.GrantSkin(player, skinId)
	end

	return result
end

function WheelService.Init()
	local Names = Net.Names

	-- Pre-create the server->client push channels so a client that boots first finds them
	-- immediately instead of hanging at WaitForChild until the first spin / inventory sync.
	Net.event(Names.SpinResult)
	Net.event(Names.SkinInventoryChanged)

	Net.on(Names.RequestSpin, function(player)
		local result = WheelService.Spin(player)
		Net.fireClient(Names.SpinResult, player, result)
	end)

	Net.on(Names.EquipSkin, function(player, buildingId, skinId)
		if buildingId ~= nil and type(buildingId) ~= "string" then
			return
		end
		if skinId ~= nil and type(skinId) ~= "string" then
			return
		end
		WheelService.EquipSkin(player, buildingId, skinId)
	end)

	Players.PlayerRemoving:Connect(forgetPlayer)

	print("WheelService initialized")
end

return WheelService
