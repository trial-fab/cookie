-- BuildViewDesktopCamera: the existing PC Build View input and motion path, extracted
-- intact from BuildViewController so mobile can evolve independently.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local BuildViewCamera = require(shared:WaitForChild("BuildViewCamera"))

-- Baked 2026-07-31: the BuildViewCameraDesktop DevTuning registry was retired once its
-- values settled, so every tunable now resolves straight from BuildViewCamera. The keys
-- are kept as the driver's value vocabulary (BuildViewController is driver-agnostic and
-- asks both cameras for values by name), but nothing here is live-adjustable any more.
local VALUES = {
	FieldOfView = BuildViewCamera.DEFAULT_FOV,
	DefaultPitchDegrees = BuildViewCamera.PITCH_DEGREES,
	EntryYawDegrees = BuildViewCamera.ENTRY_YAW_DEGREES,
	MinPitchDegrees = BuildViewCamera.MIN_PITCH_DEGREES,
	MaxPitchDegrees = BuildViewCamera.MAX_PITCH_DEGREES,
	PlacementMarginStuds = BuildViewCamera.PLACEMENT_MARGIN_STUDS,
	EntryFrameScale = BuildViewCamera.ENTRY_FRAME_SCALE,
	RoamSlackStuds = BuildViewCamera.ROAM_SLACK_STUDS,
	CameraStandoffStuds = BuildViewCamera.CAMERA_STANDOFF_STUDS,
	MinHeight = BuildViewCamera.MIN_HEIGHT,
	CeilingAllowance = BuildViewCamera.CEILING_ALLOWANCE,
	BoundsResponseSeconds = BuildViewCamera.BOUNDS_TAU,
	MinDistance = BuildViewCamera.MIN_DISTANCE,
	MaxDistance = BuildViewCamera.MAX_DISTANCE,
	WheelDollyStep = BuildViewCamera.WHEEL_DOLLY_STEP,
	WheelZoomResponseSeconds = BuildViewCamera.WHEEL_ZOOM_TAU,
	MoveSpeed = BuildViewCamera.MOVE_SPEED,
	VerticalSpeed = BuildViewCamera.VERT_SPEED,
	AccelRampSeconds = BuildViewCamera.ACCEL_RAMP_SECONDS,
	AccelMaxMultiplier = BuildViewCamera.ACCEL_MAX_MULTIPLIER,
	MovementResponseSeconds = BuildViewCamera.ACCEL_TAU,
	MovementGlideSeconds = BuildViewCamera.DECEL_TAU,
	EdgePanZonePixels = BuildViewCamera.EDGE_PAN_ZONE_PX,
	EdgePanSpeed = BuildViewCamera.EDGE_PAN_SPEED,
	YawDragSensitivity = BuildViewCamera.YAW_DRAG_SENSITIVITY,
	PitchDragSensitivity = BuildViewCamera.PITCH_DRAG_SENSITIVITY,
}

local KEY_FORWARD = { [Enum.KeyCode.W] = true, [Enum.KeyCode.Up] = true }
local KEY_BACK = { [Enum.KeyCode.S] = true, [Enum.KeyCode.Down] = true }
local KEY_RIGHT = { [Enum.KeyCode.D] = true, [Enum.KeyCode.Right] = true }
local KEY_LEFT = { [Enum.KeyCode.A] = true, [Enum.KeyCode.Left] = true }
local KEY_DOWN = { [Enum.KeyCode.LeftShift] = true, [Enum.KeyCode.RightShift] = true }

local BuildViewDesktopCamera = {}

local function isMoveKey(key)
	return KEY_FORWARD[key]
		or KEY_BACK[key]
		or KEY_RIGHT[key]
		or KEY_LEFT[key]
		or KEY_DOWN[key]
		or key == Enum.KeyCode.Space
end

