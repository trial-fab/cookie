local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local BuildingSkinConfig = require(ReplicatedStorage.Shared.BuildingSkinConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SkinFeatureConfig = require(ReplicatedStorage.Shared.SkinFeatureConfig)

local BuildingSkinService = {}
local ownedByPlayer, equippedByPlayer = {}, {}

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
local function publish(player)
	local folder = folderFor(player)
	folder:ClearAllChildren()
	if SkinFeatureConfig.BuildingSkinsEnabled then
		for buildingId, skinId in pairs(equippedByPlayer[player] or {}) do
			local multiplier = BuildingSkinConfig.GetMultiplier(skinId)
			if multiplier > 1 then
				local value = Instance.new("NumberValue")
				value.Name, value.Value, value.Parent = buildingId, multiplier, folder
			end
		end
	end
	player:SetAttribute(Attrs.OwnedSkinsJson, encode(ownedByPlayer[player] or {}))
	player:SetAttribute(Attrs.EquippedSkinsJson, encode(equippedByPlayer[player] or {}))
	Net.fireClient(Net.Names.SkinInventoryChanged, player, ownedByPlayer[player] or {}, equippedByPlayer[player] or {})
end

function BuildingSkinService.SetupPlayer(player, persistent)
	persistent = type(persistent) == "table" and persistent or {}
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
	ownedByPlayer[player], equippedByPlayer[player] = owned, equipped
	publish(player)
end

function BuildingSkinService.GrantSkin(player, skinId)
	local owned = ownedByPlayer[player]
	if not owned or not BuildingSkinConfig.GetSkinDef(skinId) or owned[skinId] then
		return false
	end
	owned[skinId] = true
	publish(player)
	return true
end

function BuildingSkinService.EquipSkin(player, buildingId, skinId)
	if not SkinFeatureConfig.BuildingSkinsEnabled then
		return false
	end
	local owned, equipped = ownedByPlayer[player], equippedByPlayer[player]
	if not owned or not equipped or type(buildingId) ~= "string" then
		return false
	end
	if skinId == nil then
		equipped[buildingId] = nil
		publish(player)
		return true
	end
	local def = BuildingSkinConfig.GetSkinDef(skinId)
	if not def or def.BuildingId ~= buildingId or not owned[skinId] then
		return false
	end
	equipped[buildingId] = skinId
	publish(player)
	return true
end

function BuildingSkinService.ForgetPlayer(player)
	ownedByPlayer[player], equippedByPlayer[player] = nil, nil
end

return BuildingSkinService
