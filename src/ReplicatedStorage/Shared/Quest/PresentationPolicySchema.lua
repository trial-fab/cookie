-- Shared validation for inert presentation declarations. Client choreography owns
-- the matching reusable policy implementations; content never embeds timing code.

local GuideRegistry = require(script.Parent.Guides.Registry)
local CompletionActionRegistry = require(script.Parent.CompletionActionRegistry)

local PresentationPolicySchema = {}

local STEP_POLICIES = {
	TutorialStrikeThenReveal = true,
	TutorialMixerUnlockThenReveal = true,
	TutorialHealingThenReveal = true,
	TutorialImmediateReveal = true,
	StandardConcise = true,
}

local QUEST_POLICIES = {
	TutorialCompletion = true,
	StandardCompletion = true,
}

local PASSIVE_POLICIES = {
	TrackedOnly = true,
	PassiveToast = true,
	Silent = true,
}

local function checkKeys(value, allowed, label)
	if type(value) ~= "table" then
		return false, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, label .. " has unknown field " .. tostring(key)
		end
	end
	return true
end

local function shortString(value)
	return type(value) == "string" and #value > 0 and #value <= 96
end

function PresentationPolicySchema.Validate(value)
	if value == nil then
		return true
	end
	local ok, problem = checkKeys(value, {
		StepCompletion = true,
		QuestCompletion = true,
		Passive = true,
		Guide = true,
		Milestones = true,
		CompletionAction = true,
	}, "presentation")
	if not ok then
		return false, problem
	end
	if value.StepCompletion ~= nil and not STEP_POLICIES[value.StepCompletion] then
		return false, "unknown step completion policy"
	end
	if value.QuestCompletion ~= nil and not QUEST_POLICIES[value.QuestCompletion] then
		return false, "unknown quest completion policy"
	end
	if value.Passive ~= nil and not PASSIVE_POLICIES[value.Passive] then
		return false, "unknown passive policy"
	end
	if value.Guide ~= nil then
		ok, problem = GuideRegistry.Validate(value.Guide)
		if not ok then return false, problem end
	end
	if value.CompletionAction ~= nil then
		ok, problem = CompletionActionRegistry.Validate(value.CompletionAction)
		if not ok then return false, problem end
	end
	if value.Milestones ~= nil then
		if type(value.Milestones) ~= "table" or #value.Milestones > 16 then
			return false, "milestones must be a bounded array"
		end
		local seen = {}
		for _, milestone in ipairs(value.Milestones) do
			ok, problem = checkKeys(milestone, { Phase = true, Policy = true }, "milestone")
			if not ok then return false, problem end
			if not shortString(milestone.Phase) or seen[milestone.Phase] then
				return false, "invalid or duplicate milestone phase"
			end
			if not STEP_POLICIES[milestone.Policy] then
				return false, "unknown milestone policy"
			end
			seen[milestone.Phase] = true
		end
	end
	return true
end

function PresentationPolicySchema.IsStepPolicy(value)
	return STEP_POLICIES[value] == true
end

function PresentationPolicySchema.IsQuestPolicy(value)
	return QUEST_POLICIES[value] == true
end

return table.freeze(PresentationPolicySchema)
