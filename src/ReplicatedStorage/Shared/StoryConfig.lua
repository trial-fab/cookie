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
