-- Shared framing math for the free-fly "Build View" placement camera.
--
-- Pure functions only (no Workspace/Camera access) so the BuildViewController and
-- verification scripts can both call them. Mirrors the GridPlacement pattern: the
-- plot's live Base part is the single source of truth -- grid dimensions are never
-- hardcoded, so Base Expansion (22x22 -> 26x26 -> 30x30) and future dimensions get
-- correct framing for free.
--
-- Camera model (replaces the old top-down solve): the camera is a FREE point in space
-- with a FIXED orientation -- a pitched 3/4 view, no mouselook. The controller flies
-- the position around (momentum glide + height + dolly); this module only converts a
-- position into a CFrame, supplies the movement basis, frames the plot on entry, and
-- eases an out-of-bounds position back toward the plot (loose "free roam" bounds).
local BuildViewCamera = {}

-- Vertical field of view (degrees).
BuildViewCamera.DEFAULT_FOV = 60

-- Fixed downward pitch (degrees below horizontal) of the look direction. ~55 gives a
-- comfortable 3/4 "creative" view that reads the plot clearly without going flat-on or
-- straight-down.
BuildViewCamera.PITCH_DEGREES = 55

-- Range the player may tilt the view to (degrees below horizontal) via right-drag. Kept
-- off the horizon (so you never look up under the plot) and short of straight-down.
BuildViewCamera.MIN_PITCH_DEGREES = 20
BuildViewCamera.MAX_PITCH_DEGREES = 85

-- Breathing room (studs) added around the editable grid when framing on entry so the
-- plot edge never sits flush against the screen edge. ~1.5 cells (GRID_SIZE 6).
BuildViewCamera.PLACEMENT_MARGIN_STUDS = 9

-- Mobile devices lose screen real estate to notches/safe areas and the store panel, so
-- frame a little wider there to keep the whole plot comfortably visible.
BuildViewCamera.MOBILE_MARGIN_SCALE = 1.18

-- "Loose free roam": how far (studs) past the plot edge + margin the focus point may
-- drift before softBounds eases it back. Generous so you can fly out for an overview.
BuildViewCamera.ROAM_SLACK_STUDS = 45

-- Absolute height clamps (studs above the Base) for the soft vertical band. MIN keeps
-- the camera from sinking into the plot; MAX is far above any realistic plot so you can
-- rise for an overview but never fly off to infinity.
BuildViewCamera.MIN_HEIGHT = 8
BuildViewCamera.MAX_HEIGHT = 1200

-- Dolly (zoom) distance clamps along the look direction, measured camera->focus.
BuildViewCamera.MIN_DISTANCE = 16
BuildViewCamera.MAX_DISTANCE = 2200

local function clamp(value, lo, hi)
	return math.max(lo, math.min(hi, value))
end

-- Resolve the framing margin for a device class (studs added to each half-extent).
function BuildViewCamera.getMargin(isMobile, marginStuds)
	local margin = marginStuds or BuildViewCamera.PLACEMENT_MARGIN_STUDS
	if isMobile then
		margin = margin * BuildViewCamera.MOBILE_MARGIN_SCALE
	end
	return margin
end

-- Default pitch (radians below horizontal) when the caller doesn't override it.
local function defaultPitch()
	return math.rad(BuildViewCamera.PITCH_DEGREES)
end

-- Horizontal "forward" (into the scene) and "right" basis vectors in WORLD space,
-- derived from the plot orientation (so WASD / drag track the plot even if a future plot
-- is not axis-aligned) and rotated by an optional view `yaw` (radians) around world-up so
-- movement follows the rotated view. Both are flattened onto the horizontal plane and
-- unit length.
function BuildViewCamera.movementBasis(baseCFrame, yaw)
	local up = Vector3.new(0, 1, 0)
	local forward = baseCFrame.LookVector
	forward = Vector3.new(forward.X, 0, forward.Z)
	if forward.Magnitude < 1e-4 then
		-- Degenerate (Base facing straight up/down) -- fall back to world +Z.
		forward = Vector3.new(0, 0, 1)
	end
	forward = forward.Unit
	if yaw and yaw ~= 0 then
		forward = CFrame.fromAxisAngle(up, yaw):VectorToWorldSpace(forward)
	end
	local right = forward:Cross(up).Unit
	return forward, right
end

-- Unit look direction: the (yaw-rotated) horizontal forward pitched downward by `pitch`
-- radians (default PITCH_DEGREES).
function BuildViewCamera.lookDirection(baseCFrame, yaw, pitch)
	pitch = pitch or defaultPitch()
	local forward = BuildViewCamera.movementBasis(baseCFrame, yaw)
	-- Forward-and-down: horizontal component shrinks by cos, downward component is -sin.
	return (forward * math.cos(pitch) + Vector3.new(0, -1, 0) * math.sin(pitch)).Unit
end

