local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local XpConfig = require(ReplicatedStorage.Shared.XpConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local XpService = {}

local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function readXp(persistent)
	return math.max(0, math.floor(tonumber(persistent.Xp) or 0))
end

function XpService.GetXp(player)
	local persistent = getPersistent(player)
	return persistent and readXp(persistent) or 0
end

function XpService.AddXp(player, amount, _source, _metadata)
	amount = math.floor(tonumber(amount) or 0)
	if not player then
		return 0
	end
	if amount <= 0 or not player.Parent then
		return XpService.GetXp(player)
	end

	local persistent = getPersistent(player)
	if not persistent then
		return 0
	end

	persistent.Xp = readXp(persistent) + amount
	player:SetAttribute(Attrs.Xp, persistent.Xp)
	return persistent.Xp
end

function XpService.AwardClick(player)
	return XpService.AddXp(player, XpConfig.Sources.ManualClick, "click")
end

function XpService.AwardBuildingUnlock(player, upgradeId, config)
	return XpService.AddXp(player, XpConfig.GetBuildingUnlockXp(upgradeId, config), "buildingUnlock", {
		upgradeId = upgradeId,
	})
end

function XpService.AwardQuest(player, questId, amount)
	return XpService.AddXp(player, amount, "quest", {
		questId = questId,
	})
end

function XpService.Init()
	print("XpService initialized")
end

return XpService
