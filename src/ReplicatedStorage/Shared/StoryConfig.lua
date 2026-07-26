local StoryConfig = {}

StoryConfig.CHAPTER_ID = "GooArrival"
StoryConfig.STEPS = {
	Meteor = "Meteor",
	Healing = "Healing",
	Lore = "Lore",
	BuildTask = "BuildTask",
	Complete = "Complete",
}

StoryConfig.HEALING_CLICKS = 5
StoryConfig.FIRST_BUILDING_ID = "Noob Clicker"

StoryConfig.Dialogue = {
	{
		Speaker = "Goob",
		Text = "Bloop? You found me! I thought I'd be stuck in that cookie meteor forever.",
	},
	{
		Speaker = "Goob",
		Text = "On my world, dough can become anything. Even something alive!",
	},
	{
		Speaker = "Goob",
		Text = "Take the Mixer. Feed it cookies, and it will shape the dough into helpers. Let's rebuild this place!",
	},
}

StoryConfig.Mascot = {
	DimSaturation = 0.12,
	DimValue = 0.48,
	ColorTweenTime = 0.28,
	RainbowCycles = 1,
	RainbowStepTime = 0.12,
	JoyPause = 0.08,
	IdleWiggleAmount = 0.055,
	IdleWiggleTime = 0.85,
}

return StoryConfig
