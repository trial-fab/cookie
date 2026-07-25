local Config = require(script.Parent.Parent.Parent:WaitForChild("QuestProgressEffectsConfig"))

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

local function easing(key, description)
	return {
		key = key,
		default = Config[key],
		kind = "enum",
		options = {
			Enum.EasingStyle.Linear,
			Enum.EasingStyle.Sine,
			Enum.EasingStyle.Quad,
			Enum.EasingStyle.Cubic,
			Enum.EasingStyle.Quart,
			Enum.EasingStyle.Quint,
			Enum.EasingStyle.Exponential,
			Enum.EasingStyle.Circular,
			Enum.EasingStyle.Back,
		},
		scope = "client",
		description = description,
	}
end

return {
	feature = "QuestProgressEffects",
	collapsedByDefault = false,
	tunables = {
		boolean("EffectsEnabled", "Master switch for quest progress presentation effects."),
		boolean("PreviewProgressEnabled", "Lets the Dev Tuning progress slider drive this unfinished quest widget."),
		number("PreviewProgress", 0, 1, 0.01, "Previewed quest completion ratio."),

		number("ProgressTweenSeconds", 0.1, 3, 0.05, "Time for the ring and percentage to fill to new progress."),
		easing("ProgressTweenEasingStyle", "Timing curve used while quest progress fills."),

		boolean("SheenEnabled", "Enables one capsule highlight pass when quest progress increases."),
		boolean("SheenPreviewTrigger", "Toggle false then true to replay one highlight pass."),
		number("SheenProgressStep", 0.01, 1, 0.01, "Accumulated progress required between automatic highlight passes."),
		number("SheenSweepSeconds", 0.1, 8, 0.05, "Time for one highlight pass across completed progress."),
		number("SheenCenterX", 12, 32, 0.25, "Horizontal center of the highlight path in widget pixels."),
		number("SheenCenterY", 12, 32, 0.25, "Vertical center of the highlight path in widget pixels."),
		number("SheenRadius", 8, 28, 0.25, "Radius of the highlight path in widget pixels."),
		number("SheenStartDegrees", -360, 360, 0.5, "Angular start of the highlight path; 90 is six o'clock."),
		boolean("SheenReverse", "Reverses highlight travel across the completed arc."),
		easing("SheenEasingStyle", "Timing curve used during each highlight pass."),
		number("SheenLength", 0.5, 16, 0.25, "Capsule length in widget pixels."),
		number("SheenWidth", 0.5, 10, 0.25, "Capsule width in widget pixels."),
		number("SheenTangentOffsetDegrees", -180, 180, 0.5, "Rotation offset from the capsule's path angle."),
		number("SheenCoreWidth", 0, 0.9, 0.01, "Fraction of the capsule occupied by its bright center plateau."),
		color("SheenEdgeColor", "Color at the feathered ends of the capsule."),
		color("SheenCenterColor", "Color at the bright center of the capsule."),
		number("SheenEdgeTransparency", 0, 1, 0.01, "Transparency at the feathered ends of the capsule."),
		number("SheenCenterTransparency", 0, 1, 0.01, "Transparency at the bright center of the capsule."),

		boolean("PulseEnabled", "Enables the scale bump when progress increases."),
		number("PulseScale", 1, 1.5, 0.01, "Scale reached by an ordinary progress bump."),
		number("CompletionPulseScale", 1, 1.75, 0.01, "Scale reached when progress completes."),
		number("PulseGrowSeconds", 0.01, 1, 0.01, "Duration of the outward progress bump."),
		number("PulseSettleSeconds", 0.01, 2, 0.01, "Duration of the return to normal scale."),
		easing("PulseSettleStyle", "Easing style used while the progress bump settles."),

		boolean("BurstEnabled", "Enables the particle burst when progress reaches 100 percent."),
		number("BurstDuration", 0.05, 2, 0.01, "Duration of the completion particle burst."),
		number("BurstParticleCount", 1, 8, 1, "Number of the eight authored completion particles to use."),
		number("BurstStartDegrees", -360, 360, 1, "Angle of the first completion particle."),
		number("BurstOddDistance", 0, 40, 0.5, "Travel distance for odd completion particles."),
		number("BurstEvenDistance", 0, 40, 0.5, "Travel distance for even completion particles."),
		number("BurstOddSize", 0.5, 10, 0.25, "Size of odd completion particles."),
		number("BurstEvenSize", 0.5, 10, 0.25, "Size of even completion particles."),
		color("BurstPrimaryColor", "Color of odd completion particles."),
		color("BurstSecondaryColor", "Color of even completion particles."),
		number("BurstStartTransparency", 0, 1, 0.01, "Transparency of completion particles when emitted."),
		easing("BurstEasingStyle", "Easing style used by completion particles."),
	},
}
