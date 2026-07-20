-- MonetizationService: the server half of the Robux store. Owns MarketplaceService.ProcessReceipt
-- (developer products) and game-pass grants, dispatching each purchase to a grant handler keyed
-- by the MonetizationConfig item Id.
--
-- Developer-product receipts live inside the buyer's session-locked Profile Data. A receipt is
-- acknowledged only after its exact ID appears in a correlated successful LastSavedData snapshot.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostService = require(ServerScriptService.Services.BoostService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local MonetizationConfig = require(ReplicatedStorage.Shared.MonetizationConfig)

local MonetizationService = {}

-- Developer-product delivery descriptors are intentionally separate from game passes. A future
-- profile-owned grant must be a yield-free owning-service operation that validates before its
-- first mutation and cannot fail after partially committing canonical state. It does not inherit
-- Server Boost's explicit external at-least-once exception.
local devProductDeliveryByItemId = {
	ServerBoost = {
		ExternalAtLeastOnce = true,
		Grant = function()
			-- Favor-the-buyer policy: activation precedes recording/saving. A retry of an
			-- unconfirmed ID activates again and may extend the server another five minutes.
			BoostService.Activate(2, 300)
			return true
		end,
	},
}

local gamePassGrantByItemId = {
	InstantWheelSpinPass = function(player)
		player:SetAttribute(Attrs.InstantWheelSpinEnabled, true)
	end,
}

local devProductItemsByProductId = {}
local gamePassItemsByProductId = {}
local processingByUserId = {}

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

local function acquireProcessing(userId)
	while processingByUserId[userId] do
		processingByUserId[userId].Event:Wait()
	end
	local released = Instance.new("BindableEvent")
	processingByUserId[userId] = released
	return function()
		if processingByUserId[userId] == released then
			processingByUserId[userId] = nil
			released:Fire()
		end
		released:Destroy()
	end
end

local function processReceiptLocked(receipt, item, delivery)
	-- Acquiring the per-user coordinator yielded, so every live object and state decision is
	-- deliberately re-resolved here.
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local state, purchaseId, data = PlayerDataService.GetReceiptState(player, receipt.PurchaseId)
	if state == PlayerDataService.ReceiptState.Persisted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if
		state ~= PlayerDataService.ReceiptState.Absent
		and state ~= PlayerDataService.ReceiptState.PresentUnconfirmed
	then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- A present-but-unconfirmed profile grant is never applied twice. Server Boost is the sole
	-- approved exception: reactivation before another save attempt guarantees no purchase is
	-- acknowledged without an activation, at the accepted cost of possible over-delivery.
	if state == PlayerDataService.ReceiptState.Absent or delivery.ExternalAtLeastOnce == true then
		local grantCallOk, granted = pcall(delivery.Grant, player, receipt, data)
		if not grantCallOk or granted ~= true then
			warn(("MonetizationService: grant failed for %s"):format(tostring(item.Id)))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	if state == PlayerDataService.ReceiptState.Absent then
		local recorded = PlayerDataService.RecordReceipt(player, purchaseId, data)
		if not recorded then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	local confirmed = PlayerDataService.ConfirmReceiptSaved(player, purchaseId)
	return confirmed and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receipt)
	local item = devProductItemsByProductId[receipt.ProductId]
	local delivery = item and item.Enabled == true and devProductDeliveryByItemId[item.Id] or nil
	if not delivery then
		warn(("MonetizationService: no grant handler for ProductId %s"):format(tostring(receipt.ProductId)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not Players:GetPlayerByUserId(receipt.PlayerId) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local release = acquireProcessing(receipt.PlayerId)
	local ok, decision = pcall(processReceiptLocked, receipt, item, delivery)
	release()
	if not ok then
		warn(("MonetizationService: receipt processing failed: %s"):format(tostring(decision)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

local function grantOwnedGamePass(player, gamePassItem)
	local grant = gamePassGrantByItemId[gamePassItem.Id]
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
