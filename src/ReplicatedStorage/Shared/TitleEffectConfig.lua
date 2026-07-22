-- Baked title text presentation. Each gradient describes one palette across the title; the
-- presenter circularly phases that palette when animation is enabled.
local function sequence(colors)
	local keypoints = {}
	for index, color in ipairs(colors) do
		table.insert(keypoints, ColorSequenceKeypoint.new((index - 1) / (#colors - 1), color))
	end
	return ColorSequence.new(keypoints)
end

local function effect(textColor, gradientColors, animated, duration, strokeColor, strokeTransparency)
	return {
		TextColor = textColor,
		Gradient = gradientColors and sequence(gradientColors) or nil,
		Animated = animated == true,
		Duration = duration or 4,
		StrokeColor = strokeColor or Color3.fromRGB(20, 24, 35),
		StrokeTransparency = strokeTransparency or 0.75,
	}
end

local cream = Color3.fromRGB(255, 239, 204)
local gold = Color3.fromRGB(255, 194, 72)
local orange = Color3.fromRGB(255, 124, 48)
local gooBlue = Color3.fromRGB(62, 205, 255)
local gooDeep = Color3.fromRGB(44, 116, 255)
local lime = Color3.fromRGB(111, 255, 133)
local violet = Color3.fromRGB(184, 104, 255)
local pink = Color3.fromRGB(255, 97, 190)

local TitleEffectConfig = {
	LockedTextColor = Color3.fromRGB(135, 142, 158),
	LockedStrokeColor = Color3.fromRGB(45, 49, 61),
	LockedStrokeTransparency = 0.82,
	ByTitleId = {
		FreshlyBaked = effect(cream),
		GooFriend = effect(gooBlue, { gooBlue, Color3.fromRGB(126, 241, 255) }, true, 9),
		DoughDabbler = effect(gold, { cream, gold }, true, 8.5),
		SparkSlinger = effect(gold, { gold, orange }, true, 8),
		LifeOfTheParty = effect(lime, { lime, gooBlue, pink }, true, 7.5),
		CrumbCatalyst = effect(gold, { orange, gold, gooBlue }, true, 7.25, Color3.fromRGB(81, 42, 13), 0.68),
		DoughWhisperer = effect(cream, { gold, cream, pink }, true, 7, Color3.fromRGB(72, 40, 63), 0.62),
		GooGuardian = effect(gooBlue, { gooDeep, gooBlue, lime }, true, 6.5, Color3.fromRGB(20, 48, 91), 0.58),
		Lifeweaver = effect(lime, { lime, gooBlue, violet }, true, 6, Color3.fromRGB(31, 63, 65), 0.54),
		ColonyCrafter = effect(
			gold,
			{ Color3.fromRGB(184, 101, 45), gold, cream },
			true,
			5.5,
			Color3.fromRGB(80, 47, 22),
			0.5
		),
		TheBigRiser = effect(gold, { pink, orange, gold }, true, 5, Color3.fromRGB(83, 38, 38), 0.46),
		Worldbaker = effect(
			gooBlue,
			{ Color3.fromRGB(32, 123, 255), lime, gold },
			true,
			4.8,
			Color3.fromRGB(22, 50, 72),
			0.42
		),
		PlanetProofer = effect(
			violet,
			{ violet, gooBlue, Color3.fromRGB(67, 92, 255) },
			true,
			4.5,
			Color3.fromRGB(39, 31, 88),
			0.38
		),
		GenesisChef = effect(Color3.new(1, 1, 1), {
			Color3.fromRGB(30, 30, 255),
			Color3.fromRGB(255, 160, 0),
		}, true, 4, Color3.fromRGB(31, 28, 96), 0.3),
		MakerOfMakers = effect(Color3.new(1, 1, 1), {
			Color3.fromRGB(255, 70, 70),
			Color3.fromRGB(255, 155, 45),
			Color3.fromRGB(255, 235, 70),
			Color3.fromRGB(70, 225, 120),
			Color3.fromRGB(60, 130, 255),
			Color3.fromRGB(178, 76, 255),
			Color3.fromRGB(255, 70, 70),
		}, true, 3.5, Color3.fromRGB(54, 29, 75), 0.2),
	},
}

return TitleEffectConfig
