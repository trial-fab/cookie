local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SkinFeatureConfig = require(ReplicatedStorage.Shared.SkinFeatureConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local GooSkinService = {}
local readyByPlayer = setmetatable({}, { __mode = "k" })

local function encode(value)
	local ok, result = pcall(HttpService.JSONEncode, HttpService, value)
	return ok and result or "{}"
end

local function bestMultiplier(owned)
	local best = 1
	for skinId, isOwned in pairs(owned or {}) do
		if isOwned then
			best = math.max(best, GooSkinConfig.GetMultiplier(skinId))
		end
	end
	return best
end

local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function snapshotFromPersistent(persistent)
	local owned = persistent.OwnedGooSkins
	return {
		Owned = owned,
		SelectedSkinId = persistent.SelectedGooSkin,
		BestMultiplier = bestMultiplier(owned),
	}
end

local function publish(player, persistent, push)
	local state = snapshotFromPersistent(persistent)
	player:SetAttribute(Attrs.OwnedGooSkinsJson, encode(state.Owned))
	player:SetAttribute(Attrs.SelectedGooSkinId, state.SelectedSkinId)
	player:SetAttribute(Attrs.GooSkinMultiplier, SkinFeatureConfig.GooSkinsEnabled and state.BestMultiplier or 1)
	if push then
		Net.fireClient(Net.Names.GooSkinInventoryChanged, player, state)
	end
	return state
end

function GooSkinService.SetupPlayer(player)
	readyByPlayer[player] = nil
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end

	local owned = { [GooSkinConfig.DefaultSkinId] = true }
	for skinId, value in pairs(type(persistent.OwnedGooSkins) == "table" and persistent.OwnedGooSkins or {}) do
		if value and GooSkinConfig.GetSkinDef(skinId) then
			owned[skinId] = true
		end
	end
	local selected = persistent.SelectedGooSkin
	if not (type(selected) == "string" and owned[selected] and GooSkinConfig.GetSkinDef(selected)) then
		selected = GooSkinConfig.DefaultSkinId
	end
	persistent.OwnedGooSkins = owned
	persistent.SelectedGooSkin = selected
	readyByPlayer[player] = true
	publish(player, persistent, false)
	return true
end

function GooSkinService.GrantSkin(player, skinId)
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local owned = persistent and persistent.OwnedGooSkins
	if not owned or not GooSkinConfig.GetSkinDef(skinId) or owned[skinId] then
		return false
	end
	owned[skinId] = true
	publish(player, persistent, true)
	return true
end

function GooSkinService.SelectSkin(player, skinId)
	if not SkinFeatureConfig.GooSkinsEnabled then
		return { Success = false, Reason = "Disabled" }
	end
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local owned = persistent and persistent.OwnedGooSkins
	if not owned then
		return { Success = false, Reason = "NotReady" }
	end
	if type(skinId) ~= "string" or not owned[skinId] or not GooSkinConfig.GetSkinDef(skinId) then
		return { Success = false, Reason = "NotOwned" }
	end
	persistent.SelectedGooSkin = skinId
	-- Selection has one authoritative response path. Ownership grants still push, but this
	-- invoke does not also send an equivalent inventory event that would race its reply.
	local state = publish(player, persistent, false)
	state.Success = true
	return state
end

function GooSkinService.IsReady(player)
	return readyByPlayer[player] == true and getPersistent(player) ~= nil
end

function GooSkinService.IsOwned(player, skinId)
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local owned = persistent and persistent.OwnedGooSkins
	return type(owned) == "table" and owned[skinId] == true
end

-- Passive readers degrade safely during setup/session loss rather than treating a projection
-- or stale cache as authority.
function GooSkinService.GetSelectedSkinId(player)
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	local selected = persistent and persistent.SelectedGooSkin
	if type(selected) == "string" and GooSkinConfig.GetSkinDef(selected) then
		return selected
	end
	return GooSkinConfig.DefaultSkinId
end

function GooSkinService.GetBestMultiplier(player)
	if not SkinFeatureConfig.GooSkinsEnabled then
		return 1
	end
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	return persistent and bestMultiplier(persistent.OwnedGooSkins) or 1
end

function GooSkinService.ForgetPlayer(player)
	readyByPlayer[player] = nil
end

function GooSkinService.Init()
	Net.event(Net.Names.GooSkinInventoryChanged)
	Net.onInvoke(Net.Names.SelectGooSkin, function(player, skinId)
		return GooSkinService.SelectSkin(player, skinId)
	end)
end

return GooSkinService
