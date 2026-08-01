-- BoostHotbarSlots: the two boost items living in the authored hotbar's flank slots.
--
-- SlotLeft = Power Field, SlotRight = Speed Field (the slots the Remote Cookie Clicker and
-- Teleporter vacated when they moved post-launch). This module owns only the item's state on
-- those slots: the owned-charge readout, its hover hint, whether the slot is selectable, and the
-- activation gesture.
-- HotbarCarousel keeps owning pose, spin, and visibility; nothing here fights it.
--
-- Activation is ONE press, like the store's cookie slot: tapping the slot (or pressing its item
-- number, 2 for Power / 3 for Speed) equips the item and opens field placement immediately. The
-- carousel's own handler still spins the slot to centre off the same tap, so the two compose
-- without a hook inside HotbarCarousel. Pressing again while placing cancels.
--
-- The slot icon is a live model preview, the same treatment building rows get (StorePreview): a
-- ViewportFrame holds a WorldModel with a cloned canister from ReplicatedStorage.BoostPreviews.
-- BoostChargeCluster owns those viewports, and how many canisters stand in the slot is how the
-- owned count is reported — the number badge is retired.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))
local CursorTooltip = require(shared:WaitForChild("CursorTooltip"))

local BoostChargeCluster = require(script.Parent:WaitForChild("BoostChargeCluster"))

local BoostHotbarSlots = {}

-- Which authored slot each item occupies, and the item number that equips it. The number is both
-- the key press and the keycap the hover hint shows, so the two can never drift apart. It mirrors
-- HotbarCarousel's own mapping (1 = centre/Mixer, 2 = left, 3 = right).
local SLOT_BY_ITEM = {
	PowerField = "SlotLeft",
	SpeedField = "SlotRight",
}
local SLOT_KEYS = {
	SlotLeft = { code = Enum.KeyCode.Two, label = "2" },
	SlotRight = { code = Enum.KeyCode.Three, label = "3" },
}

-- Longest we will wait for a requested item to reach the centre (store close, then spin) before
-- dropping the request.
local SPIN_WAIT_TIMEOUT = 4

