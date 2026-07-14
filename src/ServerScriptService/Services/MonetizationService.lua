-- MonetizationService: the server half of the Robux store. Owns MarketplaceService.ProcessReceipt
-- (developer products) and game-pass grants, dispatching each purchase to a grant handler keyed
-- by the MonetizationConfig item Id.
--
-- ProcessReceipt is idempotent: every (PlayerId, PurchaseId) is recorded in a DataStore so a
-- grant is applied at most once even though Roblox re-delivers receipts until acknowledged.
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostService = require(ServerScriptService.Services.BoostService)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)

local MonetizationService = {}

local receiptStore = DataStoreService:GetDataStore("ReceiptHistory_v1")

-- Grant handlers keyed by MonetizationConfig item Id. Add an entry here when a product/pass
-- goes live; a product with no handler is left un-granted (NotProcessedYet) so it can be added
-- and retried without losing the purchase.
local grantByItemId = {
	ServerBoost = function()
		BoostService.Activate(2, 300)
	end,
	InstantWheelSpinPass = function(player)
		player:SetAttribute(Attrs.InstantWheelSpinEnabled, true)
	end,
	-- StarterCookiePack / CookieVault grants land when those products are enabled.
}

local devProductItemsByProductId = {}
local gamePassItemsByProductId = {}

local function buildLookups()
	table.clear(devProductItemsByProductId)
	table.clear(gamePassItemsByProductId)
	for _, item in ipairs(MonetizationConfig.Items) do
		if item.ProductId then
			if item.Kind == "GamePass" then
				gamePassItemsByProductId[item.ProductId] = item
			else
				devProductItemsByProductId[item.ProductId] = item
			end
		end
	end
end

local function processReceipt(receipt)
	local key = string.format("%d_%d", receipt.PlayerId, receipt.PurchaseId)

	-- Idempotency: if we've already recorded this receipt as granted, just acknowledge it.
	local readOk, alreadyGranted = pcall(function()
		return receiptStore:GetAsync(key) == true
	end)
	if not readOk then
		-- Can't confirm history; tell Roblox to retry later rather than risk a double grant.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if alreadyGranted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- Buyer left before we could grant; retry when they're back.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local item = devProductItemsByProductId[receipt.ProductId]
	local grant = item and grantByItemId[item.Id]
	if not grant then
		warn(("MonetizationService: no grant handler for ProductId %s"):format(tostring(receipt.ProductId)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local grantOk = pcall(grant, player, receipt)
	if not grantOk then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Persist the grant before acknowledging so retries can't double-apply it.
	local saveOk = pcall(function()
		receiptStore:SetAsync(key, true)
	end)
	if not saveOk then
		-- Granted but couldn't persist. Acknowledge anyway to avoid repeat grants on retry;
		-- the trade-off is a lost history record, acceptable for these consumables.
		warn(("MonetizationService: granted but failed to persist receipt %s"):format(key))
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function grantOwnedGamePass(player, gamePassItem)
	local grant = grantByItemId[gamePassItem.Id]
	if grant then
		pcall(grant, player)
	end
end

function MonetizationService.Init()
	buildLookups()

	MarketplaceService.ProcessReceipt = processReceipt

	-- Grant a game pass the moment it's bought.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then
			return
		end
		local item = gamePassItemsByProductId[gamePassId]
		if item then
			grantOwnedGamePass(player, item)
		end
	end)

	-- Re-apply any game passes a player already owns on join.
	local function applyOwnedGamePasses(player)
		for _, item in pairs(gamePassItemsByProductId) do
			local owns = false
			pcall(function()
				owns = MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.ProductId)
			end)
			if owns then
				grantOwnedGamePass(player, item)
			end
		end
	end

	Players.PlayerAdded:Connect(applyOwnedGamePasses)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(applyOwnedGamePasses, player)
	end
end

return MonetizationService
