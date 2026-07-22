-- Server-authoritative title selection. Levels unlock titles; an empty selected ID keeps the
-- player in auto mode so the newest unlocked title follows XP automatically.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local Net = require(ReplicatedStorage.Shared.Net)
local XpConfig = require(ReplicatedStorage.Shared.XpConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local TitleService = {}
local readyByPlayer = setmetatable({}, { __mode = "k" })

local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function getLevel(persistent)
	return XpConfig.GetLevelInfo(persistent and persistent.Xp).level
end

local function publish(player, persistent)
	player:SetAttribute(Attrs.SelectedTitleId, persistent.SelectedTitleId)
	local info = XpConfig.GetLevelInfo(persistent.Xp, persistent.SelectedTitleId)
	return {
		SelectedTitleId = info.selectedTitleId,
		EquippedTitleId = info.titleId,
		AutoEquip = info.autoEquipTitle,
	}
end

function TitleService.SetupPlayer(player, persistent)
	readyByPlayer[player] = nil
	if type(persistent) ~= "table" then
		return false
	end

	persistent.SelectedTitleId = XpConfig.NormalizeSelectedTitleId(persistent.SelectedTitleId, getLevel(persistent))
	readyByPlayer[player] = true
	publish(player, persistent)
	return true
end

function TitleService.SelectTitle(player, titleId)
	local persistent = readyByPlayer[player] and getPersistent(player) or nil
	if not persistent then
		return { Success = false, Reason = "NotReady" }
	end
	if type(titleId) ~= "string" then
		return { Success = false, Reason = "InvalidTitle" }
	end

	local normalized = XpConfig.NormalizeSelectedTitleId(titleId, getLevel(persistent))
	if titleId ~= XpConfig.AutoTitleId and normalized ~= titleId then
		return { Success = false, Reason = "Locked" }
	end

	persistent.SelectedTitleId = normalized
	local state = publish(player, persistent)
	state.Success = true
	return state
end

function TitleService.Init()
	Net.onInvoke(Net.Names.SelectTitle, function(player, titleId)
		return TitleService.SelectTitle(player, titleId)
	end)
end

return TitleService
