-- Shared framing math for the free-fly "Build View" placement camera.
--
-- Pure functions only (no Workspace/Camera access) so the BuildViewController and
-- verification scripts can both call them. Mirrors the GridPlacement pattern: the
-- plot's live Base part is the single source of truth -- grid dimensions are never
-- hardcoded, so the fixed Ground footprint and future dimensions get correct framing.
--
-- Camera model (replaces the old top-down solve): the camera is a FREE point in space
-- with a FIXED orientation -- a pitched 3/4 view, no mouselook. The controller flies
-- the position around (momentum glide + height + dolly); this module only converts a
-- position into a CFrame, supplies the movement basis, frames the plot on entry, and
-- eases an out-of-bounds position back toward the player's unlocked build surfaces
-- (Ground plus unlocked terraced floors -- loose "free roam" bounds that grow with
-- each floor unlock and shrink back to the single plot after a stat reset).
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

-- "Loose free roam": slack (studs) past a surface edge + margin before softBounds eases
-- the camera back. Baked from the user's live-tuning pass 2026-07-18: zero slack -- the
-- framing margin alone is the roam allowance, keeping flight tight to the build surfaces.
BuildViewCamera.ROAM_SLACK_STUDS = 0

-- Soft vertical band. MIN_HEIGHT (studs) is the camera's clearance above the MAP surface
-- directly beneath it (the controller probes plot/terrace/crater geometry and passes its
-- top through options.supportTopY) -- the camera therefore "collides" with the world:
-- flying into a terrace wall trails it up the wall face onto the new level instead of
-- popping at a footprint edge. CEILING_ALLOWANCE is how far (studs) above that SAME
-- beneath-the-camera surface the camera may rise -- the whole fly band terrain-follows,
-- so the ceiling over Ground sits allowance above Ground while the ceiling over an
-- unlocked terrace sits allowance above THAT terrace (never "all the floors + allowance"
-- everywhere). Cresting off a terrace edge eases the camera back down over the lower
-- ground. Entry framing is clamped through softBounds, so a ceiling below the framing
-- height simply lands the fly-in closer. Baked from the user's live-tuning pass
-- 2026-07-18.
BuildViewCamera.MIN_HEIGHT = 8
BuildViewCamera.CEILING_ALLOWANCE = 60

-- Extra horizontal allowance (studs) on top of ROAM_SLACK for the camera body to sit
-- back from a surface edge. Total legal drift past a surface edge = margin + ROAM_SLACK
-- + CAMERA_STANDOFF. Baked at zero from the user's live-tuning pass 2026-07-18.
BuildViewCamera.CAMERA_STANDOFF_STUDS = 0

-- Fly movement (the controller reads these). MOVE_SPEED is the base horizontal speed
-- (studs/s) before height scaling and the acceleration ramp; VERT_SPEED is its vertical
-- counterpart. Studio-style acceleration: continuously held movement ramps linearly from
-- 1x up to ACCEL_MAX_MULTIPLIER over ACCEL_RAMP_SECONDS and resets the moment input
-- stops, so taps stay precise and long holds cross the plot fast. Baked from the user's
-- live-tuning pass 2026-07-18.
BuildViewCamera.MOVE_SPEED = 60
BuildViewCamera.VERT_SPEED = 48
BuildViewCamera.ACCEL_RAMP_SECONDS = 1.5
BuildViewCamera.ACCEL_MAX_MULTIPLIER = 2

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

-- Loose "free roam" soft bounds over every unlocked build surface. `surfaces` is a
-- Ground-first array of { cframe, size } (FloorGeometry.GetUnlockedSurfaces order).
-- `options` (all optional):
--   isMobile         -- widens the framing margin (see getMargin)
--   roamSlack        -- overrides ROAM_SLACK_STUDS (verification/tests)
--   cameraStandoff   -- overrides CAMERA_STANDOFF_STUDS (verification/tests)
--   ceilingAllowance -- overrides CEILING_ALLOWANCE (verification/tests)
--   supportTopY      -- world Y of the map surface directly beneath the camera (the
--                       controller's terrain probe); the WHOLE vertical band rides it:
--                       bottom lock MIN_HEIGHT above it (flying into a terrace wall
--                       trails the camera up onto the new level) and ceiling
--                       ceilingAllowance above it. Falls back to Ground top.
-- Returns a TARGET position the controller should ease toward (lerp), so corrections
-- feel springy rather than hard-clamped; inside the loose region the position comes back
-- unchanged (no pull -> true free roam within bounds).
--
-- Horizontal: the camera POSITION may roam over ANY unlocked surface's loose rect
-- (half-extent + margin + roamSlack + cameraStandoff) -- terraced floors extend the roam
-- region outward, and relocking to Ground-only shrinks it back. Outside every rect, the
-- smallest correction wins so the camera eases toward the nearest unlocked surface.
-- Deliberately POSITION-based, never focus-ray-based: bounds that test where the look
-- ray lands drag the camera body around during Studio-style mouselook (spinning in place
-- sweeps the focus out of bounds and the "correction" moves the player). Where the
-- camera LOOKS must never move it.
--
-- Vertical: [supportTopY + MIN_HEIGHT, supportTopY + ceiling allowance] -- the whole
-- band rides the surface currently beneath the camera, so height access terrain-follows
-- the terraces instead of granting the top floor's ceiling everywhere.
function BuildViewCamera.softBounds(cameraPos, surfaces, options)
	if type(surfaces) ~= "table" or #surfaces == 0 then
		return cameraPos
	end
	options = options or {}
	local margin = BuildViewCamera.getMargin(options.isMobile)
	local allowance = margin
		+ (options.roamSlack or BuildViewCamera.ROAM_SLACK_STUDS)
		+ (options.cameraStandoff or BuildViewCamera.CAMERA_STANDOFF_STUDS)
	local target = cameraPos

	local bestDelta = nil
	local bestMagnitude = math.huge

	for _, surface in ipairs(surfaces) do
		local localPos = surface.cframe:PointToObjectSpace(cameraPos)
		local allowX = surface.size.X / 2 + allowance
		local allowZ = surface.size.Z / 2 + allowance
		local clampedX = clamp(localPos.X, -allowX, allowX)
		local clampedZ = clamp(localPos.Z, -allowZ, allowZ)
		if clampedX == localPos.X and clampedZ == localPos.Z then
			-- Inside any surface's loose rect -> horizontally in bounds.
			bestDelta = nil
			break
		end
		local corrected = surface.cframe:PointToWorldSpace(
			Vector3.new(clampedX, localPos.Y, clampedZ))
		local delta = corrected - cameraPos
		if delta.Magnitude < bestMagnitude then
			bestDelta = delta
			bestMagnitude = delta.Magnitude
		end
	end

	if bestDelta then
		target = target + bestDelta
	end

	local groundTopY = surfaces[1].cframe.Position.Y + surfaces[1].size.Y / 2
	local supportTopY = options.supportTopY or groundTopY
	local minY = supportTopY + BuildViewCamera.MIN_HEIGHT
	local maxY = supportTopY + (options.ceilingAllowance or BuildViewCamera.CEILING_ALLOWANCE)
	local clampedY = clamp(target.Y, minY, math.max(maxY, minY))
	if clampedY ~= target.Y then
		target = Vector3.new(target.X, clampedY, target.Z)
	end

	return target
end

return BuildViewCamera
