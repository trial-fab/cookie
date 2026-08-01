local Config = require(script.Parent.Parent.Parent:WaitForChild("HubOrbFloatConfig"))

-- Client scope: the dormant core is rendered per player (one player's activation must not move
-- another's orb), so its presentation never leaves the client.
return {
	feature = "HubOrbFloat",
	collapsedByDefault = false,
	tunables = {
		{
			key = "Enabled",
			default = Config.Enabled,
			kind = "boolean",
			scope = "client",
			description = "Levitate the dormant Ancient Core. OFF returns it to resting on the mount ring.",
		},
		{
			key = "RestLift",
			default = Config.RestLift,
			kind = "number",
			min = 0,
			max = 6,
			step = 0.05,
			scope = "client",
			description = "Studs the dormant core hovers above its authored rest, at the middle of its bob.",
		},
		{
			key = "Amplitude",
			default = Config.Amplitude,
			kind = "number",
			min = 0,
			max = 3,
			step = 0.05,
			scope = "client",
			description = "Half the distance the dormant core travels. Keep at or below RestLift or it dips into the ring.",
		},
		{
			key = "LegSeconds",
			default = Config.LegSeconds,
			kind = "number",
			min = 0.2,
			max = 12,
			step = 0.1,
			scope = "client",
			description = "Time for one leg of the bob, middle to top. Larger is slower and heavier.",
		},
	},
}
