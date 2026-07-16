-- StoreSellConfirm — the centered "Sell all N X?" confirmation for sell mode.
-- Logic only: the dialog itself (frame, title, amount, buttons) is a Studio-authored
-- template named `SellConfirm` under the ScreenGui (default colors, user-styled). This
-- module wires it up and routes through ModalCoordinator so it shares the single-open
-- slot with Help/Settings/Profile.
--
-- Expected template (named children, found anywhere under `SellConfirm`):
--   Title         (TextLabel)  -> "Sell Cookie Factory?" (qty 1) / "Sell 12 Cookie Factory?" (qty >1)
--   AmountPrefix  (TextLabel)  -> static "You'll get" (logic never touches it)
--   Amount        (TextLabel)  -> just the number, e.g. "8.4M" (CookieIcon + this lay out in a row)
--   ConfirmButton (GuiButton)  -> performs the sell
--   CancelButton  (GuiButton)  -> dismisses
--
-- The Confirm path calls ctx.invokeSellAll (resolved lazily at click time, since it is
-- bound after this module is constructed).
--
-- open(upgradeId) computes the quantity + refund itself (via ctx.getOwnedCount /
-- ctx.getSellAllRefund / ctx.getCountValue) and then watches the building's owned-count
-- IntValue while open, so the "Sell N …?" / amount stay live if the player sells or buys one
-- underneath the popup. If the count hits the free minimum (nothing left to sell), it closes.

local StoreSellConfirm = {}

function StoreSellConfirm.new(ctx)
	local screenGui = ctx.screenGui
	local UpgradeConfig = ctx.UpgradeConfig
	local NumberFormat = ctx.NumberFormat

	local ModalCoordinator = require(script.Parent.Parent:WaitForChild("Modals"):WaitForChild("ModalCoordinator"))
	local MobileScale = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MobileScale"))

	local root = screenGui:FindFirstChild("SellConfirm", true)
	if not root then
		warn(
			"StoreSellConfirm: no `SellConfirm` template found under the ScreenGui — sell-all confirmation disabled until it is authored in Studio."
		)
	end

	-- Responsive sizing: SellConfirm has no open/close pop of its own. resolveModal keeps it in
	-- the safe area and, on mobile, resizes the box (not the UIScale) so its text stays native
	-- size. See [[clickgame-responsive-scaling]].
	if root and root:IsA("GuiObject") then
		MobileScale.applyResolved(root)
	end

	local titleLabel = root and root:FindFirstChild("Title", true)
	local amountLabel = root and root:FindFirstChild("Amount", true)
	local confirmButton = root and root:FindFirstChild("ConfirmButton", true)
	local cancelButton = root and root:FindFirstChild("CancelButton", true)

	local pendingUpgradeId = nil
	local countConn = nil

	local function stopWatching()
		if countConn then
			countConn:Disconnect()
			countConn = nil
		end
	end

	local slot = ModalCoordinator.register("SellConfirm", function()
		-- Another modal claimed the slot — hide ourselves.
		pendingUpgradeId = nil
		stopWatching()
		if root then
			root.Visible = false
		end
	end, {
		-- SellConfirm belongs to the active Sell flow. Keep StoreBottom visible so the
		-- player never sees the unrelated hotbar between opening and resolving it.
		suspendBackgroundSurfaces = false,
	})

	local function close()
		pendingUpgradeId = nil
		stopWatching()
		if root then
			root.Visible = false
		end
		slot.close()
	end

	-- How many of this building a sell-all would dump right now (owned above the free minimum).
	local function sellableQuantity(upgradeId, config)
		local owned = ctx.getOwnedCount and ctx.getOwnedCount(upgradeId) or 0
		return owned - ((config and config.InitialCount) or 0)
	end

	-- Push the live quantity + refund into the dialog. Returns false (and closes) when there is
	-- nothing left to sell — e.g. the player sold the last one elsewhere while this was open.
	local function render(upgradeId, config)
		local quantity = sellableQuantity(upgradeId, config)
		if quantity <= 0 then
			close()
			return false
		end

		local displayName = (config and config.DisplayName) or upgradeId
		if titleLabel and (titleLabel:IsA("TextLabel") or titleLabel:IsA("TextButton")) then
			if quantity == 1 then
				titleLabel.Text = "Sell " .. displayName .. "?"
			else
				titleLabel.Text = "Sell " .. quantity .. " " .. displayName .. "?"
			end
		end
		-- The "You'll get" wording lives in a static `AmountPrefix` label; `Amount` holds only the
		-- number so a UIListLayout can lay out "You'll get" + CookieIcon + amount in a single row.
		if amountLabel and (amountLabel:IsA("TextLabel") or amountLabel:IsA("TextButton")) then
			local refund = ctx.getSellAllRefund and ctx.getSellAllRefund(upgradeId) or 0
			amountLabel.Text = NumberFormat.abbreviate(refund)
		end
		return true
	end

	local function open(upgradeId)
		if not root then
			-- No dialog to confirm with: never sell silently, just surface the message.
			if ctx.showStatus then
				ctx.showStatus("Sell confirmation UI is missing.")
			end
			return
		end

		local config = UpgradeConfig[upgradeId]
		pendingUpgradeId = upgradeId
		stopWatching()

		if not render(upgradeId, config) then
			-- Nothing to sell; render() already closed us.
			return
		end

		-- Live refresh: if the owned count changes while the popup is open (the player sells or
		-- buys one underneath it), recompute the quantity + refund. Cheap — one Changed hook on an
		-- already-replicated IntValue, torn down on close. Static snapshot if the value is missing.
		local countValue = ctx.getCountValue and ctx.getCountValue(upgradeId)
		if countValue then
			countConn = countValue.Changed:Connect(function()
				if pendingUpgradeId == upgradeId then
					render(upgradeId, config)
				end
			end)
		end

		root.Visible = true
		slot.open()
	end

	if confirmButton and confirmButton:IsA("GuiButton") then
		confirmButton.MouseButton1Click:Connect(function()
			local upgradeId = pendingUpgradeId
			close()
			if upgradeId and ctx.invokeSellAll then
				ctx.invokeSellAll(upgradeId)
			end
		end)
	end

	if cancelButton and cancelButton:IsA("GuiButton") then
		cancelButton.MouseButton1Click:Connect(close)
	end

	if root then
		root.Visible = false
	end

	return {
		open = open,
		close = close,
	}
end

return StoreSellConfirm
