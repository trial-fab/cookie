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

local function color(key, description)
	return {
		key = key,
		default = Config[key],
		kind = "Color3",
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
		number("MaxPitch", 0, 90, 1, "Cap on how steeply an arrow tilts toward the next one. Only bites where the ground steps up or down."),
		boolean("BridgeEnabled", "Fill the vertical run with extra arrows where the ground steps up or down."),
		number("BridgeMax", 0, 20, 1, "Most arrows any one step may spend, so a cliff cannot swallow the whole trail."),
		number("FadeSpan", 1, 40, 0.5, "Studs over which arrows fade in at the player end and out on arrival."),

		number("BobHeight", 0, 4, 0.05, "Half the vertical travel of an arrow's bob. 0 holds them still."),
		number("BobSeconds", 0.2, 6, 0.05, "Time for one full bob cycle."),
		number("WaveLength", 4, 200, 1, "Studs between bob crests. Lower values make the wave read faster."),

		-- The cascade is the primary direction signal now, so BobHeight and the ribbon pulse are
		-- both secondary to it. If the cascade reads, they can go to zero.
		boolean("CascadeEnabled", "Light the arrows in sequence as the runner reaches them."),
		number("CascadeLead", 0.5, 40, 0.5, "Studs ahead of the runner an arrow starts coming up. Short reads as a sharp attack."),
		number("CascadeTail", 0.5, 120, 0.5, "Studs behind the runner over which an arrow falls back. Long reads as a comet tail."),
		color("CascadeColor", "Colour an arrow is tinted toward at the crest of the cascade."),
		number("CascadeTint", 0, 1, 0.05, "How far an arrow's own colour travels toward CascadeColor at the crest. On a Neon arrow this is the glow ramp."),
		number("CascadeRest", 0, 1, 0.05, "Floor under the tint so arrows the runner is nowhere near still read. 0 lets the trail go dark between passes."),
		number("CascadeScale", 0, 1, 0.01, "How much an arrow grows at the crest. 0 holds it at its authored size."),
		number("CascadeLift", 0, 8, 0.1, "Studs an arrow lifts at the crest."),
		boolean("CascadeBurst", "Spark an arrow as the runner crosses it."),
		number("CascadeBurstCount", 1, 60, 1, "Particles per spark burst."),

		-- The ribbon's scroll and the arrows' bob are two competing direction signals. Expect to
		-- trade one against the other here: with the ribbon on, BobHeight usually wants to drop.
		boolean("RibbonEnabled", "Draw the continuous ground ribbon beneath the arrows."),
		number("RibbonStep", 2, 24, 0.5, "Studs between ribbon nodes. Lower hugs terrain closer at more nodes."),
		number("RibbonMaxNodes", 8, 96, 1, "Ribbon node cap. Past it the nodes spread over the whole span instead."),
		number("RibbonHover", 0, 6, 0.05, "Studs the ribbon floats above the surface. Small reads as paint, high as a second line."),
		number("RibbonRoll", -180, 180, 5, "Degrees the ribbon is rolled about the path axis. 0 lays it flat on the ground."),
		number("PulseDepth", 0, 1, 0.05, "How far the ribbon's glow pulse dims at its trough. 0 holds the ribbon at a steady brightness."),
		number("PulseSeconds", 0.2, 6, 0.05, "Time for one full pulse cycle."),
		number("PulseLength", 4, 200, 1, "Studs between pulse crests. Lower values make the wave read faster."),

		boolean("RunnerEnabled", "Fly a mote along the path from the player toward the target on a loop."),
		number("RunnerSeconds", 0.4, 10, 0.1, "Seconds for one runner pass from the player end to the target end."),
		number("RunnerGap", 0, 10, 0.1, "Seconds the runner rests between passes."),
		number("RunnerHover", 0, 12, 0.1, "Studs the runner flies above the surface."),
		number("RunnerFade", 0, 0.5, 0.01, "Fraction of a pass spent fading in at the start and out at the end."),

		boolean("BeaconEnabled", "Stand a light column over the target so it stays visible over the terraces."),
		number("BeaconHeight", 5, 300, 1, "Height of the beacon column. Tall enough to clear a terrace step from across the crater."),
		number("BeaconBase", 0, 20, 0.5, "Studs above the surface the beacon column starts."),
	},
}
