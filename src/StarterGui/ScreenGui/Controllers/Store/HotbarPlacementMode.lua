-- HotbarPlacementMode: temporarily turns the authored item hotbar into placement actions.
-- Full screen-control mode uses Cancel / Rotate / Confirm. Classic desktop placement with
-- screen controls off uses only the center Cancel face while the ghost continues following the
-- mouse, for both single placement and Multi-Place. Studio owns every face; this module owns
-- visibility, geometry, and transitions.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local PlacementControls = require(Shared:WaitForChild("PlacementControls"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local HotbarPlacementMode = {}

local MODE_NONE = "none"
local MODE_CONTROLS = "controls"
local MODE_CLASSIC = "classic"
local SLOT_SIZE_PIXELS = 72
local SLOT_GAP_PIXELS = 8
local TRANSITION_SECONDS = 0.25
-- Size the controls start at for the opening entrance, as a fraction of their placed size.
local OPEN_ENTRANCE_START_SCALE = 0.3

local function findGui(slot, name)
	local child = slot and slot:FindFirstChild(name)
	return child and child:IsA("GuiObject") and child or nil
end

function HotbarPlacementMode.new(ctx)
	local screenGui = ctx.screenGui
	local slotLeft = ctx.slotLeft
	local slotCenter = ctx.slotCenter
	local slotRight = ctx.slotRight
	local slots = { slotLeft, slotCenter, slotRight }
	local centerPosition = slotCenter.Position
	local activeMode = MODE_NONE
	local placementTransitioning = false
	local transitionToken = 0
	local activeTweens = {}
	local multiPlaceFace = findGui(slotCenter, "MultiPlaceFace")
	-- Captured once per session on entrance, not read live: the owner clears its attributes as part
	-- of tearing down, and the exit animation still has to know which style it is closing.
	local openEntrance = false
	local noRotate = false

	local records = {}
	for _, slot in ipairs(slots) do
		local face = findGui(slot, "PlacementFace")
		table.insert(records, {
			slot = slot,
			face = face,
			normalIcon = findGui(slot, "icon"),
			placeholder = findGui(slot, "placeholderLabel"),
			badge = findGui(slot, "KeybindBadge"),
			hitbox = findGui(slot, "hitbox"),
		})
		if face then
			face.Visible = false
		end
	end
	if multiPlaceFace then
		multiPlaceFace.Visible = false
	end

	local function cancelTweens()
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	local function setPlacementFace(record, visible)
		if record.normalIcon then
			record.normalIcon.Visible = not visible
		end
		if record.placeholder then
			record.placeholder.Visible = not visible
		end
		if record.badge then
			record.badge.Visible = false
		end
		if record.face then
			record.face.Visible = visible
			record.face.ZIndex = 6
			local icon = record.face:FindFirstChild("Icon")
			if icon and icon:IsA("GuiObject") then
				icon.ZIndex = 7
			end
			local disabledOverlay = record.face:FindFirstChild("DisabledOverlay")
			if disabledOverlay and disabledOverlay:IsA("GuiObject") then
				disabledOverlay.ZIndex = 8
			end
		end
		if record.hitbox then
			record.hitbox.ZIndex = visible and 9 or record.slot.ZIndex
		end
	end

	local function setMultiPlaceFaceVisible(visible)
		if not multiPlaceFace then
			return
		end
		multiPlaceFace.Visible = visible
		multiPlaceFace.ZIndex = 6
		for _, descendant in ipairs(multiPlaceFace:GetDescendants()) do
			if descendant:IsA("GuiObject") then
				descendant.ZIndex = 7
			end
		end
	end

	local function setModeFaces(mode)
		local fullControls = mode == MODE_CONTROLS
		for _, record in ipairs(records) do
			setPlacementFace(record, fullControls and not (noRotate and record.slot == slotCenter))
		end
		setMultiPlaceFaceVisible(mode == MODE_CLASSIC)
		if mode == MODE_NONE then
			-- Give the middle slot back to the carousel on the way out.
			slotCenter.Visible = true
		end

		if mode == MODE_CLASSIC then
			for _, record in ipairs(records) do
				if record.slot == slotCenter then
					record.slot.Visible = true
					record.slot.ZIndex = 5
					if record.normalIcon then
						record.normalIcon.Visible = false
					end
					if record.placeholder then
						record.placeholder.Visible = false
					end
					if record.hitbox then
						record.hitbox.ZIndex = 9
					end
				else
					record.slot.Visible = false
				end
			end
		elseif fullControls then
			for _, slot in ipairs(slots) do
				slot.Visible = not (noRotate and slot == slotCenter)
				slot.ZIndex = 5
			end
		end
	end

	local function getPlacementTargets()
		local size = SLOT_SIZE_PIXELS
		local spacing = size + SLOT_GAP_PIXELS
		-- Two-button layout: with no Rotate in the middle, Cancel and Confirm close up around the
		-- centre as a pair rather than sitting at their three-slot positions with a hole between.
		if noRotate and activeMode == MODE_CONTROLS then
			local half = math.floor(spacing / 2)
			return {
				[slotLeft] = UDim2.new(
					centerPosition.X.Scale,
					centerPosition.X.Offset - half,
					centerPosition.Y.Scale,
					centerPosition.Y.Offset
				),
				[slotRight] = UDim2.new(
					centerPosition.X.Scale,
					centerPosition.X.Offset + half,
					centerPosition.Y.Scale,
					centerPosition.Y.Offset
				),
			},
				UDim2.fromOffset(size, size)
		end
		return {
			[slotLeft] = UDim2.new(
				centerPosition.X.Scale,
				centerPosition.X.Offset - spacing,
				centerPosition.Y.Scale,
				centerPosition.Y.Offset
			),
			[slotCenter] = centerPosition,
			[slotRight] = UDim2.new(
				centerPosition.X.Scale,
				centerPosition.X.Offset + spacing,
				centerPosition.Y.Scale,
				centerPosition.Y.Offset
			),
		},
			UDim2.fromOffset(size, size)
	end

	-- Entrance-only: park the participating slots collapsed at the centre so the tween below plays
	-- as the controls opening outward, instead of the discs sliding over from their hotbar poses.
	local function applyOpenEntranceStart(positions)
		for _, record in ipairs(records) do
			local participates = positions[record.slot] ~= nil
			if participates then
				record.slot.Position = centerPosition
				record.slot.Size = UDim2.fromOffset(
					SLOT_SIZE_PIXELS * OPEN_ENTRANCE_START_SCALE,
					SLOT_SIZE_PIXELS * OPEN_ENTRANCE_START_SCALE
				)
			end
		end
	end

	local function applyActivePose(animate, isEntrance)
		if activeMode == MODE_NONE then
			return
		end
		transitionToken += 1
		cancelTweens()
		setModeFaces(activeMode)
		local positions, size = getPlacementTargets()
		local duration = TRANSITION_SECONDS
		if isEntrance and animate and openEntrance then
			applyOpenEntranceStart(positions)
		end
		for _, record in ipairs(records) do
			local participates = (activeMode == MODE_CONTROLS or record.slot == slotCenter)
				and positions[record.slot] ~= nil
			if participates then
				local slot = record.slot
				if animate and duration > 0 then
					-- Back/Out gives the opening entrance a small overshoot as the controls pop
					-- apart; the ordinary travel keeps the flatter Quad curve.
					local style = (isEntrance and openEntrance) and Enum.EasingStyle.Back
						or Enum.EasingStyle.Quad
					local tween = UiMotion.create(
						slot,
						TweenInfo.new(duration, style, Enum.EasingDirection.Out),
						{ Position = positions[slot], Size = size }
					)
					table.insert(activeTweens, tween)
					tween:Play()
				else
					slot.Position = positions[slot]
					slot.Size = size
				end
			end
		end
	end

	local function returnToHotbarPose(instant)
		placementTransitioning = true
		transitionToken += 1
		local token = transitionToken
		cancelTweens()

		-- Deaden the faces for the duration of the exit animation so a tap cannot reach a slot that
		-- is mid-flight between poses. `finish` hands interactivity straight back: this module is
		-- the only thing that takes it away, so it is the only thing that may restore it.
		for _, record in ipairs(records) do
			if record.hitbox then
				record.hitbox.Active = false
				record.hitbox.Interactable = false
			end
		end

		-- A session that OPENED from the centre closes back into it, instead of gliding out to the
		-- carousel poses it never came from.
		local collapsing = openEntrance
		local targets = nil
		if collapsing then
			targets = {}
			local collapsedSize = UDim2.fromOffset(
				SLOT_SIZE_PIXELS * OPEN_ENTRANCE_START_SCALE,
				SLOT_SIZE_PIXELS * OPEN_ENTRANCE_START_SCALE
			)
			for _, record in ipairs(records) do
				targets[record.slot] = { Position = centerPosition, Size = collapsedSize }
			end
		else
			targets = ctx.getExitTargets and ctx.getExitTargets() or nil
		end
		local duration = TRANSITION_SECONDS
		local remaining = 0
		local function finish()
			if token ~= transitionToken then
				return
			end
			placementTransitioning = false
			table.clear(activeTweens)
			setModeFaces(MODE_NONE)
			-- Hand the slots back to the carousel BEFORE onExit, which is where SlotCenter's own
			-- owner (HotbarCarousel.updateMixerFace) re-disables it if the store is open. Nothing
			-- else in the codebase re-enables the FLANK hitboxes, so leaving them off here made
			-- every slot but the centre permanently dead after the first placement -- fatal on
			-- touch, where the 2/3 item keys do not exist.
			for _, record in ipairs(records) do
				if record.hitbox then
					record.hitbox.Active = true
					record.hitbox.Interactable = true
				end
			end
			openEntrance = false
			noRotate = false
			if ctx.onExit then
				ctx.onExit()
			end
		end
		if instant then
			finish()
			return
		end

		if targets and duration > 0 then
			for _, record in ipairs(records) do
				local target = targets[record.slot]
				if target and record.slot.Visible then
					remaining += 1
					local tween = UiMotion.create(
						record.slot,
						collapsing
								and TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.In)
							or TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						target
					)
					table.insert(activeTweens, tween)
					tween.Completed:Once(function()
						if token ~= transitionToken then
							return
						end
						remaining -= 1
						if remaining == 0 then
							finish()
						end
					end)
					tween:Play()
				end
			end
		end

		if remaining == 0 then
			finish()
		end
	end

	local function setMode(mode, instantExit)
		if activeMode == mode and not (mode ~= MODE_NONE and placementTransitioning) then
			return
		end
		local previousMode = activeMode
		if mode ~= MODE_NONE then
			transitionToken += 1
			placementTransitioning = false
			cancelTweens()
			if previousMode == MODE_NONE then
				openEntrance = screenGui:GetAttribute(Attrs.PlacementControlsOpenEntrance) == true
				noRotate = screenGui:GetAttribute(Attrs.PlacementControlsNoRotate) == true
			end
			activeMode = mode
			if previousMode == MODE_NONE and ctx.onEnter then
				ctx.onEnter()
			end
			applyActivePose(true, previousMode == MODE_NONE)
			return
		end
		if previousMode == MODE_NONE then
			return
		end
		activeMode = MODE_NONE
		returnToHotbarPose(instantExit == true)
	end

	local function desiredMode()
		if screenGui:GetAttribute(Attrs.PlacementActive) ~= true then
			return MODE_NONE
		end
		if PlacementControls.screenControlsActive(screenGui) then
			return MODE_CONTROLS
		end
		return MODE_CLASSIC
	end

	local function storeWillReturn()
		return screenGui:GetAttribute(Attrs.StoreOpen) == true
			or (
				screenGui:GetAttribute(Attrs.BuildModeActive) == true
				and screenGui:GetAttribute(Attrs.AutoBuildMode) == true
			)
	end

	local function refreshMode()
		local placementEnded = screenGui:GetAttribute(Attrs.PlacementActive) ~= true
		local instantExit = placementEnded
			and (screenGui:GetAttribute(Attrs.PlacementInstantExit) == true or storeWillReturn())
		setMode(desiredMode(), instantExit)
	end

	for _, attribute in ipairs({
		Attrs.PlacementActive,
		Attrs.MultiPlaceSessionActive,
	}) do
		screenGui:GetAttributeChangedSignal(attribute):Connect(refreshMode)
	end
	-- Covers the setting AND the input device: picking up a controller mid-placement has to swap
	-- classic mode for the on-screen faces, or the session is left with no way to commit.
	PlacementControls.observe(screenGui, refreshMode)

	refreshMode()

	return {
		isActive = function()
			return activeMode ~= MODE_NONE
		end,
		isTransitioning = function()
			return placementTransitioning
		end,
		refresh = function()
			applyActivePose(false, false)
		end,
	}
end

return HotbarPlacementMode