-- options: { screenGui, onActivate(item) }
function BoostHotbarSlots.new(options)
	local screenGui = options.screenGui
	local player = Players.LocalPlayer

	local hotbar = screenGui:FindFirstChild("Hotbar")
	if not hotbar then
		warn("BoostHotbarSlots: no `Hotbar` under the ScreenGui — boost items have no slots.")
		return nil
	end

	local tooltip = CursorTooltip.get(screenGui)
	local bindings = {}
	local scheduleActivate

	local function ownedCount(item)
		return math.max(0, math.floor(tonumber(player:GetAttribute(item.OwnedAttribute)) or 0))
	end

	local previews = ReplicatedStorage:FindFirstChild(BoostShopConfig.PreviewFolderName)
	if not previews then
		warn(("BoostHotbarSlots: no `%s` folder in ReplicatedStorage — slots fall back to the authored icon."):format(
			BoostShopConfig.PreviewFolderName
		))
	end

	-- An empty slot is just the authored `+` placeholder; the canisters replace it only once the
	-- player owns a charge, and hand the slot back when the last one is spent. The two are never
	-- visible together.
	local function render(binding)
		local owned = ownedCount(binding.item)
		-- While the placement faces own the bar, the slot belongs to Cancel/Confirm. HotbarPlacementMode
		-- hides the authored icon/placeholder itself but knows nothing about the canisters, so they are
		-- suppressed here or they would show through the face.
		local placing = screenGui:GetAttribute(Attrs.PlacementActive) == true
		local hasItem = owned > 0

		if binding.cluster then
			binding.cluster.render(owned, not placing)
		end
		-- The placeholder is only ours to drive outside placement: during it HotbarPlacementMode
		-- hides every placeholder for the Cancel/Confirm faces, and re-showing it here would fight
		-- that. When the slot is empty otherwise, hand it back to the carousel's rule (placeholders
		-- show while the store is closed).
		if binding.placeholder and not placing then
			binding.placeholder.Visible = not hasItem and screenGui:GetAttribute(Attrs.StoreOpen) ~= true
		end
		if binding.tooltip then
			binding.tooltip:refresh()
		end
	end

	-- Activation waits for the carousel to actually deliver the slot to the centre before placement
	-- takes over the bar. That wait can be long: pressing 2 while the store is open first closes
	-- the store, and only then does the carousel spin. So rather than guessing a delay, watch for
	-- the slot to reach the centre pose and let the spin settle from there. One pending request at
	-- a time; a newer press supersedes an older one.
	local pendingToken = 0
	function scheduleActivate(binding)
		pendingToken += 1
		local token = pendingToken
		local slot = binding.slot

		local function ready()
			return slot:GetAttribute("HotbarPose") == "center"
				and screenGui:GetAttribute(Attrs.StoreOpen) ~= true
		end

		if ready() then
			binding.fire()
			return
		end

		local connections = {}
		local function cleanup()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end

		local function check()
			if token ~= pendingToken then
				cleanup()
				return
			end
			if not ready() then
				return
			end
			cleanup()
			-- The pose attribute flips when the spin STARTS, so let it land before placement
			-- replaces the bar with its controls. The carousel publishes its own deadline, so the
			-- wait tracks the real tween instead of a duplicated duration.
			local settlesAt = tonumber(hotbar:GetAttribute(Attrs.HotbarSpinSettlesAt)) or 0
			task.delay(math.max(0, settlesAt - os.clock()), function()
				if token == pendingToken then
					binding.fire()
				end
			end)
		end

		table.insert(connections, slot:GetAttributeChangedSignal("HotbarPose"):Connect(check))
		table.insert(connections, screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(check))
		-- Never leave a listener waiting on a spin that is not coming.
		task.delay(SPIN_WAIT_TIMEOUT, function()
			if token == pendingToken then
				cleanup()
			end
		end)
	end

	for _, itemId in ipairs(BoostShopConfig.Order) do
		local item = BoostShopConfig.Items[itemId]
		local slotName = SLOT_BY_ITEM[itemId]
		local slot = slotName and hotbar:FindFirstChild(slotName)
		local hitbox = slot and slot:FindFirstChild("hitbox")

		if not (slot and hitbox and hitbox:IsA("GuiButton")) then
			warn(("BoostHotbarSlots: %s has no usable slot (%s) — %s cannot be equipped."):format(
				item.DisplayName,
				tostring(slotName),
				item.DisplayName
			))
		else
			local placeholder = slot:FindFirstChild("placeholderLabel")
			local binding = {
				item = item,
				slot = slot,
				placeholder = placeholder and placeholder:IsA("GuiObject") and placeholder or nil,
			}

			-- The count is told by the canisters now, so the authored number badge is retired here
			-- once and never driven again. It is left in place rather than destroyed: the slots are
			-- Studio-owned, so deleting the label is the user's edit to make.
			local badge = slot:FindFirstChild("CountBadge")
			if badge and badge:IsA("GuiObject") then
				badge.Visible = false
			end

			-- Mount the canisters once; render() decides how many are visible.
			local sourceModel = previews and previews:FindFirstChild(item.CanisterName)
			binding.cluster = BoostChargeCluster.bind(slot, sourceModel)
			table.insert(bindings, binding)

			-- Name the item on hover, the way the Mixer names itself. Keyboard-and-mouse only, like
			-- every other cursor hint. It stays quiet whenever the slot is not being an item: during
			-- a placement the slot is wearing a Cancel/Confirm face (whose own hints belong to the
			-- placement), and an open store parks its close X over these very slots.
			binding.tooltip = tooltip:registerGui(hitbox, {
				trigger = tooltip.Trigger.Hover,
				getContent = function()
					if UserInputService.PreferredInput ~= Enum.PreferredInput.KeyboardAndMouse then
						return nil
					end
					if screenGui:GetAttribute(Attrs.PlacementActive) == true then
						return nil
					end
					if screenGui:GetAttribute(Attrs.StoreOpen) == true then
						return nil
					end
					local keys = SLOT_KEYS[slot.Name]
					return {
						mode = "Hint",
						title = item.DisplayName,
						keybind = keys and keys.label or nil,
					}
				end,
			})

			-- HotbarPlacementMode restores every placeholder when its exit animation FINISHES,
			-- which lands after our own PlacementActive re-render — that is what left the preview
			-- and the `+` both showing. Re-assert whenever something else turns it back on.
			if binding.placeholder then
				binding.placeholder:GetPropertyChangedSignal("Visible"):Connect(function()
					if binding.placeholder.Visible and ownedCount(item) > 0 then
						if screenGui:GetAttribute(Attrs.PlacementActive) ~= true then
							binding.placeholder.Visible = false
						end
					end
				end)
			end

			-- Final guards, run at the moment of activation rather than when it was requested.
			binding.fire = function()
				if screenGui:GetAttribute(Attrs.PlacementActive) == true then
					return
				end
				if screenGui:GetAttribute(Attrs.StoreOpen) == true then
					return
				end
				if ownedCount(item) <= 0 then
					return
				end
				if options.onActivate then
					options.onActivate(item)
				end
			end

			-- A tap while the store is open belongs to the store (its close X sits over a flank
			-- slot), so it never equips. A NUMBER key does: it closes the store, spins, and then
			-- activates, which is handled by the scheduler below.
			--
			-- A tap DURING a placement belongs to Cancel/Confirm, which are wearing these very
			-- slots. Scheduling from here would leave an activation pending that fires after the
			-- session it was meant to control has already ended -- re-entering placement on top of
			-- a drop the player just confirmed.
			hitbox.Activated:Connect(function()
				if screenGui:GetAttribute(Attrs.StoreOpen) == true then
					return
				end
				if screenGui:GetAttribute(Attrs.PlacementActive) == true then
					return
				end
				scheduleActivate(binding)
			end)

			player:GetAttributeChangedSignal(item.OwnedAttribute):Connect(function()
				render(binding)
			end)
			render(binding)
		end
	end

	local function renderAll()
		for _, binding in ipairs(bindings) do
			render(binding)
		end
	end

	local ITEM_KEYS = {
		[Enum.KeyCode.One] = true,
		[Enum.KeyCode.Two] = true,
		[Enum.KeyCode.Three] = true,
	}
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not ITEM_KEYS[input.KeyCode] then
			return
		end

		-- Any item number leaves an active field placement: you switch items rather than being
		-- stuck until you cancel. Pressing the SAME item's number just cancels.
		--
		-- The spin itself belongs to HotbarCarousel, which now DEFERS a selection made during a
		-- field placement until its controls have folded away, then spins the pressed item to the
		-- centre. So this side only has to end the session and wait for the slot to land -- the
		-- two listeners no longer race, and the bar is never spun while it is still the controls.
		local wasPlacing = options.isPlacing and options.isPlacing()
		local samePlacingItem = wasPlacing and options.placingItemId and options.placingItemId()
		if wasPlacing and options.cancelPlacement then
			options.cancelPlacement()
		end

		for _, binding in ipairs(bindings) do
			local keys = SLOT_KEYS[binding.slot.Name]
			if keys and keys.code == input.KeyCode then
				if samePlacingItem ~= binding.item.Id then
					scheduleActivate(binding)
				end
			end
		end
	end)

	-- The carousel toggles every placeholderLabel on store open/close, so re-assert ours after it
	-- has run (deferred so we are not fighting it inside the same signal).
	screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(function()
		task.defer(renderAll)
	end)
	screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(function()
		task.defer(renderAll)
	end)

	return {
		refresh = renderAll,
	}
end

return BoostHotbarSlots
