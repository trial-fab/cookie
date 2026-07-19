-- Independent touch-camera controls for real-phone testing. Nothing in this group
-- changes the desktop camera, and all edits remain session-only until deliberately baked.
local Config = require(script.Parent.Parent.Parent:WaitForChild("BuildViewMobileCameraConfig"))

local function number(key, default, min, max, step, description)
	return {
		key = key,
		default = default,
		kind = "number",
		min = min,
		max = max,
		step = step,
		scope = "client",
		description = description,
	}
end

return {
	feature = "BuildViewCameraMobile",
	collapsedByDefault = false,
	tunables = {
		number("FieldOfView", Config.DEFAULT_FOV, 20, 100, 1, "Mobile Build View field of view."),
		number("DefaultPitchDegrees", Config.PITCH_DEGREES, 5, 89, 1, "Mobile starting downward pitch."),
		number("MinPitchDegrees", Config.MIN_PITCH_DEGREES, 1, 89, 1, "Mobile shallow pitch limit."),
		number("MaxPitchDegrees", Config.MAX_PITCH_DEGREES, 1, 89, 1, "Mobile steep pitch limit."),
		number(
			"PlacementMarginStuds",
			Config.PLACEMENT_MARGIN_STUDS,
			0,
			500,
			1,
			"Mobile framing and bounds margin around build surfaces."
		),
		number(
			"EntryFrameScale",
			Config.ENTRY_FRAME_SCALE,
			0.5,
			3,
			0.05,
			"Mobile automatic-entry distance multiplier."
		),
		number("RoamSlackStuds", Config.ROAM_SLACK_STUDS, 0, 1000, 1, "Mobile travel outside the surface margin."),
		number(
			"CameraStandoffStuds",
			Config.CAMERA_STANDOFF_STUDS,
			0,
			1000,
			1,
			"Mobile camera-body pull-back allowance."
		),
		number("MinHeight", Config.MIN_HEIGHT, 0, 500, 1, "Mobile minimum map clearance."),
		number("CeilingAllowance", Config.CEILING_ALLOWANCE, 1, 3000, 1, "Mobile maximum height above the map."),
		number("BoundsResponseSeconds", Config.BOUNDS_TAU, 0.02, 3, 0.01, "Mobile bounds correction time constant."),
		number("MinDistance", Config.MIN_DISTANCE, 1, 1000, 1, "Mobile minimum pinch/entry distance."),
		number("MaxDistance", Config.MAX_DISTANCE, 16, 5000, 1, "Mobile maximum pinch/entry distance."),
		number(
			"EdgePanZonePixels",
			Config.EDGE_PAN_ZONE_PX,
			0,
			400,
			1,
			"Placement distance from a screen edge that starts mobile panning."
		),
		number("EdgePanSpeed", Config.EDGE_PAN_SPEED, 0, 500, 1, "Mobile placement edge-pan speed."),
		number("VerticalSpeed", Config.VERT_SPEED, 1, 500, 1, "Mobile rise and descend speed."),
		number(
			"PanMomentumSeconds",
			Config.PAN_MOMENTUM_SECONDS,
			0.02,
			3,
			0.01,
			"One-finger release momentum decay time constant."
		),
		number(
			"PanMomentumScale",
			Config.PAN_MOMENTUM_SCALE,
			0,
			3,
			0.05,
			"Multiplier applied to one-finger release momentum."
		),
		number(
			"MinFlingPixelsPerSecond",
			Config.MIN_FLING_PX_PER_SEC,
			0,
			3000,
			10,
			"Finger speed removed as a dead zone before release momentum starts."
		),
		number(
			"MaxFlingPixelsPerSecond",
			Config.MAX_FLING_PX_PER_SEC,
			100,
			5000,
			10,
			"Maximum finger speed accepted when seeding release momentum."
		),
		number(
			"MinFlingTravelPixels",
			Config.MIN_FLING_TRAVEL_PX,
			0,
			300,
			1,
			"Minimum total drag distance required before release can create momentum."
		),
		number(
			"PanVelocitySmoothing",
			Config.PAN_VELOCITY_SMOOTHING,
			0,
			1,
			0.05,
			"Blend weight for the newest world-pan velocity sample."
		),
		number(
			"MomentumReleaseWindowSeconds",
			Config.MOMENTUM_RELEASE_WINDOW,
			0.02,
			0.5,
			0.01,
			"Maximum pause before release that still produces momentum."
		),
		number(
			"PanReferencePitchDegrees",
			Config.PAN_REFERENCE_PITCH_DEGREES,
			5,
			85,
			1,
			"Stable reference pitch used to map one-finger pixels to world travel."
		),
		number(
			"PanMaxStudsPerPixel",
			Config.PAN_MAX_STUDS_PER_PIXEL,
			0.05,
			3,
			0.05,
			"Hard cap on mobile one-finger pan and momentum distance per pixel."
		),
		number("PinchSensitivity", Config.PINCH_SENSITIVITY, 0.1, 3, 0.05, "Pinch zoom response exponent."),
		number(
			"PinchScaleLimitPerGesture",
			Config.PINCH_SCALE_LIMIT_PER_GESTURE,
			1.01,
			10,
			0.05,
			"Maximum zoom scale change accepted during one continuous pinch gesture."
		),
		number("TwistSensitivity", Config.TWIST_SENSITIVITY, 0, 3, 0.05, "Two-finger twist yaw multiplier."),
		number(
			"PitchDragSensitivity",
			Config.PITCH_DRAG_SENSITIVITY,
			0.0005,
			0.02,
			0.0005,
			"Parallel two-finger pitch radians per vertical pixel."
		),
		number(
			"PitchDeadZonePixels",
			Config.PITCH_DEAD_ZONE_PX,
			0,
			100,
			1,
			"Parallel two-finger vertical travel ignored before pitch starts."
		),
	},
}
