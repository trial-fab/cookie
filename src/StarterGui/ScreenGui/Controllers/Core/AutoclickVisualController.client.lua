local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VisualConfig = require(script.Parent.AutoclickVisualConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.UpgradeConfig)
local AutoclickerConfig = require(ReplicatedStorage.Shared.AutoclickerConfig)
local Attrs = require(ReplicatedStorage.Shared.Attrs)

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")

-- Mouse COUNT tracks the Power line; click CADENCE tracks the Speed line, so
-- more Power = more mice and more Speed = faster clicking (matches AutoclickService).
local UPGRADE_ID = AutoclickerConfig.PowerUpgradeId
local SPEED_UPGRADE_ID = AutoclickerConfig.SpeedUpgradeId
local BASE_SPEED = 2 -- clicks/s before any Autoclick Speed level (matches AutoclickService)
local TEMPLATE_NAME = "mouse"
local ICON_NAME = "MouseIcon"
local GENERATED_ATTRIBUTE = "GeneratedAutoclickMouse"

local cookieSheets = Workspace:WaitForChild("CookieSheets")
local statesBySheet = {}
local warnedMissingTemplate = false
local elapsed = 0

local function warnMissingTemplate(surfacePart)
	if warnedMissingTemplate then
		return
	end
	warnedMissingTemplate = true
	warn(("Autoclick visuals disabled: add a SurfaceGui named '%s' with a GuiObject named '%s' under %s")
		:format(TEMPLATE_NAME, ICON_NAME, surfacePart:GetFullName()))
end

local function destroyGeneratedClones(state)
	for _, clone in ipairs(state.clones) do
		if clone.Parent then
			clone:Destroy()
		end
	end
	table.clear(state.clones)
	table.clear(state.clickStates)
end

local function getLevelValue(owner)
	if not owner or not owner:IsA("Player") then
		return nil
	end
	local data = owner:FindFirstChild("UpgradeCountData")
	local value = data and data:FindFirstChild(UPGRADE_ID)
	return value and value:IsA("IntValue") and value or nil
end

local function getSpeedLevelValue(owner)
	if not owner or not owner:IsA("Player") then
		return nil
	end
	local data = owner:FindFirstChild("UpgradeCountData")
	local value = data and data:FindFirstChild(SPEED_UPGRADE_ID)
	return value and value:IsA("IntValue") and value or nil
end

