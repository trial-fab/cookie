-- Provisional placement-grid palette and emphasis tuning. Kept separate from
-- VerticalFloors so visual iteration does not share a dropdown with reveal motion.
local FloorConfig = require(script.Parent.Parent.Parent:WaitForChild("FloorConfig"))
local GRID_DEFAULTS = FloorConfig.Grid

return {
	feature = "FloorGrids",
	collapsedByDefault = false,
	tunables = {
		{
			key = "GroundColor",
			default = GRID_DEFAULTS.Colors.Ground,
			kind = "Color3",
			scope = "client",
			description = "Placement-grid color on the Ground floor.",
		},
		{
			key = "IndustryColor",
			default = GRID_DEFAULTS.Colors.Floor1,
			kind = "Color3",
			scope = "client",
			description = "Bright-orange placement grid over the brown Industry floor.",
		},
		{
			key = "FinanceColor",
			default = GRID_DEFAULTS.Colors.Floor2,
			kind = "Color3",
			scope = "client",
			description = "Yellow-gold placement grid over the blue Finance and Distribution floor.",
		},
		{
			key = "ScienceColor",
			default = GRID_DEFAULTS.Colors.Floor3,
			kind = "Color3",
			scope = "client",
			description = "Dark-purple placement grid over the white Science floor.",
		},
		{
			key = "ActiveTransparency",
			default = GRID_DEFAULTS.ActiveTransparency,
			kind = "number",
			min = 0,
			max = 1,
			step = 0.05,
			scope = "client",
			description = "Line transparency for the placement floor currently under direct aim.",
		},
		{
			key = "InactiveTransparency",
			default = GRID_DEFAULTS.InactiveTransparency,
			kind = "number",
			min = 0,
			max = 1,
			step = 0.05,
			scope = "client",
			description = "Line transparency for other unlocked placement floors.",
		},
	},
}
