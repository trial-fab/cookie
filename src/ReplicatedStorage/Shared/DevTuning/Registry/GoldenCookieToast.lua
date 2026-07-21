local GOLD = Color3.fromRGB(227, 178, 0)

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

local function color(key, default, description)
	return {
		key = key,
		default = default,
		kind = "Color3",
		scope = "client",
		description = description,
	}
end

return {
	feature = "GoldenCookieToast",
	collapsedByDefault = false,
	tunables = {
		number("HoldSeconds", 0.45, 0, 3, 0.05, "Delay before the earned-GC toast begins fading."),
		number("RiseSeconds", 1.4, 0.1, 5, 0.05, "Duration of the toast's upward movement."),
		number("FadeSeconds", 0.95, 0.1, 5, 0.05, "Duration of the toast fade after its hold."),
		number(
			"RiseDistanceScale",
			-0.06,
			-0.25,
			0.25,
			0.005,
			"Vertical screen-scale travel; negative values move upward."
		),
		number(
			"HorizontalJitterScale",
			0.04,
			0,
			0.15,
			0.005,
			"Maximum random horizontal screen-scale offset for overlapping earns."
		),
		{
			key = "TextFormat",
			default = "+{amount} GC",
			kind = "string",
			maxLength = 64,
			scope = "client",
			description = "Toast label format; {amount} is replaced by the abbreviated earned amount.",
		},
		number("TextSize", 16, 8, 48, 1, "Toast label text size."),
		color("TextColor", GOLD, "Toast label color."),
		number("TextStrokeThickness", 2, 0, 6, 0.25, "Outline thickness around the toast label."),
		color("TextStrokeColor", Color3.fromRGB(0, 0, 0), "Outline color around the toast label."),
		{
			key = "ShowIcon",
			default = true,
			kind = "boolean",
			scope = "client",
			description = "Whether the golden-cookie icon is shown beside the amount.",
		},
		number("IconSize", 24, 8, 64, 1, "Width and height of the golden-cookie icon in pixels."),
		color("IconColor", GOLD, "Golden-cookie icon tint."),
		{
			key = "PreviewEnabled",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Show a local example now and after each toast-control change while enabled.",
		},
		number("PreviewAmount", 1, 1, 1000000000, 1, "Earned amount displayed by the local preview toast."),
	},
}
