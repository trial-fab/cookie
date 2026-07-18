-- HotbarPlacementMode: temporarily turns the authored item hotbar into placement actions.
-- Full screen-control mode uses Cancel / Rotate / Confirm. Classic desktop Multi-Place with
-- screen controls off uses only the center Cancel face while the ghost continues following the
-- mouse. Studio owns every face; this module owns visibility, geometry, and transitions.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local HotbarPlacementMode = {}

local MODE_NONE = "none"
local MODE_CONTROLS = "controls"
local MODE_MULTI_PLACE = "multiPlace"
local SLOT_SIZE_PIXELS = 72
local SLOT_GAP_PIXELS = 8
local TRANSITION_SECONDS = 0.25

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
			setPlacementFace(record, fullControls)
		end
		setMultiPlaceFaceVisible(mode == MODE_MULTI_PLACE)

		if mode == MODE_MULTI_PLACE then
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
				slot.Visible = true
				slot.ZIndex = 5
			end
		end
	end

	local function getPlacementTargets()
		local size = SLOT_SIZE_PIXELS
		local spacing = size + SLOT_GAP_PIXELS
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

	local function applyActivePose(animate)
		if activeMode == MODE_NONE then
			return
		end
		transitionToken += 1
		cancelTweens()
		setModeFaces(activeMode)
		local positions, size = getPlacementTargets()
		local duration = TRANSITION_SECONDS
		for _, record in ipairs(records) do
			local participates = activeMode == MODE_CONTROLS or record.slot == slotCenter
			if participates then
				local slot = record.slot
				if animate and duration > 0 then
					local tween = UiMotion.create(
						slot,
						TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
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

		for _, record in ipairs(records) do
			if record.hitbox then
				record.hitbox.Active = false
				record.hitbox.Interactable = false
			end
		end

		local targets = ctx.getExitTargets and ctx.getExitTargets() or nil
		local duration = TRANSITION_SECONDS
		local remaining = 0
		local function finish()
			if token ~= transitionToken then
				return
			end
			placementTransitioning = false
			table.clear(activeTweens)
			setModeFaces(MODE_NONE)
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
						TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
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
			activeMode = mode
			if previousMode == MODE_NONE and ctx.onEnter then
				ctx.onEnter()
			end
			applyActivePose(true)
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
		if screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true then
			return MODE_CONTROLS
		end
		if screenGui:GetAttribute(Attrs.MultiPlaceSessionActive) == true then
			return MODE_MULTI_PLACE
		end
		return MODE_NONE
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
		Attrs.PlacementControlsEnabled,
		Attrs.MultiPlaceSessionActive,
	}) do
		screenGui:GetAttributeChangedSignal(attribute):Connect(refreshMode)
	end

	refreshMode()

	return {
		isActive = function()
			return activeMode ~= MODE_NONE
		end,
		isTransitioning = function()
			return placementTransitioning
		end,
		refresh = function()
			applyActivePose(false)
		end,
	}
end

return HotbarPlacementMode
