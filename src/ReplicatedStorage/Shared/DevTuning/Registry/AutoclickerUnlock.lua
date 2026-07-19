local AutoclickerConfig = require(script.Parent.Parent.Parent:WaitForChild("AutoclickerConfig"))

return {
	feature = "AutoclickerUnlock",
	collapsedByDefault = false,
	tunables = {
		{
			key = "Cost",
			default = AutoclickerConfig.UnlockCost,
			kind = "number",
			min = 0,
			max = 5000,
			step = 25,
			scope = "shared",
			description = "Cookie price of the one-time Autoclicker prerequisite.",
		},
	},
}
