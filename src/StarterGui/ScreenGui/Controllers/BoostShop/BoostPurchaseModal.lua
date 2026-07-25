-- BoostPurchaseModal — the "Boost Shop" buy window opened from a counter prompt.
--
-- Logic only: the window itself is the Studio-authored `BoostPurchaseConfirm` template under the
-- ScreenGui (docs/boost-shop-design.md §7). This module binds it, mirroring StoreSellConfirm:
-- ModalCoordinator for the single-open slot, MobileScale.applyResolved for responsive sizing,
-- ModalOutsideClose to dismiss on a background click.
--
-- Expected template (named children, found anywhere under `BoostPurchaseConfirm`):
--   Header         (TextLabel)  -> static "Boost Shop" (logic never touches it)
--   Prompt         (TextLabel)  -> `Buy "Power Field"?`
--   ItemName       (TextLabel)  -> "Power Field"
--   Description    (TextLabel)  -> flavor line
--   DurationValue  (TextLabel)  -> "5:00"        (+ optional DurationBar.Fill)
--   StrengthValue  (TextLabel)  -> "+50%"        (+ optional StrengthBar.Fill)
--   OwnedValue     (TextLabel)  -> "0 / 1"
--   Price          (TextLabel)  -> "40"          (GemIcon beside it is static art)
--   Message        (TextLabel)  -> optional; blocked-state line ("Not enough gems")
--   ConfirmButton  (GuiButton)  -> Buy
--   CancelButton   (GuiButton)  -> Cancel
--
-- The three §7 states are driven from live data: the player's replicated gem balance and the
-- item's owned-charge attribute. When Buy is blocked (too few gems, or the 1-per-type stack is
-- full) the button goes inert and dims from its authored color; nothing else is restyled.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))
local MobileScale = require(shared:WaitForChild("MobileScale"))
local NumberFormat = require(shared:WaitForChild("NumberFormat"))

local modals = script.Parent.Parent:WaitForChild("Modals")
local ModalCoordinator = require(modals:WaitForChild("ModalCoordinator"))
local ModalOutsideClose = require(modals:WaitForChild("ModalOutsideClose"))

local MY = "BoostPurchase"

-- Blocked-Buy chrome. The dim is a solid pre-blended color against the window's dark panel, the
-- same trick StoreAffordance uses, so a disabled button never stacks transparency over the box.
local PANEL = Color3.fromRGB(6, 7, 9)
local DISABLED_BLEND = 0.55
local SHORTFALL_COLOR = Color3.fromRGB(255, 72, 72)
local OUTSIDE_CLOSE_GRACE = 0.25

local BoostPurchaseModal = {}

local function findText(root, name)
	local object = root:FindFirstChild(name, true)
	if object and (object:IsA("TextLabel") or object:IsA("TextButton")) then
		return object
	end
	return nil
end

local function setText(label, text)
	if label then
		label.Text = text
	end
end

local function findFill(root, barName)
	local bar = root:FindFirstChild(barName, true)
	local fill = bar and bar:FindFirstChild("Fill", true)
	if fill and fill:IsA("GuiObject") then
		return fill
	end
	return nil
end

local function setFill(fill, fraction)
	if fill then
		fill.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, fill.Size.Y.Scale, fill.Size.Y.Offset)
	end
end

local function formatDuration(seconds)
	local minutes = math.floor(seconds / 60)
	return ("%d:%02d"):format(minutes, seconds - minutes * 60)
end

