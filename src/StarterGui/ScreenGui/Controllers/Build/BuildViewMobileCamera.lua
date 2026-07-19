-- Touch-first Build View camera. This owns no lifecycle or plot discovery; it only
-- translates phone gestures into camera state supplied by BuildViewController.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local BuildViewCamera = require(shared:WaitForChild("BuildViewCamera"))
local Config = require(shared:WaitForChild("BuildViewMobileCameraConfig"))
local DevTuning = require(shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))

local FEATURE = "BuildViewCameraMobile"
local BuildViewMobileCamera = {}

local function touchPosition(input)
	return Vector2.new(input.Position.X, input.Position.Y)
end

local function wrapAngle(angle)
	return (angle + math.pi) % (2 * math.pi) - math.pi
end

function BuildViewMobileCamera.new(ctx)
	local self = {}
	local tuningCache = {}
	local tuningObserved = {}
	local touches = {}
	local touchOrder = {}
	local multiLatched = false
	local multiStart = nil
	local singleTouch = nil
	local singleStartPosition = nil
	local lastPanPosition = nil
	local lastPanTime = nil
	local lastPanMoveTime = nil
	local smoothedScreenVelocity = Vector2.zero
	local panMomentum = Vector3.zero
	local placementPosition = nil
	local heightHoldDir = 0

	local function tuning(key)
		if tuningCache[key] == nil then
			local dottedId = FEATURE .. "." .. key
			tuningCache[key] = DevTuning.get(dottedId)
			if not tuningObserved[key] then
				tuningObserved[key] = true
				DevTuning.observe(dottedId, function(value)
					tuningCache[key] = value
				end)
			end
		end
		return tuningCache[key]
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

	local function activeTouches()
		local result = {}
		for _, input in ipairs(touchOrder) do
			local record = touches[input]
			if record then
				if record.blocked then
					return {}
				end
				table.insert(result, { input = input, position = record.position })
			end
		end
		return result
	end

	local function pixelsToWorldMovement(base, pixels)
		local camera = Workspace.CurrentCamera
		if not camera then
			return Vector3.zero
		end
		-- Ground-plane ray intersections approach infinity as the camera flattens. Derive
		-- pan scale from camera height and a fixed reference pitch instead, so the same
		-- finger travel has the same response at every current pitch. The explicit cap
		-- also contains unusually tall or temporarily out-of-bounds camera states.
		local planeY = base.CFrame.Position.Y + base.Size.Y / 2
		local height = math.max(1, ctx.getPosition().Y - planeY)
		local referencePitch = math.rad(math.clamp(tuning("PanReferencePitchDegrees"), 5, 85))
		local referenceDistance = height / math.max(math.sin(referencePitch), 0.1)
		local viewportY = math.max(1, camera.ViewportSize.Y)
		local studsPerPixel = math.min(
			(2 * referenceDistance * math.tan(math.rad(tuning("FieldOfView") / 2))) / viewportY,
			tuning("PanMaxStudsPerPixel")
		)
		local forward, right = BuildViewCamera.movementBasis(base.CFrame, ctx.getYaw())
		return right * (-pixels.X * studsPerPixel) + forward * (pixels.Y * studsPerPixel)
	end

	local function clearSinglePan()
		singleTouch = nil
		singleStartPosition = nil
		lastPanPosition = nil
		lastPanTime = nil
		lastPanMoveTime = nil
		smoothedScreenVelocity = Vector2.zero
	end

	local function startSinglePan(touch)
		clearSinglePan()
		singleTouch = touch.input
		singleStartPosition = touch.position
		lastPanPosition = touch.position
		lastPanTime = os.clock()
	end

	local function multiMetrics(active)
		local a = active[1].position
		local b = active[2].position
		local delta = b - a
		return (a + b) / 2, math.max(delta.Magnitude, 1), math.atan2(delta.Y, delta.X)
	end

	local function startMultiGesture(base, active)
		clearSinglePan()
		panMomentum = Vector3.zero
		if #active < 2 then
			multiStart = nil
			return
		end
		local centroid, spacing, angle = multiMetrics(active)
		local position = ctx.getPosition()
		local yaw = ctx.getYaw()
		local pitch = ctx.getPitch()
		-- Multi-touch is camera-centered, not finger-centered. Measuring distance from the
		-- current center-screen focus prevents a gesture begun in a corner from pulling the
		-- camera toward that corner.
		local focus = BuildViewCamera.focusPoint(position, base.CFrame, base.Size, yaw, pitch)
		multiStart = {
			first = active[1].input,
			second = active[2].input,
			centroid = centroid,
			spacing = spacing,
			angle = angle,
			position = position,
			yaw = yaw,
			pitch = pitch,
			lookDirection = BuildViewCamera.lookDirection(base.CFrame, yaw, pitch),
			distance = focus and math.max(1, (position - focus).Magnitude) or 120,
		}
	end

	local function updateMultiGesture(base, active)
		if #active < 2 then
			return
		end
		if not multiStart or multiStart.first ~= active[1].input or multiStart.second ~= active[2].input then
			startMultiGesture(base, active)
		end
		if not multiStart then
			return
		end
		local centroid, spacing, angle = multiMetrics(active)
		local relativeSpacing = spacing / multiStart.spacing
		local effectiveSpacing = relativeSpacing ^ tuning("PinchSensitivity")
		local minDistance, maxDistance = distanceLimits()
		local distance = math.clamp(multiStart.distance / effectiveSpacing, minDistance, maxDistance)
		local yaw = multiStart.yaw + wrapAngle(angle - multiStart.angle) * tuning("TwistSensitivity")
		local verticalTravel = centroid.Y - multiStart.centroid.Y
		local deadZone = tuning("PitchDeadZonePixels")
		local effectiveVertical = math.sign(verticalTravel) * math.max(0, math.abs(verticalTravel) - deadZone)
		local minPitch, maxPitch = pitchLimits()
		local pitch =
			math.clamp(multiStart.pitch + effectiveVertical * Config.PITCH_DRAG_SENSITIVITY, minPitch, maxPitch)
		ctx.setYaw(yaw)
		ctx.setPitch(pitch)
		-- Twist and vertical pitch rotate in place. Only pinch translates the camera, and
		-- it dollies along the view direction captured at gesture start rather than toward
		-- the fingers' screen position.
		local dollyDistance = multiStart.distance - distance
		ctx.setPosition(multiStart.position + multiStart.lookDirection * dollyDistance)
		ctx.renderNow(base)
	end

	local function updateSinglePan(base, touch)
		if singleTouch ~= touch.input or not lastPanPosition then
			startSinglePan(touch)
			return
		end
		local screenDelta = touch.position - lastPanPosition
		ctx.setPosition(ctx.getPosition() + pixelsToWorldMovement(base, screenDelta))
		local now = os.clock()
		local elapsed = lastPanTime and (now - lastPanTime) or 0
		if lastPanPosition and elapsed > 1e-4 then
			local sample = (touch.position - lastPanPosition) / elapsed
			local weight = math.clamp(tuning("PanVelocitySmoothing"), 0, 1)
			smoothedScreenVelocity = smoothedScreenVelocity:Lerp(sample, weight)
			lastPanMoveTime = now
		end
		lastPanPosition = touch.position
		lastPanTime = now
		ctx.renderNow(base)
	end

	local function updateTouches()
		if not ctx.isSelected() or not ctx.isActive() then
			return
		end
		local base = ctx.getBasePart()
		if not base then
			return
		end
		local active = activeTouches()
		if #active >= 2 then
			multiLatched = true
			placementPosition = nil
			updateMultiGesture(base, active)
		elseif #active == 1 then
			multiStart = nil
			if ctx.isPlacementActive() then
				placementPosition = active[1].position
				clearSinglePan()
			elseif not multiLatched then
				placementPosition = nil
				updateSinglePan(base, active[1])
			end
		else
			placementPosition = nil
		end
	end

	local function computePlacementEdgePan(base)
		if not placementPosition or not ctx.isPlacementActive() or #activeTouches() >= 2 then
			return Vector3.zero
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return Vector3.zero
		end
		local viewport = camera.ViewportSize
		local zone = math.min(tuning("EdgePanZonePixels"), viewport.X * 0.2, viewport.Y * 0.2)
		if zone <= 0 then
			return Vector3.zero
		end
		local xDir = 0
		local yDir = 0
		if placementPosition.X < zone then
			xDir = -(1 - placementPosition.X / zone)
		elseif placementPosition.X > viewport.X - zone then
			xDir = (placementPosition.X - (viewport.X - zone)) / zone
		end
		if placementPosition.Y < zone then
			yDir = 1 - placementPosition.Y / zone
		elseif placementPosition.Y > viewport.Y - zone then
			yDir = -((placementPosition.Y - (viewport.Y - zone)) / zone)
		end
		local forward, right = BuildViewCamera.movementBasis(base.CFrame, ctx.getYaw())
		local direction = right * math.clamp(xDir, -1, 1) + forward * math.clamp(yDir, -1, 1)
		return direction.Magnitude > 1e-3 and direction.Unit * tuning("EdgePanSpeed") or Vector3.zero
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
		panMomentum = Vector3.zero
		clearSinglePan()
		if active then
			local activeNow = activeTouches()
			placementPosition = activeNow[1] and activeNow[1].position or nil
		elseif #activeTouches() == 1 then
			multiLatched = true
			placementPosition = nil
		end
	end

	function self:reset()
		table.clear(touches)
		table.clear(touchOrder)
		multiLatched = false
		multiStart = nil
		placementPosition = nil
		heightHoldDir = 0
		panMomentum = Vector3.zero
		clearSinglePan()
	end

	function self:step(dt, base)
		if panMomentum.Magnitude > 0.01 and #activeTouches() == 0 then
			ctx.setPosition(ctx.getPosition() + panMomentum * dt)
			panMomentum *= math.exp(-dt / math.max(tuning("PanMomentumSeconds"), 0.001))
		else
			panMomentum = Vector3.zero
		end
		local edgePan = computePlacementEdgePan(base)
		ctx.setPosition(ctx.getPosition() + edgePan * dt)
		if heightHoldDir ~= 0 then
			ctx.setPosition(ctx.getPosition() + Vector3.new(0, heightHoldDir * tuning("VerticalSpeed") * dt, 0))
		end
	end

	DevTuning.observe(FEATURE .. ".DefaultPitchDegrees", function(value)
		tuningCache.DefaultPitchDegrees = value
		if ctx.isSelected() and ctx.isActive() then
			local minPitch, maxPitch = pitchLimits()
			ctx.setPitch(math.clamp(math.rad(value), minPitch, maxPitch))
		end
	end)
	for _, key in ipairs({ "MinPitchDegrees", "MaxPitchDegrees" }) do
		DevTuning.observe(FEATURE .. "." .. key, function(value)
			tuningCache[key] = value
			if ctx.isSelected() and ctx.isActive() then
				local minPitch, maxPitch = pitchLimits()
				ctx.setPitch(math.clamp(ctx.getPitch(), minPitch, maxPitch))
			end
		end)
	end
	DevTuning.observe(FEATURE .. ".FieldOfView", function(value)
		tuningCache.FieldOfView = value
		local camera = Workspace.CurrentCamera
		if ctx.isSelected() and ctx.isActive() and camera then
			camera.FieldOfView = value
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not ctx.isSelected() or not ctx.isActive() or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		panMomentum = Vector3.zero
		touches[input] = {
			position = touchPosition(input),
			blocked = gameProcessed or ctx.isInputBlocked(input.Position),
		}
		table.insert(touchOrder, input)
		local active = activeTouches()
		if #active >= 2 then
			multiLatched = true
			local base = ctx.getBasePart()
			if base then
				startMultiGesture(base, active)
			end
		elseif #active == 1 and ctx.isPlacementActive() then
			placementPosition = active[1].position
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		local record = touches[input]
		if not record then
			return
		end
		record.position = touchPosition(input)
		updateTouches()
	end)

	UserInputService.InputEnded:Connect(function(input)
		local record = touches[input]
		if not record then
			return
		end
		local wasSinglePan = input == singleTouch and not multiLatched and not ctx.isPlacementActive()
		local base = ctx.getBasePart()
		local dragTravel = singleStartPosition and lastPanPosition and (lastPanPosition - singleStartPosition).Magnitude
			or 0
		local flingSpeed = smoothedScreenVelocity.Magnitude
		local minFlingSpeed = tuning("MinFlingPixelsPerSecond")
		local maxFlingSpeed = math.max(minFlingSpeed, tuning("MaxFlingPixelsPerSecond"))
		if
			wasSinglePan
			and base
			and lastPanMoveTime
			and os.clock() - lastPanMoveTime <= tuning("MomentumReleaseWindowSeconds")
			and dragTravel >= tuning("MinFlingTravelPixels")
			and flingSpeed >= minFlingSpeed
		then
			-- Subtract the threshold rather than launching at full threshold speed. This
			-- creates a smooth ramp from parked to gliding, while the upper clamp rejects
			-- tiny-time-step velocity spikes from touch hardware.
			local effectiveSpeed = math.clamp(flingSpeed - minFlingSpeed, 0, maxFlingSpeed - minFlingSpeed)
			local effectiveVelocity = flingSpeed > 1e-4 and (smoothedScreenVelocity.Unit * effectiveSpeed)
				or Vector2.zero
			panMomentum = pixelsToWorldMovement(base, effectiveVelocity) * tuning("PanMomentumScale")
		else
			panMomentum = Vector3.zero
		end
		touches[input] = nil
		for index, orderedInput in ipairs(touchOrder) do
			if orderedInput == input then
				table.remove(touchOrder, index)
				break
			end
		end
		clearSinglePan()
		local active = activeTouches()
		if #active == 0 then
			multiLatched = false
			multiStart = nil
			placementPosition = nil
		elseif #active >= 2 then
			if base then
				startMultiGesture(base, active)
			end
		else
			multiStart = nil
			placementPosition = ctx.isPlacementActive() and active[1].position or nil
		end
	end)

	return self
end

return BuildViewMobileCamera
