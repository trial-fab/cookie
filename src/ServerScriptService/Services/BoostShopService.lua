-- BoostShopService: authoritative gem purchases at the central Hub boost stall.
--
-- One purchase spends the item's gem price and grants one consumable field charge, capped at
-- BoostShopConfig's per-type stack cap (1 at launch). Charges live in Persistent data, so they
-- survive run resets and rejoins alongside the gem balance that bought them.
--
-- Data-first, like GemService: `PlayerDataService` Data is canonical and the per-item
-- `*FieldCharges` Player attributes are replication projections the client reads for the purchase
-- window's Owned / stack-full state. Nothing trusts a client-supplied balance, count, or price.
--
-- The check/spend/grant path is deliberately yield-free, so two invokes racing on one player can
-- never both pass the cap check or spend the same gems twice.
--
-- Out of scope here (the next build): equipping a charge, dropping the field, its radius/timer,
-- and expiry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local BoostShopConfig = require(ReplicatedStorage.Shared.BoostShopConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local GemService = require(script.Parent.GemService)
local PlayerDataService = require(script.Parent.PlayerDataService)

local BoostShopService = {}

local function getPersistent(player)
	local data = player and PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

-- Charges are stored as one itemId -> count map so a new boost item needs no schema change.
local function getCharges(persistent)
	local charges = persistent.BoostCharges
	if type(charges) ~= "table" then
		charges = {}
		persistent.BoostCharges = charges
	end
	return charges
end

local function readCharge(persistent, item)
	local count = math.floor(tonumber(getCharges(persistent)[item.Id]) or 0)
	return math.clamp(count, 0, item.StackCap)
end

local function writeCharge(player, persistent, item, count)
	count = math.clamp(math.floor(count), 0, item.StackCap)
	getCharges(persistent)[item.Id] = count
	player:SetAttribute(item.OwnedAttribute, count)
	return count
end

-- Projects every item's stored count onto its attribute at join. Also normalizes a saved value
-- that predates a stack-cap change (or was written by an older build) down to the current cap.
function BoostShopService.SetupPlayer(player, persistent)
	if type(persistent) ~= "table" then
		return
	end
	for _, id in ipairs(BoostShopConfig.Order) do
		local item = BoostShopConfig.Items[id]
		writeCharge(player, persistent, item, readCharge(persistent, item))
	end
end

function BoostShopService.GetCharges(player, itemId)
	local item = BoostShopConfig.Items[itemId]
	local persistent = item and getPersistent(player)
	return persistent and readCharge(persistent, item) or 0
end

-- Consumes one charge (the equip/field-drop build's entry point). Returns the remaining count,
-- or nil when the player holds none.
function BoostShopService.ConsumeCharge(player, itemId)
	local item = BoostShopConfig.Items[itemId]
	local persistent = item and getPersistent(player)
	if not persistent then
		return nil
	end

	local owned = readCharge(persistent, item)
	if owned <= 0 then
		return nil
	end
	return writeCharge(player, persistent, item, owned - 1)
end

-- Drops every held charge. Yield-free so the dev onboarding reset can group it with its other
-- canonical persistent mutations. Returns false when the player has no active profile.
function BoostShopService.ClearCharges(player)
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end

	for _, id in ipairs(BoostShopConfig.Order) do
		writeCharge(player, persistent, BoostShopConfig.Items[id], 0)
	end
	return true
end

-- Authoritative purchase. Returns success, message, remaining charge count.
function BoostShopService.Purchase(player, itemId)
	local item = BoostShopConfig.Items[itemId]
	if not item then
		return false, "Unknown boost."
	end

	local persistent = getPersistent(player)
	if not persistent then
		return false, "Your data is still loading."
	end

	local owned = readCharge(persistent, item)
	if owned >= item.StackCap then
		return false, ("Inventory full (%d / %d)"):format(owned, item.StackCap), owned
	end

	-- TrySpend is the only balance authority: it re-reads canonical Data, so a stale attribute
	-- or a forged client price cannot buy anything.
	if not GemService.TrySpend(player, item.PriceGems) then
		return false, "Not enough gems.", owned
	end

	local remaining = writeCharge(player, persistent, item, owned + 1)
	return true, ("%s purchased."):format(item.DisplayName), remaining
end

function BoostShopService.Init()
	Net.onInvoke(Net.Names.PurchaseBoostItem, function(player, itemId)
		if type(itemId) ~= "string" then
			return { success = false, message = "Unknown boost." }
		end

		local success, message, owned = BoostShopService.Purchase(player, itemId)
		return {
			success = success,
			message = message,
			itemId = itemId,
			owned = owned,
			gems = player:GetAttribute(Attrs.Gems),
		}
	end)

	print("BoostShopService initialized")
end

return BoostShopService
