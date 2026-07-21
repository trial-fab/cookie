-- GemService: authoritative persistent balance for the deterministic boost-shop currency.
-- Gems survive run resets. Every positive grant carries presentation metadata so the client can
-- animate from the real reward source without trusting the client to mutate the balance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local Net = require(ReplicatedStorage.Shared.Net)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)

local GemService = {}

local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function readBalance(persistent)
	return math.max(0, math.floor(tonumber(persistent.Gems) or 0))
end

function GemService.GetGems(player)
	local persistent = getPersistent(player)
	return persistent and readBalance(persistent) or 0
end

-- Corrections/setup writes do not create earn presentation. Use AddGems for player-visible grants.
function GemService.SetGems(player, amount)
	local persistent = getPersistent(player)
	if not persistent then
		return nil
	end

	persistent.Gems = math.max(0, math.floor(tonumber(amount) or 0))
	player:SetAttribute(Attrs.Gems, persistent.Gems)
	return persistent.Gems
end

function GemService.AddGems(player, amount, source, sourceAnchor)
	amount = math.floor(tonumber(amount) or 0)
	if amount == 0 then
		local persistent = getPersistent(player)
		return persistent and readBalance(persistent) or nil
	end

	local persistent = getPersistent(player)
	if not persistent then
		return nil
	end

	local previousTotal = readBalance(persistent)
	local newTotal = math.max(0, previousTotal + amount)
	local granted = newTotal - previousTotal
	persistent.Gems = newTotal
	player:SetAttribute(Attrs.Gems, newTotal)

	if granted > 0 then
		PlayerMetricsService.RecordGemsEarned(player, granted, source)
		Net.fireClient(Net.Names.GemEarned, player, granted, source or "unknown", newTotal, sourceAnchor)
	end

	return newTotal
end

-- Yield-free read/check/write. Future boost purchases and products must call this rather than
-- trusting a replicated attribute or a client-supplied balance.
function GemService.TrySpend(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return false
	end

	local persistent = getPersistent(player)
	if not persistent then
		return false
	end

	local balance = readBalance(persistent)
	if balance < amount then
		return false
	end

	persistent.Gems = balance - amount
	player:SetAttribute(Attrs.Gems, persistent.Gems)
	PlayerMetricsService.RecordGemsSpent(player, amount)
	return true
end

function GemService.Init()
	Net.event(Net.Names.GemEarned)
	print("GemService initialized")
end

return GemService