-- Build the camera CFrame for a given world position, looking along the view direction.
function BuildViewCamera.toCFrame(cameraPos, baseCFrame, yaw, pitch)
	local lookDir = BuildViewCamera.lookDirection(baseCFrame, yaw, pitch)
	return CFrame.lookAt(cameraPos, cameraPos + lookDir, Vector3.new(0, 1, 0))
end

-- Initial camera position that frames the whole plot at the fixed angle on entry.
-- Uses the plot's in-plane bounding radius (conservative -- guarantees the whole plot is
-- visible at any yaw) and the limiting half-FOV to choose a dolly distance, then steps
-- back from the plot center along -lookDirection. Returns a Vector3.
function BuildViewCamera.framePose(baseCFrame, baseSize, viewportSize, isMobile, fov, yaw, pitch)
	fov = fov or BuildViewCamera.DEFAULT_FOV
	local margin = BuildViewCamera.getMargin(isMobile)

	local vx = (viewportSize and viewportSize.X) or 1280
	local vy = (viewportSize and viewportSize.Y) or 720
	if vx <= 0 then vx = 1280 end
	if vy <= 0 then vy = 720 end
	local aspect = vx / vy

	local halfX = baseSize.X / 2 + margin
	local halfZ = baseSize.Z / 2 + margin
	local boundingRadius = math.sqrt(halfX * halfX + halfZ * halfZ)

	local vertHalf = math.rad(fov / 2)
	local horizHalf = math.atan(math.tan(vertHalf) * aspect)
	local limitingHalf = math.min(vertHalf, horizHalf)
	-- 1.1 keeps a little air around the plot rather than framing it edge-to-edge.
	local distance = clamp((boundingRadius / math.tan(limitingHalf)) * 1.1,
		BuildViewCamera.MIN_DISTANCE, BuildViewCamera.MAX_DISTANCE)

	local lookDir = BuildViewCamera.lookDirection(baseCFrame, yaw, pitch)
	-- Center on the Base top surface so the plot, not its underside, is framed.
	local center = baseCFrame.Position + Vector3.new(0, baseSize.Y / 2, 0)
	return center - lookDir * distance
end

-- Project the camera's look-ray onto the Base top plane; returns the world focus point
-- (or nil if the look direction is parallel to the plane, which the pitch range avoids).
function BuildViewCamera.focusPoint(cameraPos, baseCFrame, baseSize, yaw, pitch)
	local lookDir = BuildViewCamera.lookDirection(baseCFrame, yaw, pitch)
	local normal = Vector3.new(0, 1, 0)
	local denom = lookDir:Dot(normal)
	if math.abs(denom) < 1e-6 then
		return nil
	end
	local planeY = baseCFrame.Position.Y + baseSize.Y / 2
	local t = (planeY - cameraPos.Y) / denom
	if t <= 0 then
		return nil
	end
	return cameraPos + lookDir * t
end

-- Loose "free roam" soft bounds. Returns a TARGET position the controller should ease
-- toward (lerp), so corrections feel springy rather than hard-clamped. Horizontal: if the
-- focus point drifts past the plot half-extent + margin + ROAM_SLACK, shift the camera so
-- the focus returns to that loose edge. Vertical: keep the camera within the [MIN,MAX]
-- height band above the Base. When the camera is already inside the loose region the
-- position is returned unchanged (no pull -> true free roam within bounds).
function BuildViewCamera.softBounds(cameraPos, baseCFrame, baseSize, isMobile, yaw, pitch)
	local margin = BuildViewCamera.getMargin(isMobile)
	local target = cameraPos

	local focus = BuildViewCamera.focusPoint(cameraPos, baseCFrame, baseSize, yaw, pitch)
	if focus then
		local localFocus = baseCFrame:PointToObjectSpace(focus)
		local allowX = baseSize.X / 2 + margin + BuildViewCamera.ROAM_SLACK_STUDS
		local allowZ = baseSize.Z / 2 + margin + BuildViewCamera.ROAM_SLACK_STUDS
		local clampedX = clamp(localFocus.X, -allowX, allowX)
		local clampedZ = clamp(localFocus.Z, -allowZ, allowZ)
		if clampedX ~= localFocus.X or clampedZ ~= localFocus.Z then
			-- Orientation is fixed, so translating the focus by a world delta translates
			-- the camera by the same delta. Convert the in-plane correction to world space.
			local correctedFocus = baseCFrame:PointToWorldSpace(
				Vector3.new(clampedX, localFocus.Y, clampedZ))
			target = target + (correctedFocus - focus)
		end
	end

	local minY = baseCFrame.Position.Y + BuildViewCamera.MIN_HEIGHT
	local maxY = baseCFrame.Position.Y + BuildViewCamera.MAX_HEIGHT
	local clampedY = clamp(target.Y, minY, maxY)
	if clampedY ~= target.Y then
		target = Vector3.new(target.X, clampedY, target.Z)
	end

	return target
end

return BuildViewCamera
