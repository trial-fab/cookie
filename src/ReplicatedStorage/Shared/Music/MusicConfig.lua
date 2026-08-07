-- MusicConfig -- policy numbers for the Orbit Radio engine core.
--
-- Every value here is engine policy, not catalog content: per-track loudness,
-- per-cue crossfades, pool weights, and recency exclusions live in the catalog.
-- A reusing game passes overrides to MusicConfig.new instead of forking modules.

local MusicConfig = {}

MusicConfig.defaults = table.freeze({
	-- Queue and history
	historyLimit = 20, -- previous non-story entries retained for Previous
	previousRestartSeconds = 3, -- Previous restarts the current recording past this point
	maxExplicitQueue = 100, -- live "Next in Queue" bound
	upNextPreviewCount = 5, -- generated Up Next rows

	-- Automatic selection
	defaultRecencyExclusion = 8, -- used when a pool row does not set its own
	energyPenalty = 0.35, -- weight multiplier for a large energy jump
	balancedRepeatLaneWeight = 0.4, -- Balanced: weight for repeating the previous lane
	unlockBoostMultiplier = 2.5, -- newly unlocked floor music selection boost
	unlockBoostSelections = 3, -- boosted picks before the boost expires
	unlockBoostSeconds = 600, -- boost also expires on this timer
	recoverySelections = 1, -- picks drawn from a recovery pool after a somber cue

	-- Loading and failure recovery
	loadTimeoutSeconds = 8, -- a cinematic never blocks gameplay waiting for audio
	loadRetryLimit = 1, -- retries before the fallback chain
	fallbackAttemptLimit = 2, -- alternate ambient picks before giving up silently
	quarantineFailedTracks = true, -- a failed asset is skipped for the session

	-- Mixing
	defaultCrossfadeSeconds = 2,
	maxNormalizationGainDb = 6, -- cap positive per-track normalization gain
	stingerDuckDb = 6,
	stingerDuckAttackSeconds = 0.08,
	stingerDuckReleaseSeconds = 0.5,

	-- Persistence
	resumeTtlSeconds = 6 * 60 * 60, -- rolling six-hour QueueResume window
	resumeClockSkewSeconds = 60, -- tolerated future SavedAt from a server clock
	snapshotQueueLimit = 100, -- explicit entries stored in a resume snapshot
	snapshotPositionSeconds = 30, -- minimum spacing between position-only refreshes
	maxFavorites = 500,

	-- Station lane weighting. Vibe is a bias, never a hard filter: a thin catalog
	-- must still produce a selection.
	laneWeights = table.freeze({
		StoryMix = table.freeze({ Playful = 1, Synth = 1, Crossover = 1 }),
		Playful = table.freeze({ Playful = 1, Synth = 0.15, Crossover = 0.5 }),
		SynthSpace = table.freeze({ Playful = 0.15, Synth = 1, Crossover = 0.5 }),
		Balanced = table.freeze({ Playful = 1, Synth = 1, Crossover = 0.8 }),
	}),

	-- Distance between energies, used for smoothing large jumps.
	energyRank = table.freeze({ Chill = 1, Cinematic = 2, Energetic = 3 }),
})

local function copyTable(source)
	local result = {}
	for key, value in pairs(source) do
		if type(value) == "table" then
			local inner = {}
			for innerKey, innerValue in pairs(value) do
				inner[innerKey] = innerValue
			end
			result[key] = inner
		else
			result[key] = value
		end
	end
	return result
end

-- Returns a mutable copy of the defaults with one level of overrides merged in.
function MusicConfig.new(overrides)
	local result = copyTable(MusicConfig.defaults)
	if type(overrides) ~= "table" then
		return result
	end

	for key, value in pairs(overrides) do
		if type(value) == "table" and type(result[key]) == "table" then
			for innerKey, innerValue in pairs(value) do
				result[key][innerKey] = innerValue
			end
		else
			result[key] = value
		end
	end
	return result
end

return MusicConfig
