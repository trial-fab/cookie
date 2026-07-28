local StoryConfig = require(script.Parent.StoryConfig)

return {
	ActivationCostCookies = 1000,
	RequiredStoryStep = StoryConfig.STEPS.Complete,
	MaxActivationDistance = 16,
	PromptHoldDuration = 0.65,
	PromptMaxDistance = 12,
}
