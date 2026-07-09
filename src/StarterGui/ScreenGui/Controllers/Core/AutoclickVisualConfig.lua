-- Autoclick mouse visual tuning.
-- Change these values, save, and restart Play mode to preview the result.
return {
	-- Seconds required for one complete orbit. Lower values move faster.
	RevolutionSeconds = 12,

	-- Distance from the center of the SurfaceGui, where 0.5 reaches its edge.
	OrbitRadiusScale = 0.38,

	-- Width and height of each mouse in SurfaceGui pixels.
	IconSizePixels = 36,

	-- Rotates the cursor artwork relative to its direction around the orbit.
	RotationOffsetDegrees = 270,

	-- Use 1 for clockwise or -1 for counterclockwise movement.
	OrbitDirection = 1,

	-- Rotates the starting arrangement of all mice around the cookie.
	StartAngleDegrees = 0,

	-- Radius reached when a mouse presses toward the cookie.
	ClickRadiusScale = 0.32,

	-- Seconds spent moving from the normal orbit to the cookie.
	ClickTravelSeconds = 0.4,

	-- Optional pause at the cookie before the return begins.
	ClickHoldSeconds = 0.08,

	-- Seconds spent moving back to the normal orbit.
	ClickReturnSeconds = 0.8,
}