-- Animation speed multiplier (>=1): clicks/s of the owner's Speed line / base.
local function updateSpeedFactor(state)
	local owner = state.ownerValue.Value
	local speed = BASE_SPEED
	local levelValue = getSpeedLevelValue(owner)
	local config = UpgradeConfig[SPEED_UPGRADE_ID]
	local levels = config and config.Levels
	if levelValue and levels then
		local level = math.clamp(levelValue.Value, 0, #levels)
		local levelConfig = levels[level]
		speed = levelConfig and tonumber(levelConfig.AutoclickSpeed) or BASE_SPEED
	end
	state.speedFactor = math.max(1, speed / BASE_SPEED)
end

local function getTemplate(state)
	local template = state.surfacePart:FindFirstChild(TEMPLATE_NAME)
	if not template or not template:IsA("SurfaceGui") then
		return nil
	end
	local icon = template:FindFirstChild(ICON_NAME, true)
	if not icon or not icon:IsA("GuiObject") then
		return nil
	end
	return template
end

local function getFaceTowardCookie(state)
	local localDirection = state.surfacePart.CFrame:VectorToObjectSpace(
		state.cookie.Position - state.surfacePart.Position
	)
	local x, y, z = localDirection.X, localDirection.Y, localDirection.Z
	local absX, absY, absZ = math.abs(x), math.abs(y), math.abs(z)

	if absY >= absX and absY >= absZ then
		return y >= 0 and Enum.NormalId.Top or Enum.NormalId.Bottom
	elseif absX >= absZ then
		return x >= 0 and Enum.NormalId.Right or Enum.NormalId.Left
	end
	return z >= 0 and Enum.NormalId.Back or Enum.NormalId.Front
end

local function rebuild(state)
	destroyGeneratedClones(state)

	local template = getTemplate(state)
	if not template then
		warnMissingTemplate(state.surfacePart)
		return
	end
	template.Face = getFaceTowardCookie(state)
	template.Enabled = false

	local levelValue = getLevelValue(state.ownerValue.Value)
	local count = levelValue and math.max(0, levelValue.Value) or 0
	for index = 1, count do
		local clone = template:Clone()
		clone.Name = "AutoclickMouse_" .. index
		clone:SetAttribute(GENERATED_ATTRIBUTE, true)
		clone.Enabled = true
		local icon = clone:FindFirstChild(ICON_NAME, true)
		icon.Visible = true
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Size = UDim2.fromOffset(VisualConfig.IconSizePixels, VisualConfig.IconSizePixels)
		if screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
			local angle = math.rad(VisualConfig.StartAngleDegrees)
				+ ((index - 1) / math.max(1, count)) * 2 * math.pi
			local radius = VisualConfig.OrbitRadiusScale
			icon.Position = UDim2.fromScale(0.5 + math.cos(angle) * radius, 0.5 + math.sin(angle) * radius)
			icon.Rotation = math.deg(angle) + VisualConfig.RotationOffsetDegrees
		end
		clone.Parent = state.surfacePart
		table.insert(state.clones, clone)
		state.clickStates[clone] = {
			phase = "idle",
			startedAt = 0,
		}
	end
	state.nextClickIndex = 1
	state.nextClickAt = elapsed
	updateSpeedFactor(state)
end

local function disconnectOwnerCount(state)
	if state.countConnection then
		state.countConnection:Disconnect()
		state.countConnection = nil
	end
	if state.speedConnection then
		state.speedConnection:Disconnect()
		state.speedConnection = nil
	end
	if state.dataChildConnection then
		state.dataChildConnection:Disconnect()
		state.dataChildConnection = nil
	end
end

local function watchOwnerCount(state)
	disconnectOwnerCount(state)
	local owner = state.ownerValue.Value
	if not owner or not owner:IsA("Player") then
		rebuild(state)
		return
	end

	-- Speed changes only adjust the click cadence (state.speedFactor) — no rebuild.
	local function bindSpeedValue()
		if state.speedConnection then
			state.speedConnection:Disconnect()
			state.speedConnection = nil
		end
		local speedValue = getSpeedLevelValue(owner)
		if speedValue then
			state.speedConnection = speedValue.Changed:Connect(function()
				updateSpeedFactor(state)
			end)
		end
		updateSpeedFactor(state)
	end

	local function bindCountValue()
		if state.countConnection then
			state.countConnection:Disconnect()
			state.countConnection = nil
		end
		local levelValue = getLevelValue(owner)
		if levelValue then
			state.countConnection = levelValue.Changed:Connect(function()
				rebuild(state)
			end)
		end
		rebuild(state)
	end

	local data = owner:FindFirstChild("UpgradeCountData")
	if data then
		state.dataChildConnection = data.ChildAdded:Connect(function(child)
			if child.Name == UPGRADE_ID then
				bindCountValue()
			elseif child.Name == SPEED_UPGRADE_ID then
				bindSpeedValue()
			end
		end)
	end
	bindCountValue()
	bindSpeedValue()
end

local function detachSheet(sheet)
	local state = statesBySheet[sheet]
	if not state then
		return
	end
	statesBySheet[sheet] = nil
	disconnectOwnerCount(state)
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	destroyGeneratedClones(state)
end

local function attachSheet(sheet)
	if statesBySheet[sheet] or not sheet:IsA("Model") then
		return
	end
	local cookie = sheet:FindFirstChild("Cookie")
	local surfacePart = sheet:FindFirstChild("Center")
	local ownerValue = sheet:FindFirstChild("SheetOwner")
	if not cookie or not cookie:IsA("BasePart")
		or not surfacePart or not surfacePart:IsA("BasePart")
		or not ownerValue or not ownerValue:IsA("ObjectValue")
	then
		return
	end

	for _, child in ipairs(surfacePart:GetChildren()) do
		if child:GetAttribute(GENERATED_ATTRIBUTE) then
			child:Destroy()
		end
	end

	local state = {
		sheet = sheet,
		cookie = cookie,
		surfacePart = surfacePart,
		ownerValue = ownerValue,
		clones = {},
		clickStates = {},
		nextClickIndex = 1,
		nextClickAt = 0,
		speedFactor = 1,
		connections = {},
		countConnection = nil,
		speedConnection = nil,
		dataChildConnection = nil,
	}
	statesBySheet[sheet] = state

	table.insert(state.connections, ownerValue:GetPropertyChangedSignal("Value"):Connect(function()
		watchOwnerCount(state)
	end))
	table.insert(state.connections, surfacePart.ChildAdded:Connect(function(child)
		if child.Name == TEMPLATE_NAME and child:IsA("SurfaceGui") and not child:GetAttribute(GENERATED_ATTRIBUTE) then
			rebuild(state)
		end
	end))
	table.insert(state.connections, surfacePart.DescendantAdded:Connect(function(descendant)
		if descendant.Name ~= ICON_NAME or not descendant:IsA("GuiObject") then
			return
		end

		local topLevel = descendant
		while topLevel.Parent and topLevel.Parent ~= surfacePart do
			topLevel = topLevel.Parent
		end
		if topLevel.Name == TEMPLATE_NAME and topLevel:IsA("SurfaceGui") and not topLevel:GetAttribute(GENERATED_ATTRIBUTE) then
			rebuild(state)
		end
	end))
	table.insert(state.connections, sheet.AncestryChanged:Connect(function(_, parent)
		if not parent then
			detachSheet(sheet)
		end
	end))

	watchOwnerCount(state)
end

for _, sheet in ipairs(cookieSheets:GetChildren()) do
	attachSheet(sheet)
end
cookieSheets.ChildAdded:Connect(function(sheet)
	task.defer(attachSheet, sheet)
end)
cookieSheets.ChildRemoved:Connect(detachSheet)

local function easeInOut(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function getClickRadius(clickState, now, speedFactor)
	local defaultRadius = VisualConfig.OrbitRadiusScale
	local clickRadius = math.clamp(VisualConfig.ClickRadiusScale, 0, defaultRadius)
	if not clickState or clickState.phase == "idle" then
		return defaultRadius
	end

	speedFactor = math.max(1, speedFactor or 1)
	local travelSeconds = math.max(0.01, VisualConfig.ClickTravelSeconds / speedFactor)
	local holdSeconds = math.max(0, VisualConfig.ClickHoldSeconds / speedFactor)
	local returnSeconds = math.max(0.01, VisualConfig.ClickReturnSeconds / speedFactor)
	local phaseElapsed = now - clickState.startedAt

	if clickState.phase == "outbound" then
		if phaseElapsed < travelSeconds then
			return defaultRadius + (clickRadius - defaultRadius) * easeInOut(phaseElapsed / travelSeconds)
		end
		if phaseElapsed < travelSeconds + holdSeconds then
			return clickRadius
		end
		clickState.phase = "returning"
		clickState.startedAt = now
		return clickRadius
	end

	if phaseElapsed < returnSeconds then
		return clickRadius + (defaultRadius - clickRadius) * easeInOut(phaseElapsed / returnSeconds)
	end
	clickState.phase = "idle"
	return defaultRadius
end

local function startNextClockwiseClick(state, now)
	local count = #state.clones
	if count == 0 or now < state.nextClickAt then
		return
	end

	local index = math.clamp(state.nextClickIndex, 1, count)
	local surfaceGui = state.clones[index]
	local clickState = surfaceGui and state.clickStates[surfaceGui]
	if not clickState or clickState.phase ~= "idle" then
		state.nextClickAt = now + 0.05
		return
	end

	clickState.phase = "outbound"
	clickState.startedAt = now
	state.nextClickIndex = index % count + 1

	local speedFactor = math.max(1, state.speedFactor or 1)
	local outboundDuration = math.max(0.01, VisualConfig.ClickTravelSeconds / speedFactor)
		+ math.max(0, VisualConfig.ClickHoldSeconds / speedFactor)
	if count == 1 then
		state.nextClickAt = now + outboundDuration + math.max(0.01, VisualConfig.ClickReturnSeconds / speedFactor)
	else
		-- The next clockwise neighbor begins exactly as this mouse starts returning.
		state.nextClickAt = now + outboundDuration
	end
end

local function applyStaticLayout()
	local startAngle = math.rad(VisualConfig.StartAngleDegrees)
	local radius = VisualConfig.OrbitRadiusScale
	for _, state in pairs(statesBySheet) do
		local count = #state.clones
		state.nextClickIndex = 1
		state.nextClickAt = 0
		for index, surfaceGui in ipairs(state.clones) do
			local clickState = state.clickStates[surfaceGui]
			if clickState then
				clickState.phase = "idle"
				clickState.startedAt = 0
			end
			local icon = surfaceGui:FindFirstChild(ICON_NAME, true)
			if icon and icon:IsA("GuiObject") then
				local angle = startAngle + ((index - 1) / math.max(1, count)) * 2 * math.pi
				icon.Position = UDim2.fromScale(0.5 + math.cos(angle) * radius, 0.5 + math.sin(angle) * radius)
				icon.Rotation = math.deg(angle) + VisualConfig.RotationOffsetDegrees
			end
		end
	end
end

if screenGui then
	screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
		elapsed = 0
		if screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
			applyStaticLayout()
		end
	end)
end

RunService.RenderStepped:Connect(function(dt)
	if screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
		return
	end
	elapsed += dt
	local revolutionSeconds = math.max(0.01, VisualConfig.RevolutionSeconds)
	local orbitDirection = VisualConfig.OrbitDirection < 0 and -1 or 1
	local startAngle = math.rad(VisualConfig.StartAngleDegrees)
	local orbitAngle = startAngle + elapsed * (2 * math.pi / revolutionSeconds) * orbitDirection
	for _, state in pairs(statesBySheet) do
		local count = #state.clones
		-- Update phase boundaries before scheduling, so only one mouse is ever
		-- outbound and the next neighbor starts when the prior one turns back.
		for _, surfaceGui in ipairs(state.clones) do
			getClickRadius(state.clickStates[surfaceGui], elapsed, state.speedFactor)
		end
		startNextClockwiseClick(state, elapsed)

		for index, surfaceGui in ipairs(state.clones) do
			if surfaceGui.Parent then
				local icon = surfaceGui:FindFirstChild(ICON_NAME, true)
				if icon and icon:IsA("GuiObject") then
					local angle = orbitAngle + ((index - 1) / math.max(1, count)) * 2 * math.pi
					local radius = getClickRadius(state.clickStates[surfaceGui], elapsed, state.speedFactor)
					icon.Position = UDim2.fromScale(
						0.5 + math.cos(angle) * radius,
						0.5 + math.sin(angle) * radius
					)
					icon.Rotation = math.deg(angle) + VisualConfig.RotationOffsetDegrees
				end
			end
		end
	end
end)
