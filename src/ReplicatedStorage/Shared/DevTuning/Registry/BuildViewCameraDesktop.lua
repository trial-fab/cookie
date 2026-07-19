-- Granular live controls for the existing PC Build View camera. The baked values in
-- BuildViewCamera remain the defaults while Studio/client-session changes are ephemeral.
local Config = require(script.Parent.Parent.Parent:WaitForChild("BuildViewCamera"))

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
	feature = "BuildViewCameraDesktop",
	collapsedByDefault = false,
	tunables = {
		number("FieldOfView", Config.DEFAULT_FOV, 20, 100, 1, "Vertical field of view while Build View is active."),
		number("DefaultPitchDegrees", Config.PITCH_DEGREES, 5, 89, 1, "Starting downward pitch on entry."),
		number("MinPitchDegrees", Config.MIN_PITCH_DEGREES, 1, 89, 1, "Shallowest allowed downward pitch."),
		number("MaxPitchDegrees", Config.MAX_PITCH_DEGREES, 1, 89, 1, "Steepest allowed downward pitch."),
		number(
			"PlacementMarginStuds",
			Config.PLACEMENT_MARGIN_STUDS,
			0,
			500,
			1,
			"Framing and bounds margin around build surfaces."
		),
		number("EntryFrameScale", Config.ENTRY_FRAME_SCALE, 0.5, 3, 0.05, "Automatic entry distance multiplier."),
		number(
			"RoamSlackStuds",
			Config.ROAM_SLACK_STUDS,
			0,
			1000,
			1,
			"Extra horizontal travel outside the surface margin."
		),
		number(
			"CameraStandoffStuds",
			Config.CAMERA_STANDOFF_STUDS,
			0,
			1000,
			1,
			"Camera-body pull-back allowance outside surface bounds."
		),
		number("MinHeight", Config.MIN_HEIGHT, 0, 500, 1, "Minimum camera clearance above the map surface."),
		number(
			"CeilingAllowance",
			Config.CEILING_ALLOWANCE,
			1,
			3000,
			1,
			"Maximum camera height above the map surface."
		),
		number("BoundsResponseSeconds", Config.BOUNDS_TAU, 0.02, 3, 0.01, "Bounds correction time constant."),
		number("MinDistance", Config.MIN_DISTANCE, 1, 1000, 1, "Minimum automatic-entry distance from the focus."),
		number("MaxDistance", Config.MAX_DISTANCE, 16, 5000, 1, "Maximum automatic-entry distance from the focus."),
		number("WheelDollyStep", Config.WHEEL_DOLLY_STEP, 1, 300, 1, "Mouse-wheel dolly distance per notch."),
		number(
			"WheelZoomResponseSeconds",
			Config.WHEEL_ZOOM_TAU,
			0.02,
			3,
			0.01,
			"Mouse-wheel dolly decay time constant."
		),
		number("MoveSpeed", Config.MOVE_SPEED, 1, 500, 1, "Base horizontal keyboard flight speed."),
		number("VerticalSpeed", Config.VERT_SPEED, 1, 500, 1, "Base rise and descend speed."),
		number(
			"AccelRampSeconds",
			Config.ACCEL_RAMP_SECONDS,
			0.05,
			10,
			0.05,
			"Time held movement takes to reach maximum speed."
		),
		number(
			"AccelMaxMultiplier",
			Config.ACCEL_MAX_MULTIPLIER,
			0.25,
			10,
			0.05,
			"Maximum held-movement speed multiplier."
		),
		number("MovementResponseSeconds", Config.ACCEL_TAU, 0.02, 3, 0.01, "Held-movement response time constant."),
		number("MovementGlideSeconds", Config.DECEL_TAU, 0.02, 3, 0.01, "Keyboard release glide time constant."),
		number(
			"EdgePanZonePixels",
			Config.EDGE_PAN_ZONE_PX,
			0,
			400,
			1,
			"Placement distance from an edge that starts panning."
		),
		number("EdgePanSpeed", Config.EDGE_PAN_SPEED, 0, 500, 1, "Placement edge-pan base speed."),
		number(
			"KeyboardYawSpeedDegreesPerSecond",
			Config.KEYBOARD_YAW_SPEED_DEGREES,
			1,
			360,
			1,
			"Held Q/E in-place yaw speed in degrees per second."
		),
		number(
			"YawDragSensitivity",
			Config.YAW_DRAG_SENSITIVITY,
			0.0005,
			0.02,
			0.0005,
			"Right-drag yaw radians per pixel."
		),
		number(
			"PitchDragSensitivity",
			Config.PITCH_DRAG_SENSITIVITY,
			0.0005,
			0.02,
			0.0005,
			"Right-drag pitch radians per pixel."
		),
	},
}