-- options: { screenGui, onConfirm(item) }
function BoostPurchaseModal.new(options)
	local screenGui = options.screenGui
	local root = screenGui:FindFirstChild(BoostShopConfig.ModalName, true)
	if not (root and root:IsA("GuiObject")) then
		warn(
			("BoostPurchaseModal: no `%s` template found under the ScreenGui — the boost shop window is disabled until it is authored in Studio."):format(
				BoostShopConfig.ModalName
			)
		)
		return nil
	end

	-- Same responsive treatment as SellConfirm: keep the box inside the safe area and resize it
	-- (not its text) on phones. See [[clickgame-responsive-scaling]].
	MobileScale.applyResolved(root)

	local promptLabel = findText(root, "Prompt")
	local itemNameLabel = findText(root, "ItemName")
	local descriptionLabel = findText(root, "Description")
	local durationLabel = findText(root, "DurationValue")
	local strengthLabel = findText(root, "StrengthValue")
	local ownedLabel = findText(root, "OwnedValue")
	local priceLabel = findText(root, "Price")
	local messageLabel = findText(root, "Message")
	local durationFill = findFill(root, "DurationBar")
	local strengthFill = findFill(root, "StrengthBar")

	local confirmButton = root:FindFirstChild("ConfirmButton", true)
	confirmButton = (confirmButton and confirmButton:IsA("GuiButton")) and confirmButton or nil
	local cancelButton = root:FindFirstChild("CancelButton", true)
	cancelButton = (cancelButton and cancelButton:IsA("GuiButton")) and cancelButton or nil

	-- Authored styling captured before anything is dimmed, so enabling restores the user's colors.
	local confirmColor = confirmButton and confirmButton.BackgroundColor3
	local confirmAutoColor = confirmButton and confirmButton.AutoButtonColor
	local priceColor = priceLabel and priceLabel.TextColor3

	local player = Players.LocalPlayer
	local openItem = nil
	local openedAt = 0
	-- True while a purchase invoke is in flight: Buy stays inert so one tap cannot double-spend.
	local busy = false
	local gemsConn = nil
	local ownedConn = nil

	local function ownedCount(item)
		return math.max(0, math.floor(tonumber(player:GetAttribute(item.OwnedAttribute)) or 0))
	end

	local function gemBalance()
		return math.max(0, math.floor(tonumber(player:GetAttribute(Attrs.Gems)) or 0))
	end

	local function setBuyEnabled(enabled)
		if not confirmButton then
			return
		end
		confirmButton.Active = enabled
		confirmButton.Selectable = enabled
		confirmButton.AutoButtonColor = enabled and confirmAutoColor or false
		confirmButton.BackgroundColor3 = enabled and confirmColor or PANEL:Lerp(confirmColor, 1 - DISABLED_BLEND)
	end

	local function render()
		local item = openItem
		if not item then
			return
		end

		setText(promptLabel, ('Buy "%s"?'):format(item.DisplayName))
		setText(itemNameLabel, item.DisplayName)
		setText(descriptionLabel, item.Description)
		setText(durationLabel, formatDuration(item.DurationSeconds))
		setText(strengthLabel, ("+%d%%"):format(item.StrengthPercent))
		setFill(durationFill, item.DurationSeconds / BoostShopConfig.BarReference.DurationSeconds)
		setFill(strengthFill, item.StrengthPercent / BoostShopConfig.BarReference.StrengthPercent)

		local owned = ownedCount(item)
		setText(ownedLabel, ("%d / %d"):format(owned, item.StackCap))
		setText(priceLabel, NumberFormat.abbreviate(item.PriceGems))

		local full = owned >= item.StackCap
		local affordable = gemBalance() >= item.PriceGems
		-- Stack-full outranks the price: a full inventory blocks the buy whatever the balance is.
		if full then
			setText(messageLabel, ("Inventory full (%d / %d)"):format(owned, item.StackCap))
		elseif not affordable then
			setText(messageLabel, "Not enough gems")
		else
			setText(messageLabel, "")
		end
		if priceLabel then
			priceLabel.TextColor3 = (not full and not affordable) and SHORTFALL_COLOR or priceColor
		end
		setBuyEnabled(not full and affordable and not busy)
	end

	local function stopWatching()
		if gemsConn then
			gemsConn:Disconnect()
			gemsConn = nil
		end
		if ownedConn then
			ownedConn:Disconnect()
			ownedConn = nil
		end
	end

	local slot = ModalCoordinator.register(MY, function()
		-- Another modal claimed the slot — hide ourselves.
		openItem = nil
		stopWatching()
		root.Visible = false
	end)

	local function close()
		openItem = nil
		busy = false
		stopWatching()
		root.Visible = false
		slot.close()
	end

	local function open(item)
		openItem = item
		openedAt = os.clock()
		busy = false
		stopWatching()
		render()

		-- Live state while the window sits open: a gem reward landing (or the future purchase
		-- writing the charge count) flips the Buy button without the player reopening it.
		gemsConn = player:GetAttributeChangedSignal(Attrs.Gems):Connect(render)
		ownedConn = player:GetAttributeChangedSignal(item.OwnedAttribute):Connect(render)

		root.Visible = true
		slot.open()
	end

	if confirmButton then
		confirmButton.MouseButton1Click:Connect(function()
			local item = openItem
			if not item or busy or confirmButton.Active == false then
				return
			end
			if options.onConfirm then
				options.onConfirm(item)
			end
		end)
	end
	if cancelButton then
		cancelButton.MouseButton1Click:Connect(close)
	end

	ModalOutsideClose.bind({
		modal = root,
		isOpen = function()
			-- Grace window: on touch, the tap that fires the counter prompt also lands as an
			-- InputBegan outside the window, which would dismiss it in the same frame it opened.
			return openItem ~= nil and (os.clock() - openedAt) > OUTSIDE_CLOSE_GRACE
		end,
		close = close,
	})

	root.Visible = false

	return {
		open = open,
		close = close,
		isOpen = function()
			return openItem ~= nil
		end,
		-- One-off line in the window's Message slot (kept until the next render/close).
		showMessage = function(text)
			setText(messageLabel, text)
		end,
		-- Holds Buy inert while a purchase is in flight; clearing it re-renders the live state.
		setBusy = function(value)
			busy = value == true
			if busy then
				setBuyEnabled(false)
			else
				render()
			end
		end,
		-- The item the window is currently showing, or nil when closed.
		currentItem = function()
			return openItem
		end,
	}
end

return BoostPurchaseModal
