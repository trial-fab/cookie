-- BoostShopController — the central Hub boost stall: counter prompt -> purchase window -> buy.
--
-- Thin orchestrator over two modules:
--   BoostShopPrompts   — world side (finds the stall, wires each canister's ViewPrompt + highlight)
--   BoostPurchaseModal — the Studio-authored BoostPurchaseConfirm window and its live states
--
-- Buy invokes the server (BoostShopService owns the gem spend and the charge grant); this side
-- only reports the result. The window closes on a successful purchase and keeps the server's own
-- message on a rejection, so the player never sees a client-invented reason for a failed buy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local BoostFieldPlacement = require(script.Parent:WaitForChild("BoostFieldPlacement"))
local BoostFieldLabels = require(script.Parent:WaitForChild("BoostFieldLabels"))
local BoostFieldPulse = require(script.Parent:WaitForChild("BoostFieldPulse"))
local BoostHotbarSlots = require(script.Parent:WaitForChild("BoostHotbarSlots"))
local BoostPurchaseModal = require(script.Parent:WaitForChild("BoostPurchaseModal"))
local BoostShopPrompts = require(script.Parent:WaitForChild("BoostShopPrompts"))

local FAILED_MESSAGE = "Purchase failed. Please try again."

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("BoostShopController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("BoostShopControllerRunning") then
	return
end
screenGui:SetAttribute("BoostShopControllerRunning", true)

-- Declared before the constructor so `onConfirm` closes over this local (not a stray global).
local modal
modal = BoostPurchaseModal.new({
	screenGui = screenGui,
	onConfirm = function(item)
		modal.setBusy(true)
		-- Net.invoke blocks its thread until the server replies, so the click handler must not
		-- own the wait.
		task.spawn(function()
			local ok, result = pcall(Net.invoke, Net.Names.PurchaseBoostItem, item.Id)
			modal.setBusy(false)

			-- The window may have been closed (or reopened on the other canister) while the
			-- invoke was in flight; a stale reply must not overwrite what is on screen now.
			if modal.currentItem() ~= item then
				return
			end
			if not ok or type(result) ~= "table" then
				modal.showMessage(FAILED_MESSAGE)
				return
			end
			if result.success then
				modal.close()
			else
				modal.showMessage(result.message or FAILED_MESSAGE)
			end
		end)
	end,
})
if not modal then
	-- The window is missing (BoostPurchaseModal already warned); leaving the prompts unwired is
	-- better than a prompt that visibly does nothing.
	return
end

-- Equip half: the hotbar flank slots enter field placement for the item they hold.
local placement = BoostFieldPlacement.new({
	screenGui = screenGui,
	onMessage = function(text)
		-- No status surface owns this domain yet, so a refused drop is only reported here. The
		-- common refusals are already prevented client-side (an empty slot is inert, an off-plot
		-- ghost reads invalid); what reaches this is mainly "that plot already has this field".
		warn("BoostShop: " .. tostring(text))
	end,
})
if placement then
	BoostHotbarSlots.new({
		screenGui = screenGui,
		onActivate = function(item)
			placement.enter(item)
		end,
		isPlacing = placement.isActive,
		placingItemId = placement.activeItemId,
		cancelPlacement = placement.exit,
	})
end

-- Every dropped field on every plot gets its quiet ping and a status panel (item, boost, countdown,
-- plus who gifted it). Both cover fields already on the ground when this client joined, and both are
-- purely presentational: the fields themselves are server-owned.
BoostFieldPulse.bindWorld()
BoostFieldLabels.bindWorld(screenGui)


BoostShopPrompts.bind(function(item)
	modal.open(item)
end)
