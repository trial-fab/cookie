-- Reusable, step-agnostic presentation policy registry. Stage D content selects
-- these names; Stage C fixtures may inject additional generic policies in tests.

local QuestProgressPresentationPolicies = {}
QuestProgressPresentationPolicies.__index = QuestProgressPresentationPolicies

local TIMING_PROFILES = {
	TutorialReadableBeat = { DurationSeconds = 2 },
	ConciseBeat = { DurationSeconds = 0.35 },
}

local SAFETY_TIMEOUTS = {
	Strike = 2,
	Guide = 2,
	PresentationSignal = 10,
	Reward = 10,
	Passive = 4,
}

local DEFAULT_POLICIES = {
	TutorialStrikeThenReveal = {
		Family = "Step",
		Strike = true,
		Release = { Kind = "TimingProfile", Profile = "TutorialReadableBeat" },
	},
	TutorialMixerUnlockThenReveal = {
		Family = "Step",
		Strike = true,
		Release = {
			Kind = "PresentationSignal",
			Name = "MixerUnlockPresented",
			Fallback = { Kind = "TimingProfile", Profile = "TutorialReadableBeat" },
		},
	},
	TutorialHealingThenReveal = {
		Family = "Step",
		Strike = true,
		Release = {
			Kind = "PresentationSignal",
			Name = "HealingPresentationCompleted",
			Fallback = { Kind = "TimingProfile", Profile = "TutorialReadableBeat" },
		},
	},
	TutorialImmediateReveal = {
		Family = "Step",
		Strike = false,
		Release = { Kind = "Immediate" },
	},
	StandardConcise = {
		Family = "Step",
		Strike = false,
		Release = { Kind = "Immediate" },
	},
	TutorialCompletion = {
		Family = "Quest",
		Strike = true,
		Release = { Kind = "Immediate" },
	},
	StandardCompletion = {
		Family = "Quest",
		Strike = false,
		Release = { Kind = "Immediate" },
	},
	PassiveToast = {
		Family = "Passive",
		Strike = false,
		Release = { Kind = "Immediate" },
	},
	Silent = {
		Family = "Passive",
		Strike = false,
		Release = { Kind = "Immediate" },
		Silent = true,
	},
}

local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in pairs(value) do
		result[key] = clone(child)
	end
	return result
end

local function validName(value)
	return type(value) == "string" and #value > 0 and #value <= 96 and string.match(value, "^[%w_:%-%.]+$") ~= nil
end

local function exactKeys(value, allowed, label)
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

local function validateRelease(release, timingProfiles, nested)
	local ok, problem = exactKeys(release, {
		Kind = true,
		Profile = true,
		Name = true,
		Fallback = true,
		Acknowledgement = true,
	}, "release policy")
	if not ok then
		return false, problem
	end
	if release.Kind == "Immediate" then
		return release.Profile == nil and release.Name == nil and release.Fallback == nil
			and release.Acknowledgement == nil, "Immediate has invalid fields"
	elseif release.Kind == "TimingProfile" then
		return timingProfiles[release.Profile] ~= nil and release.Name == nil and release.Fallback == nil
			and release.Acknowledgement == nil, "unknown timing profile"
	elseif release.Kind == "PresentationSignal" then
		if not validName(release.Name) or release.Profile ~= nil or release.Acknowledgement ~= nil then
			return false, "invalid presentation signal release"
		end
		if release.Fallback ~= nil then
			if nested then
				return false, "release fallback cannot nest"
			end
			local fallbackOk, fallbackProblem = validateRelease(release.Fallback, timingProfiles, true)
			if not fallbackOk or release.Fallback.Kind == "PresentationSignal"
				or release.Fallback.Kind == "ManualAcknowledge"
			then
				return false, fallbackProblem or "invalid presentation signal fallback"
			end
		end
		return true
	elseif release.Kind == "ManualAcknowledge" then
		return validName(release.Acknowledgement) and release.Profile == nil and release.Name == nil
			and release.Fallback == nil, "invalid manual acknowledgement release"
	end
	return false, "unknown release policy"
end

local function validatePolicy(policy, timingProfiles)
	local ok, problem = exactKeys(policy, {
		Family = true,
		Strike = true,
		Release = true,
		Silent = true,
	}, "presentation policy")
	if not ok then
		return false, problem
	end
	if policy.Family ~= "Step" and policy.Family ~= "Quest" and policy.Family ~= "Passive" then
		return false, "invalid presentation family"
	end
	if type(policy.Strike) ~= "boolean" or policy.Silent ~= nil and type(policy.Silent) ~= "boolean" then
		return false, "invalid presentation flags"
	end
	return validateRelease(policy.Release, timingProfiles)
end

function QuestProgressPresentationPolicies.new(config)
	config = config or {}
	local timingProfiles = clone(TIMING_PROFILES)
	for name, profile in pairs(config.TimingProfiles or {}) do
		assert(validName(name) and type(profile) == "table", "invalid fixture timing profile")
		local duration = profile.DurationSeconds
		assert(type(duration) == "number" and duration == duration and duration >= 0 and duration <= 60, "invalid timing duration")
		assert(timingProfiles[name] == nil, "duplicate timing profile")
		timingProfiles[name] = { DurationSeconds = duration }
	end
	local policies = clone(DEFAULT_POLICIES)
	for name, policy in pairs(config.Policies or {}) do
		assert(validName(name) and policies[name] == nil, "invalid or duplicate fixture policy")
		policies[name] = clone(policy)
	end
	for name, policy in pairs(policies) do
		local ok, problem = validatePolicy(policy, timingProfiles)
		assert(ok, name .. ": " .. tostring(problem))
	end
	return setmetatable({
		Policies = policies,
		TimingProfiles = timingProfiles,
		SafetyTimeouts = clone(SAFETY_TIMEOUTS),
	}, QuestProgressPresentationPolicies)
end

function QuestProgressPresentationPolicies:Get(name, family)
	local policy = self.Policies[name]
	if not policy or family and policy.Family ~= family then
		return nil
	end
	return clone(policy)
end

function QuestProgressPresentationPolicies:GetTiming(name)
	local profile = self.TimingProfiles[name]
	return profile and clone(profile) or nil
end

function QuestProgressPresentationPolicies:GetSafetyTimeout(kind)
	return self.SafetyTimeouts[kind]
end

function QuestProgressPresentationPolicies:ValidateRelease(release)
	return validateRelease(release, self.TimingProfiles)
end

function QuestProgressPresentationPolicies:IsManualReserved(release)
	return type(release) == "table" and release.Kind == "ManualAcknowledge"
end

return QuestProgressPresentationPolicies
