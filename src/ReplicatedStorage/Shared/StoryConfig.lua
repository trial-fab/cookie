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
StoryConfig.FIRST_BUILDING_COST = 15
StoryConfig.TOOL_NAME = "Mixer"

StoryConfig.Dialogue = {
	{
		Speaker = "Goo Alien",
		Text = "...Bloop? You found me. I thought that cookie meteor was going to be my new home forever.",
	},
	{
		Speaker = "Goo Alien",
		Text = "I come from a world where dough can become anything—even something alive.",
	},
	{
		Speaker = "Goo Alien",
		Text = "Take the Mixer. Feed it cookies, shape the cosmic dough, and we can build this place back up.",
	},
}

StoryConfig.Prompts = {
	[StoryConfig.STEPS.Healing] = "Click your cookie to help the goo alien recover! (%d/%d)",
	[StoryConfig.STEPS.BuildTask] = "Collect %d cookies, open the Mixer, and place a Noob Clicker.",
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
