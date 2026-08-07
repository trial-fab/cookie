-- MusicTypes -- shared vocabulary for the Orbit Radio music engine.
--
-- Runtime tokens only. Nothing here knows about Roblox instances, ClickGame
-- progression, or asset ids, so another experience reuses this file unchanged.
-- The catalog compiler emits these same one-word tokens (see docs/music.md).

local MusicTypes = {}

local function enum(values)
	local result = {}
	for _, value in ipairs(values) do
		result[value] = value
	end
	return table.freeze(result)
end

-- Director states. Exactly one is active at a time.
--   Stopped  no playable selection, explicit stop, or boot
--   Loading  a requested recording is being prepared (the previous one may still be audible)
--   Ambient  contextual shuffled-bag selection
--   Manual   direct selection, queue, or Repeat One
--   Story    cinematic or major-milestone cue
MusicTypes.State = enum({ "Stopped", "Loading", "Ambient", "Manual", "Story" })

-- Who owns the audible recording. Stingers never become a state or a source.
MusicTypes.Source = enum({ "Ambient", "Manual", "Story" })

MusicTypes.Channel = enum({ "Main", "Stinger" })

-- Where automatic selection draws from.
MusicTypes.SourceKind = enum({ "Station", "Collection", "Pool" })

-- Catalog tokens (mirrors of the compiler's controlled vocabularies).
MusicTypes.CueClass = enum({ "Cinematic", "MajorMilestone", "Stinger" })
MusicTypes.LoopMode = enum({ "Loop", "NoLoop", "LoopIfNeeded" })
MusicTypes.EndBehavior = enum({ "CueDefault", "Advance", "Release" })
MusicTypes.AssignmentRole = enum({ "Primary", "Continuation", "Fallback" })
MusicTypes.AudienceLane = enum({ "Playful", "Synth", "Crossover" })
MusicTypes.Energy = enum({ "Chill", "Energetic", "Cinematic" })
MusicTypes.UnlockRule = enum({
	"Always",
	"IndustryFloor",
	"CommerceFloor",
	"ScienceFloor",
	"StoryEncounter",
	"ContextualOnly",
	"NotBrowsable",
})
MusicTypes.SelectionPolicy = enum({ "ShuffledBag", "ShuffledBagWithUnlockBoost", "WeightedContextual" })

-- Saved player preferences.
MusicTypes.RepeatMode = enum({ "Off", "All", "One" })
MusicTypes.Vibe = enum({ "StoryMix", "Playful", "SynthSpace", "Balanced" })

-- requestCue outcomes.
--   Started      the cue owns playback now
--   Retained     held until hydration finishes; starts only while the request stays active
--   Duplicate    same requestId delivered again; no second effect
--   Suppressed   lower or equal priority than the active presentation
--   Acknowledged the moment counts, but Story Moments is off so playback did not change
--   NoRecording  the cue exists with no approved recording in this catalog build
--   UnknownCue   no such cue id
MusicTypes.CueResult = enum({
	"Started",
	"Retained",
	"Duplicate",
	"Suppressed",
	"Acknowledged",
	"NoRecording",
	"UnknownCue",
})

MusicTypes.ReleaseReason = enum({ "Completed", "Skipped", "Replaced", "SceneEnded", "Cancelled", "Failed" })

-- Which release reasons mean the presentation actually reached its end. Only these
-- record a story encounter and reveal the scene's recording; a cancelled, replaced,
-- failed, or wholly skipped scene never happened for the player. A scene owner that
-- fast-forwards but still commits its story beat releases with SceneEnded, not
-- Skipped: Skipped means the player left the moment behind.
MusicTypes.CompletionReason = table.freeze({
	[MusicTypes.ReleaseReason.Completed] = true,
	[MusicTypes.ReleaseReason.SceneEnded] = true,
})

function MusicTypes.isCompletionReason(reason)
	return MusicTypes.CompletionReason[reason] == true
end

-- What the single player-facing transport button does right now.
MusicTypes.TransportAction = enum({ "Play", "Pause", "Resume", "SkipStory" })

-- Player command outcomes.
MusicTypes.CommandResult = enum({
	"Accepted",
	"Rejected",
	"StoryActive",
	"QueueFull",
	"NotPlayable",
	"Unavailable",
})

-- Bounded, non-content-sensitive engine diagnostics.
MusicTypes.Diagnostic = enum({
	"UnknownCue",
	"CueSuppressed",
	"CueReplaced",
	"CueWithoutRecording",
	"LoadFailed",
	"LoadTimeout",
	"FallbackUsed",
	"TrackQuarantined",
	"NoEligibleTrack",
	"StaleCallback",
	"ResumeRejected",
	"ResumeRestored",
	"QueueFull",
})

return table.freeze(MusicTypes)
