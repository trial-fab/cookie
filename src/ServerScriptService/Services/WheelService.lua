-- Server-authoritative wheel transaction. Goo skins are active; building skins are retained
-- behind their own disabled service for a future combined collection.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildingSkinConfig = require(ReplicatedStorage.Shared.BuildingSkinConfig)
local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)
local GooSkinAssets = require(ReplicatedStorage.Shared.GooSkinAssets)
local Net = require(ReplicatedStorage.Shared.Net)
local SkinFeatureConfig = require(ReplicatedStorage.Shared.SkinFeatureConfig)
local WheelConfig = require(ReplicatedStorage.Shared.WheelConfig)
local BuildingSkinService = require(script.Parent.BuildingSkinService)
local GoldenCookieService = require(script.Parent.GoldenCookieService)
local GooSkinService = require(script.Parent.GooSkinService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)

local WheelService = {}
local random = Random.new()
local configurationReady = false

function WheelService.SetupPlayer(player, persistent)
	BuildingSkinService.SetupPlayer(player, persistent)
	GooSkinService.SetupPlayer(player, persistent)
end

function WheelService.EquipSkin(player, buildingId, skinId)
	return BuildingSkinService.EquipSkin(player, buildingId, skinId)
end

function WheelService.GrantSkin(player, skinId)
	if GooSkinConfig.GetSkinDef(skinId) then
		return GooSkinService.GrantSkin(player, skinId)
	end
	if BuildingSkinConfig.GetSkinDef(skinId) then
		return BuildingSkinService.GrantSkin(player, skinId)
	end
	return false
end

local function rollReward()
	local rarityId = WheelConfig.RollRarity(random)
	local pool = WheelConfig.GetRollableGooSkins(rarityId)
	if #pool == 0 then
		return nil, ("No rollable goo skins configured for %s"):format(rarityId)
	end
	return pool[random:NextInteger(1, #pool)]
end

local function validateConfiguration()
	local errors = GooSkinConfig.ValidateDefinitions()
	local seenRarities = {}
	local assetErrors, assetWarnings = GooSkinAssets.Validate()
	for _, message in ipairs(assetErrors) do
		table.insert(errors, message)
	end
	for _, message in ipairs(assetWarnings) do
		warn("WheelService config warning: " .. message)
	end
	for _, rarity in ipairs(WheelConfig.Rarities) do
		if type(rarity.Id) ~= "string" or rarity.Id == "" or seenRarities[rarity.Id] then
			table.insert(errors, ("Wheel rarity ID must be nonempty and unique: %s"):format(tostring(rarity.Id)))
		end
		seenRarities[rarity.Id] = true
		if type(rarity.Weight) ~= "number" or rarity.Weight <= 0 then
			table.insert(errors, ("Wheel rarity %s must have a positive weight"):format(tostring(rarity.Id)))
		end
	end
	for _, message in ipairs(errors) do
		warn("WheelService config error: " .. message)
	end
	return #errors == 0
end

function WheelService.Spin(player)
	if not SkinFeatureConfig.GooSkinsEnabled then
		return { Success = false, Reason = "Disabled" }
	end
	if not configurationReady then
		return { Success = false, Reason = "ConfigurationUnavailable" }
	end
	if not GooSkinService.GetOwned(player) then
		return { Success = false, Reason = "NotReady" }
	end

	-- Prepare a valid, server-private outcome first. A bad config cannot consume GC, and
	-- an outcome prepared for a player who cannot pay is simply discarded without leaking.
	local ok, def, rollError = pcall(rollReward)
	if not ok then
		warn("WheelService roll failed: " .. tostring(def))
		return { Success = false, Reason = "ConfigurationUnavailable" }
	end
	if not def then
		warn("WheelService roll failed: " .. tostring(rollError))
		return { Success = false, Reason = "ConfigurationUnavailable" }
	end
	if not GoldenCookieService.TrySpend(player, WheelConfig.SpinCost) then
		return { Success = false, Reason = "NotEnoughGoldenCookies" }
	end
	PlayerMetricsService.RecordWheelSpin(player)

	local owned = GooSkinService.GetOwned(player)
	local duplicate = owned[def.Id] == true
	if duplicate then
		GoldenCookieService.AddGoldenCookies(player, WheelConfig.DuplicateRefundGC, "refund")
	else
		GooSkinService.GrantSkin(player, def.Id)
	end

	return {
		Success = true,
		SkinId = def.Id,
		SkinKind = def.Kind,
		RarityId = def.RarityId,
		DisplayName = def.DisplayName,
		Multiplier = def.Multiplier,
		IsLimited = def.IsLimited == true,
		IsDuplicate = duplicate,
		RefundGC = duplicate and WheelConfig.DuplicateRefundGC or 0,
	}
end

function WheelService.Init()
	configurationReady = validateConfiguration()
	GooSkinService.Init()
	Net.event(Net.Names.SpinResult)
	Net.event(Net.Names.SkinInventoryChanged)
	Net.on(Net.Names.RequestSpin, function(player)
		Net.fireClient(Net.Names.SpinResult, player, WheelService.Spin(player))
	end)
	Net.on(Net.Names.EquipSkin, function(player, buildingId, skinId)
		if buildingId ~= nil and type(buildingId) ~= "string" then
			return
		end
		if skinId ~= nil and type(skinId) ~= "string" then
			return
		end
		BuildingSkinService.EquipSkin(player, buildingId, skinId)
	end)
	Players.PlayerRemoving:Connect(function(player)
		GooSkinService.ForgetPlayer(player)
		BuildingSkinService.ForgetPlayer(player)
	end)
	print("WheelService initialized")
end

return WheelService
