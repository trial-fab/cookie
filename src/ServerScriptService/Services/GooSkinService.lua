local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local GooSkinConfig = require(ReplicatedStorage.Shared.GooSkinConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local SkinFeatureConfig = require(ReplicatedStorage.Shared.SkinFeatureConfig)

local GooSkinService = {}
local ownedByPlayer = {}
local selectedByPlayer = {}

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

local function snapshot(player)
	local owned = ownedByPlayer[player] or {}
	return {
		Owned = owned,
		SelectedSkinId = selectedByPlayer[player] or GooSkinConfig.DefaultSkinId,
		BestMultiplier = bestMultiplier(owned),
	}
end

local function sync(player, push)
	local state = snapshot(player)
	player:SetAttribute(Attrs.OwnedGooSkinsJson, encode(state.Owned))
	player:SetAttribute(Attrs.SelectedGooSkinId, state.SelectedSkinId)
	player:SetAttribute(Attrs.GooSkinMultiplier, SkinFeatureConfig.GooSkinsEnabled and state.BestMultiplier or 1)
	if push then
		Net.fireClient(Net.Names.GooSkinInventoryChanged, player, state)
	end
	return state
end

function GooSkinService.SetupPlayer(player, persistent)
	persistent = type(persistent) == "table" and persistent or {}
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
	ownedByPlayer[player] = owned
	selectedByPlayer[player] = selected
	return sync(player, false)
end

function GooSkinService.GrantSkin(player, skinId)
	local owned = ownedByPlayer[player]
	if not owned or not GooSkinConfig.GetSkinDef(skinId) or owned[skinId] then
		return false
	end
	owned[skinId] = true
	sync(player, true)
	return true
end

function GooSkinService.SelectSkin(player, skinId)
	local owned = ownedByPlayer[player]
	if not SkinFeatureConfig.GooSkinsEnabled then
		return { Success = false, Reason = "Disabled" }
	end
	if not owned then
		return { Success = false, Reason = "NotReady" }
	end
	if type(skinId) ~= "string" or not owned[skinId] or not GooSkinConfig.GetSkinDef(skinId) then
		return { Success = false, Reason = "NotOwned" }
	end
	selectedByPlayer[player] = skinId
	-- Selection has one authoritative response path. Ownership grants still push, but this
	-- invoke does not also send an equivalent inventory event that would race its reply.
	local state = sync(player, false)
	state.Success = true
	return state
end

function GooSkinService.GetOwned(player)
	return ownedByPlayer[player]
end

function GooSkinService.GetSnapshot(player)
	return snapshot(player)
end

function GooSkinService.ForgetPlayer(player)
	ownedByPlayer[player] = nil
	selectedByPlayer[player] = nil
end

function GooSkinService.Init()
	Net.event(Net.Names.GooSkinInventoryChanged)
	Net.onInvoke(Net.Names.SelectGooSkin, function(player, skinId)
		return GooSkinService.SelectSkin(player, skinId)
	end)
end

return GooSkinService
