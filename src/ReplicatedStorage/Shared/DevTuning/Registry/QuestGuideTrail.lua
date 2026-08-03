local Config = require(script.Parent.Parent.Parent:WaitForChild("QuestGuideTrailConfig"))

-- Client scope: the trail is drawn from the local player's own feet to their own guide target,
-- so nothing about it is shared state. Layout/probe internals (probe span, cache grid, cast
-- budget) stay out of the registry -- they are implementation, not look.

local function number(key, min, max, step, description)
	return {
		key = key,
		default = Config[key],
		kind = "number",
		min = min,
		max = max,
		step = step,
		scope = "client",
		description = description,
	}
end

local function boolean(key, description)
	return {
		key = key,
		default = Config[key],
		kind = "boolean",
		scope = "client",
		description = description,
	}
end

return {
	feature = "QuestGuideTrail",
	collapsedByDefault = false,
	tunables = {
		boolean("Enabled", "Draw the world arrow trail for world-target quest guides."),

		number("Spacing", 4, 40, 0.5, "Studs between arrows. Fixed, so the count grows with distance."),
		number("MaxArrows", 4, 40, 1, "Arrow cap. Past it the trail spreads over the whole distance instead."),
		number("TailGap", 0, 40, 0.5, "Studs short of the target the closest arrow stops."),
		number("HeadGap", 0, 30, 0.5, "Closest an arrow may come to the player."),
		number("ArriveRadius", 4, 60, 0.5, "Distance from the target at which the trail fades out entirely."),

		number("Hover", 0, 12, 0.1, "Studs an arrow floats above the surface beneath it."),
		number("FadeSpan", 1, 40, 0.5, "Studs over which arrows fade in at the player end and out on arrival."),

		number("BobHeight", 0, 4, 0.05, "Half the vertical travel of an arrow's bob. 0 holds them still."),
		number("BobSeconds", 0.2, 6, 0.05, "Time for one full bob cycle."),
		number("WaveLength", 4, 200, 1, "Studs between bob crests. Lower values make the wave read faster."),
	},
}
