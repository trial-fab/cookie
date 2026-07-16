-- DELETABLE EXAMPLE: remove this registry module before the DevTuning release gate.
-- It exists only to prove registry discovery, generated controls, and live replication.

return {
	feature = "_Example",
	tunables = {
		{
			key = "EasingStyle",
			default = Enum.EasingStyle.Quad,
			kind = "enum",
			options = {
				Enum.EasingStyle.Linear,
				Enum.EasingStyle.Quad,
				Enum.EasingStyle.Back,
			},
			scope = "client",
			description = "Example enum used to verify the generated selector.",
		},
		{
			key = "PulseSeconds",
			default = 1,
			kind = "number",
			min = 0.1,
			max = 5,
			step = 0.1,
			scope = "shared",
			description = "Example duration used to verify clamping and step quantization.",
		},
		{
			key = "ShowBounds",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Example toggle used to verify boolean live updates.",
		},
	},
}
