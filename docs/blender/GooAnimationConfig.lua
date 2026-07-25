local GooAnimationConfig = {}

-- Runtime deliberately does not depend on deformation-bone names. Replacement
-- rigs may add or reorganize controls as long as every skin and every uploaded
-- animation uses the same final skeleton.
GooAnimationConfig.MinimumBoneCount = 1

GooAnimationConfig.Playback = {
	BaseFadeTime = 0.16,
	ActionFadeTime = 0.10,
	HealingColorTweenTime = 0.28,
	RevealPulseAmount = 0.10,
	ClickPulseAmount = 0.07,
	PulseRiseTime = 0.11,
	PulseSettleTime = 0.18,
}

GooAnimationConfig.Definitions = {
	Idle = {
		AssetId = "rbxassetid://115214814596597",
		Looped = true,
		Priority = Enum.AnimationPriority.Idle,
		FallbackDuration = 71 / 30,
	},
	Dizzy = {
		AssetId = "rbxassetid://96359965879591",
		Looped = true,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 95 / 30,
	},
	DizzyCompressed = {
		AssetId = "rbxassetid://75866000611681",
		Looped = true,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 95 / 30,
	},
	Hop = {
		AssetId = "rbxassetid://75133297765876",
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 71 / 30,
		-- World translation occurs only between authored takeoff and contact.
		-- Fractions survive frame-rate or duration changes in the replacement clip.
		TravelStartNormalized = 17 / 71,
		TravelEndNormalized = 51 / 71,
		TurnToTravelDuration = 0.30,
		TurnToIdleDuration = 0.35,
	},
	Joy = {
		AssetId = "rbxassetid://129862884177776",
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 113 / 30,
	},
	Recover = {
		AssetId = "rbxassetid://133164210457488",
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 53 / 30,
		EffectClearNormalized = 23 / 53,
	},
	Showcase = {
		AssetId = "rbxassetid://132060364376918",
		Looped = false,
		Priority = Enum.AnimationPriority.Action,
		FallbackDuration = 71 / 30,
	},
}

function GooAnimationConfig.Validate()
	local errors = {}
	local requiredActions = { "Idle", "Dizzy", "DizzyCompressed", "Hop", "Joy", "Recover" }
	for _, name in ipairs(requiredActions) do
		local definition = GooAnimationConfig.Definitions[name]
		if not definition then
			table.insert(errors, ("missing required animation definition %s"):format(name))
		elseif type(definition.AssetId) ~= "string" or not definition.AssetId:match("^rbxassetid://%d+$") then
			table.insert(errors, ("%s has an invalid AssetId"):format(name))
		elseif type(definition.FallbackDuration) ~= "number" or definition.FallbackDuration <= 0 then
			table.insert(errors, ("%s has an invalid FallbackDuration"):format(name))
		end
	end

	local hop = GooAnimationConfig.Definitions.Hop
	if
		hop
		and not (
			type(hop.TravelStartNormalized) == "number"
			and type(hop.TravelEndNormalized) == "number"
			and hop.TravelStartNormalized >= 0
			and hop.TravelStartNormalized < hop.TravelEndNormalized
			and hop.TravelEndNormalized <= 1
		)
	then
		table.insert(errors, "Hop has an invalid normalized travel window")
	end
	if
		hop
		and not (
			type(hop.TurnToTravelDuration) == "number"
			and hop.TurnToTravelDuration >= 0
			and type(hop.TurnToIdleDuration) == "number"
			and hop.TurnToIdleDuration >= 0
		)
	then
		table.insert(errors, "Hop has invalid turn durations")
	end

	local recover = GooAnimationConfig.Definitions.Recover
	if
		recover
		and not (
			type(recover.EffectClearNormalized) == "number"
			and recover.EffectClearNormalized >= 0
			and recover.EffectClearNormalized <= 1
		)
	then
		table.insert(errors, "Recover has an invalid normalized effect-clear time")
	end

	if
		GooAnimationConfig.Definitions.Dizzy
		and GooAnimationConfig.Definitions.DizzyCompressed
		and GooAnimationConfig.Definitions.Dizzy.FallbackDuration
			~= GooAnimationConfig.Definitions.DizzyCompressed.FallbackDuration
	then
		table.insert(errors, "Dizzy and DizzyCompressed must have identical durations")
	end

	return errors
end

return GooAnimationConfig
