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

BoostShopPrompts.bind(function(item)
	modal.open(item)
end)
