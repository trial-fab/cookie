local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local BuildingSkinConfig = require(ReplicatedStorage.Shared.BuildingSkinConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SkinFeatureConfig = require(ReplicatedStorage.Shared.SkinFeatureConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local BuildingSkinService = {}
local readyByPlayer = setmetatable({}, { __mode = "k" })

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or "{}"
end
local function folderFor(player)
	local folder = player:FindFirstChild("EquippedSkinData")
	if not folder then
		folder = Instance.new("Configuration")
		folder.Name = "EquippedSkinData"
		folder.Parent = player
	end
	return folder
end
local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end
local function publish(player, persistent)
	local folder = folderFor(player)
	folder:ClearAllChildren()
	if SkinFeatureConfig.BuildingSkinsEnabled then
		for buildingId, skinId in pairs(persistent.EquippedSkins) do
			local multiplier = BuildingSkinConfig.GetMultiplier(skinId)
			if multiplier > 1 then
				local value = Instance.new("NumberValue")
				value.Name, value.Value, value.Parent = buildingId, multiplier, folder
			end
		end
	end
	player:SetAttribute(Attrs.OwnedSkinsJson, encode(persistent.OwnedSkins))
	player:SetAttribute(Attrs.EquippedSkinsJson, encode(persistent.EquippedSkins))
	Net.fireClient(Net.Names.SkinInventoryChanged, player, persistent.OwnedSkins, persistent.EquippedSkins)
end

function BuildingSkinService.SetupPlayer(player)
	readyByPlayer[player] = nil
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end

	local owned, equipped = {}, {}
	for id, value in pairs(type(persistent.OwnedSkins) == "table" and persistent.OwnedSkins or {}) do
		if value and BuildingSkinConfig.GetSkinDef(id) then
			owned[id] = true
		end
	end
	for buildingId, id in pairs(type(persistent.EquippedSkins) == "table" and persistent.EquippedSkins or {}) do
		local def = BuildingSkinConfig.GetSkinDef(id)
		if def and def.BuildingId == buildingId and owned[id] then
			equipped[buildingId] = id
		end
	end
	persistent.OwnedSkins = owned
	persistent.EquippedSkins = equipped
	readyByPlayer[player] = true
	publish(player, persistent)
	return true
end

function BuildingSkinService.GrantSkin(player, skinId)
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local owned = persistent and persistent.OwnedSkins
	if not owned or not BuildingSkinConfig.GetSkinDef(skinId) or owned[skinId] then
		return false
	end
	owned[skinId] = true
	publish(player, persistent)
	return true
end

function BuildingSkinService.EquipSkin(player, buildingId, skinId)
	if not SkinFeatureConfig.BuildingSkinsEnabled then
		return false
	end
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local owned = persistent and persistent.OwnedSkins
	local equipped = persistent and persistent.EquippedSkins
	if not owned or not equipped or type(buildingId) ~= "string" then
		return false
	end
	if skinId == nil then
		equipped[buildingId] = nil
		publish(player, persistent)
		return true
	end
	local def = BuildingSkinConfig.GetSkinDef(skinId)
	if not def or def.BuildingId ~= buildingId or not owned[skinId] then
		return false
	end
	equipped[buildingId] = skinId
	publish(player, persistent)
	return true
end

function BuildingSkinService.GetProductionMultiplier(player, buildingId)
	if not SkinFeatureConfig.BuildingSkinsEnabled then
		return 1
	end
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local skinId = persistent and persistent.EquippedSkins and persistent.EquippedSkins[buildingId]
	return skinId and BuildingSkinConfig.GetMultiplier(skinId) or 1
end

function BuildingSkinService.ForgetPlayer(player)
	readyByPlayer[player] = nil
end

return BuildingSkinService