function BuildViewDesktopCamera.new(ctx)
	local self = {}
	local heldKeys = {}
	local heightHoldDir = 0
	local velocity = Vector3.zero
	local wheelDollyVelocity = Vector3.zero
	local placementDragInput = nil
	local placementDragPosition = nil
	local middleMouseDragging = false
	local middleMouseGrabPoint = nil
	local rightDragging = false
	local moveRampStart = nil

	local function tuning(key)
		return VALUES[key]
	end

	local function pitchLimits()
		local a = math.rad(tuning("MinPitchDegrees"))
		local b = math.rad(tuning("MaxPitchDegrees"))
		return math.min(a, b), math.max(a, b)
	end

	local function distanceLimits()
		local a = tuning("MinDistance")
		local b = tuning("MaxDistance")
		return math.min(a, b), math.max(a, b)
	end

	local function updateMouseBehavior()
		UserInputService.MouseBehavior = rightDragging and Enum.MouseBehavior.LockCurrentPosition
			or Enum.MouseBehavior.Default
	end

	local function setRightDragging(active)
		if rightDragging == active then
			return
		end
		rightDragging = active
		updateMouseBehavior()
	end

	local function setMiddleMouseDragging(active)
		if middleMouseDragging == active then
			return
		end
		middleMouseDragging = active
		if not active then
			middleMouseGrabPoint = nil
		end
		updateMouseBehavior()
	end

	local function speedFactor(base)
		return math.clamp((ctx.getPosition().Y - base.CFrame.Position.Y) / 60, 0.65, 8)
	end

	local function moveAccelFactor(hasInput)
		if not hasInput then
			moveRampStart = nil
			return 1
		end
		if not moveRampStart then
			moveRampStart = os.clock()
		end
		local ramp = math.max(tuning("AccelRampSeconds"), 0.01)
		local maxMultiplier = tuning("AccelMaxMultiplier")
		local alpha = math.clamp((os.clock() - moveRampStart) / ramp, 0, 1)
		return 1 + (maxMultiplier - 1) * alpha
	end

	local function computeMoveTarget(base)
		local forward, right = BuildViewCamera.movementBasis(base.CFrame, ctx.getYaw())
		local dir = Vector3.zero
		for key in pairs(heldKeys) do
			if KEY_FORWARD[key] then
				dir += forward
			elseif KEY_BACK[key] then
				dir -= forward
			elseif KEY_RIGHT[key] then
				dir += right
			elseif KEY_LEFT[key] then
				dir -= right
			end
		end
		local vert = heightHoldDir
		if heldKeys[Enum.KeyCode.Space] then
			vert += 1
		end
		if heldKeys[Enum.KeyCode.LeftShift] or heldKeys[Enum.KeyCode.RightShift] then
			vert -= 1
		end
		vert = math.clamp(vert, -1, 1)
		local hasInput = dir.Magnitude > 1e-3 or vert ~= 0
		local factor = speedFactor(base) * moveAccelFactor(hasInput)
		local horizontal = (dir.Magnitude > 1e-3) and (dir.Unit * tuning("MoveSpeed") * factor) or Vector3.zero
		return horizontal + Vector3.new(0, vert * tuning("VerticalSpeed") * factor, 0)
	end

	local function computePlacementEdgePanTarget(base)
		if not placementDragPosition or not ctx.isPlacementActive() then
			return Vector3.zero
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return Vector3.zero
		end
		local viewport = camera.ViewportSize
		if viewport.X <= 0 or viewport.Y <= 0 then
			return Vector3.zero
		end
		local zone = math.min(tuning("EdgePanZonePixels"), viewport.X * 0.2, viewport.Y * 0.2)
		if zone <= 0 then
			return Vector3.zero
		end
		local x = placementDragPosition.X
		local y = placementDragPosition.Y
		local xDir = 0
		local yDir = 0
		if x < zone then
			xDir = -(1 - x / zone)
		elseif x > viewport.X - zone then
			xDir = (x - (viewport.X - zone)) / zone
		end
		if y < zone then
			yDir = 1 - y / zone
		elseif y > viewport.Y - zone then
			yDir = -((y - (viewport.Y - zone)) / zone)
		end
		xDir = math.clamp(xDir, -1, 1)
		yDir = math.clamp(yDir, -1, 1)
		if xDir == 0 and yDir == 0 then
			return Vector3.zero
		end
		local forward, right = BuildViewCamera.movementBasis(base.CFrame, ctx.getYaw())
		local dir = right * xDir + forward * yDir
		return dir.Magnitude > 1e-3 and (dir.Unit * tuning("EdgePanSpeed") * speedFactor(base)) or Vector3.zero
	end

	local function screenPositionToBasePlanePoint(base, screenPosition)
		local camera = Workspace.CurrentCamera
		if not camera or not base or not screenPosition then
			return nil
		end
		local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)
		if math.abs(ray.Direction.Y) < 1e-6 then
			return nil
		end
		local planeY = base.CFrame.Position.Y + base.Size.Y / 2
		local t = (planeY - ray.Origin.Y) / ray.Direction.Y
		return t > 0 and (ray.Origin + ray.Direction * t) or nil
	end

	function self:getValue(key)
		return tuning(key)
	end

	function self:getPitchLimits()
		return pitchLimits()
	end

	function self:getDistanceLimits()
		return distanceLimits()
	end

	function self:getBoundsOptions()
		return {
			isMobile = false,
			marginStuds = tuning("PlacementMarginStuds"),
			roamSlack = tuning("RoamSlackStuds"),
			cameraStandoff = tuning("CameraStandoffStuds"),
			minHeight = tuning("MinHeight"),
			ceilingAllowance = tuning("CeilingAllowance"),
		}
	end

	function self:getFramingOptions()
		local minDistance, maxDistance = distanceLimits()
		return {
			marginStuds = tuning("PlacementMarginStuds"),
			entryFrameScale = tuning("EntryFrameScale"),
			minDistance = minDistance,
			maxDistance = maxDistance,
		}
	end

	function self:setHeightDirection(direction)
		heightHoldDir = math.clamp(direction or 0, -1, 1)
	end

	function self:onPlacementActiveChanged(active)
		if not active then
			placementDragInput = nil
			placementDragPosition = nil
		end
	end

	function self:reset()
		table.clear(heldKeys)
		heightHoldDir = 0
		velocity = Vector3.zero
		wheelDollyVelocity = Vector3.zero
		placementDragInput = nil
		placementDragPosition = nil
		moveRampStart = nil
		setRightDragging(false)
		setMiddleMouseDragging(false)
	end

	function self:step(dt, base)
		if middleMouseDragging then
			velocity = Vector3.zero
			moveRampStart = nil
		else
			local target = computeMoveTarget(base) + computePlacementEdgePanTarget(base)
			local tau = (target.Magnitude > 1e-3) and tuning("MovementResponseSeconds")
				or tuning("MovementGlideSeconds")
			velocity = velocity:Lerp(target, 1 - math.exp(-dt / tau))
		end
		ctx.setPosition(ctx.getPosition() + velocity * dt)
		if wheelDollyVelocity.Magnitude > 0.01 then
			ctx.setPosition(ctx.getPosition() + wheelDollyVelocity * dt)
			wheelDollyVelocity *= math.exp(-dt / tuning("WheelZoomResponseSeconds"))
		else
			wheelDollyVelocity = Vector3.zero
		end
	end

	UserInputService.InputChanged:Connect(function(input, gameProcessed)
		if not ctx.isSelected() or not ctx.isActive() then
			return
		end
		if placementDragInput == "mouse" and input.UserInputType == Enum.UserInputType.MouseMovement then
			placementDragPosition = UserInputService:GetMouseLocation()
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			if gameProcessed or ctx.isInputBlocked(UserInputService:GetMouseLocation()) then
				return
			end
			local base = ctx.getBasePart()
			if base then
				local lookDir = BuildViewCamera.lookDirection(base.CFrame, ctx.getYaw(), ctx.getPitch())
				wheelDollyVelocity += lookDir * ((input.Position.Z * tuning("WheelDollyStep")) / tuning(
					"WheelZoomResponseSeconds"
				))
			end
		elseif middleMouseDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local base = ctx.getBasePart()
			local cursorPoint = base and screenPositionToBasePlanePoint(base, UserInputService:GetMouseLocation())
			if cursorPoint and middleMouseGrabPoint then
				ctx.setPosition(ctx.getPosition() + middleMouseGrabPoint - cursorPoint)
				velocity = Vector3.zero
				wheelDollyVelocity = Vector3.zero
				ctx.renderNow(base)
			elseif cursorPoint then
				middleMouseGrabPoint = cursorPoint
			end
		elseif rightDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			ctx.setYaw(ctx.getYaw() - input.Delta.X * tuning("YawDragSensitivity"))
			local minPitch, maxPitch = pitchLimits()
			ctx.setPitch(
				math.clamp(ctx.getPitch() + input.Delta.Y * tuning("PitchDragSensitivity"), minPitch, maxPitch)
			)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not ctx.isSelected() then
			return
		end
		-- BuildViewController sinks Shift so Roblox's Mouse Lock cannot toggle while
		-- the scriptable camera is active. Accept that processed Shift as descend input.
		local processedBuildViewShift = ctx.isActive()
			and KEY_DOWN[input.KeyCode] == true
			and UserInputService:GetFocusedTextBox() == nil
		local isPointerPress = input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton3
		local startsOnUi = isPointerPress and ctx.isInputBlocked(input.Position)
		if gameProcessed and not processedBuildViewShift then
			return
		end
		if
			ctx.isActive()
			and ctx.isPlacementActive()
			and not startsOnUi
			and input.UserInputType == Enum.UserInputType.MouseButton1
		then
			placementDragInput = "mouse"
			placementDragPosition = UserInputService:GetMouseLocation()
		end
		if input.KeyCode == Enum.KeyCode.V then
			ctx.toggleBuildView()
			return
		elseif input.KeyCode == Enum.KeyCode.Escape and ctx.isActive() then
			ctx.exitBuildView()
			return
		end
		if ctx.isActive() and input.UserInputType == Enum.UserInputType.MouseButton2 then
			setRightDragging(true)
			return
		end
		if ctx.isActive() and input.UserInputType == Enum.UserInputType.MouseButton3 and not startsOnUi then
			local base = ctx.getBasePart()
			local grabPoint = base and screenPositionToBasePlanePoint(base, UserInputService:GetMouseLocation())
			if grabPoint then
				middleMouseGrabPoint = grabPoint
				setMiddleMouseDragging(true)
				velocity = Vector3.zero
				wheelDollyVelocity = Vector3.zero
			end
			return
		end
		if ctx.isActive() and isMoveKey(input.KeyCode) then
			heldKeys[input.KeyCode] = true
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not ctx.isSelected() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and placementDragInput == "mouse" then
			placementDragInput = nil
			placementDragPosition = nil
		end
		if isMoveKey(input.KeyCode) then
			heldKeys[input.KeyCode] = nil
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			setRightDragging(false)
		end
		if input.UserInputType == Enum.UserInputType.MouseButton3 then
			setMiddleMouseDragging(false)
		end
	end)

	return self
end

return BuildViewDesktopCamera
