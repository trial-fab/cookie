-- BoostHotbarSlots: the two boost items living in the authored hotbar's flank slots.
--
-- SlotLeft = Power Field, SlotRight = Speed Field (the slots the Remote Cookie Clicker and
-- Teleporter vacated when they moved post-launch). This module owns only the item's state on
-- those slots: the owned-count badge, whether the slot is selectable, and the activation gesture.
-- HotbarCarousel keeps owning pose, spin, and visibility; nothing here fights it.
--
-- Activation is ONE press, like the store's cookie slot: tapping the slot (or pressing its item
-- number, 2 for Power / 3 for Speed) equips the item and opens field placement immediately. The
-- carousel's own handler still spins the slot to centre off the same tap, so the two compose
-- without a hook inside HotbarCarousel. Pressing again while placing cancels.
--
-- The slot icon is a live model preview, the same treatment building rows get (StorePreview): the
-- authored `Preview` ViewportFrame holds a WorldModel with a cloned canister from
-- ReplicatedStorage.BoostPreviews. The Camera is created here at runtime and assigned to
-- CurrentCamera on purpose — authored Camera instances are stripped in the StarterGui -> PlayerGui
-- replication, so a Studio-authored one renders blank in Play.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))

local BoostHotbarSlots = {}

-- Which authored slot each item occupies.
local SLOT_BY_ITEM = {
	PowerField = "SlotLeft",
	SpeedField = "SlotRight",
}

-- Orbit framing for the slot preview, BAKED from a live tuning session (2026-07-26). Deliberately
-- not StorePreview's front-quarter building pose: a canister is a small vertical object in a small
-- round slot, and it reads best square-on and filling the frame, so the camera ended up at a flat
-- side-on angle with no elevation, pulled in tight (zoom 1) at a wide 60 degree field of view.
local PREVIEW_ANGLE = math.rad(90)
local PREVIEW_ELEVATION = math.rad(0)
local PREVIEW_ZOOM = 1
local PREVIEW_FOV = 60

-- Longest we will wait for a requested item to reach the centre (store close, then spin) before
-- dropping the request.
local SPIN_WAIT_TIMEOUT = 4

local function mountPreview(viewport, sourceModel)
	viewport:ClearAllChildren()
	viewport.CurrentCamera = nil

	local world = Instance.new("WorldModel")
	world.Name = "PreviewWorld"
	world.Parent = viewport

	local model = sourceModel:Clone()
	model.Parent = world

	local boundingCFrame, size = model:GetBoundingBox()
	local radius = math.max(size.Magnitude / 2, 0.1)
	local distance = radius * PREVIEW_ZOOM / math.tan(math.rad(PREVIEW_FOV) / 2)
	local direction = CFrame.fromEulerAnglesYXZ(PREVIEW_ELEVATION, PREVIEW_ANGLE, 0).LookVector

	local camera = Instance.new("Camera")
	camera.Name = "PreviewCamera"
	camera.FieldOfView = PREVIEW_FOV
	camera.CFrame = CFrame.lookAt(boundingCFrame.Position - direction * distance, boundingCFrame.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
end

-- options: { screenGui, onActivate(item) }
function BoostHotbarSlots.new(options)
	local screenGui = options.screenGui
	local player = Players.LocalPlayer

	local hotbar = screenGui:FindFirstChild("Hotbar")
	if not hotbar then
		warn("BoostHotbarSlots: no `Hotbar` under the ScreenGui — boost items have no slots.")
		return nil
	end

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

	-- An empty slot is just the authored `+` placeholder; the model preview replaces it only once
	-- the player owns a charge, and hands the slot back when the last one is spent. The two are
	-- never visible together.
	local function render(binding)
		local owned = ownedCount(binding.item)
		-- While the placement faces own the bar, the slot belongs to Cancel/Confirm. HotbarPlacementMode
		-- hides the authored icon/placeholder itself but knows nothing about these two, so they are
		-- suppressed here or they would show through the face.
		local placing = screenGui:GetAttribute(Attrs.PlacementActive) == true
		local hasItem = owned > 0

		if binding.badge then
			binding.badge.Text = hasItem and tostring(owned) or ""
			binding.badge.Visible = hasItem and not placing
		end
		if binding.preview then
			binding.preview.Visible = hasItem and not placing
		end
		-- The placeholder is only ours to drive outside placement: during it HotbarPlacementMode
		-- hides every placeholder for the Cancel/Confirm faces, and re-showing it here would fight
		-- that. When the slot is empty otherwise, hand it back to the carousel's rule (placeholders
		-- show while the store is closed).
		if binding.placeholder and not placing then
			binding.placeholder.Visible = not hasItem and screenGui:GetAttribute(Attrs.StoreOpen) ~= true
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
				badge = slot:FindFirstChild("CountBadge"),
			}
			if binding.badge and not binding.badge:IsA("TextLabel") then
				binding.badge = nil
			end

			-- Mount the model preview once; render() decides when it is visible.
			local viewport = slot:FindFirstChild("Preview")
			local sourceModel = previews and previews:FindFirstChild(item.CanisterName)
			if viewport and viewport:IsA("ViewportFrame") and sourceModel then
				mountPreview(viewport, sourceModel)
				binding.preview = viewport
			end
			table.insert(bindings, binding)

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

	-- Item numbers mirror HotbarCarousel's own mapping (1 = centre/Mixer, 2 = left, 3 = right).
	local KEY_BY_SLOT = {
		SlotLeft = Enum.KeyCode.Two,
		SlotRight = Enum.KeyCode.Three,
	}
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
			if KEY_BY_SLOT[binding.slot.Name] == input.KeyCode then
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
