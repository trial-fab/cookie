local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local XpConfig = require(ReplicatedStorage.Shared.XpConfig)

local XpService = {}

local function getXp(player)
	local value = player:GetAttribute(Attrs.Xp)
	if typeof(value) == "number" then
		return math.max(0, math.floor(value))
	end
	return 0
end

function XpService.GetXp(player)
	return getXp(player)
end

function XpService.AddXp(player, amount, _source, _metadata)
	amount = math.floor(tonumber(amount) or 0)
	if not player then
		return 0
	end
	if amount <= 0 or not player.Parent then
		return getXp(player)
	end

	local total = getXp(player) + amount
	player:SetAttribute(Attrs.Xp, total)
	return total
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

local function setupPlayer(player)
	if player:GetAttribute(Attrs.Xp) == nil then
		player:SetAttribute(Attrs.Xp, 0)
	end
end

function XpService.Init()
	Players.PlayerAdded:Connect(setupPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	print("XpService initialized")
end

return XpService
