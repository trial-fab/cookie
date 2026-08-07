--!strict
-- MusicCatalog.generated.lua
--
-- GENERATED FILE - DO NOT EDIT BY HAND.
-- Source of truth: the CSV catalog under music/ (see docs/music.md).
-- Regenerate with:
--   python3 tools/compile_music_catalog.py --mode development
--
-- Runtime fields only. Local paths, hashes, license evidence, archive names, and
-- production notes stay in the CSVs.

return {
	formatVersion = 1,
	mode = "development",
	experienceId = "FX_GAME",
	inputDigest = "3052f52f67c7950c4bc851e834862ffceca76bf5f4247cbc4e701c348d420174",
	credits = {
		{
			sourceId = "FIXTURE_APPROVED",
			provider = "Fixture Studios",
			packTitle = "Fixture Loop Pack",
			artist = "Fixture Composer",
			licenseId = "CC0-1.0",
			credit = "Music by Fixture Composer",
		},
	},
	collections = {
		{
			id = "FX_STORY",
			displayName = "Fixture Story",
			nameKey = "Music.Collection.FX_STORY.Name",
			unlockRule = "StoryEncounter",
			unlockCopyKey = "Music.Collection.FX_STORY.Unlock",
			trackIds = {
				"FX_STORY_ONE",
			},
		},
		{
			id = "FX_UNIVERSAL",
			displayName = "Fixture Universal",
			nameKey = "Music.Collection.FX_UNIVERSAL.Name",
			unlockRule = "Always",
			unlockCopyKey = "Music.Collection.FX_UNIVERSAL.Unlock",
			artworkAssetId = 200000001,
			trackIds = {
				"FX_AMBIENT_TWO",
				"FX_AMBIENT_ONE",
			},
		},
	},
	tracks = {
		{
			id = "FX_AMBIENT_ONE",
			title = "Quiet Orbit",
			titleKey = "Music.Track.FX_AMBIENT_ONE.Title",
			artist = "Fixture Composer",
			sourceId = "FIXTURE_APPROVED",
			collectionId = "FX_UNIVERSAL",
			audienceLane = "Playful",
			energy = "Chill",
			dialogueSafe = true,
			loopQuality = "Good",
			storyLocked = false,
			favoriteEnabled = true,
			assetId = 100000001,
			durationSeconds = 40,
			normalizedVolumeDb = -1.5,
			playbackStartSeconds = 0,
			playbackEndSeconds = 40,
		},
		{
			id = "FX_AMBIENT_TWO",
			title = "Bright Vector",
			titleKey = "Music.Track.FX_AMBIENT_TWO.Title",
			artist = "Fixture Composer",
			sourceId = "FIXTURE_APPROVED",
			collectionId = "FX_UNIVERSAL",
			audienceLane = "Synth",
			energy = "Energetic",
			dialogueSafe = true,
			loopQuality = "Good",
			storyLocked = false,
			favoriteEnabled = true,
			assetId = 100000002,
			durationSeconds = 40,
			normalizedVolumeDb = 0.5,
			playbackStartSeconds = 1,
			playbackEndSeconds = 39,
			loopStartSeconds = 2,
			loopEndSeconds = 38,
		},
		{
			id = "FX_STORY_ONE",
			title = "First Light",
			titleKey = "Music.Track.FX_STORY_ONE.Title",
			artist = "Fixture Composer",
			sourceId = "FIXTURE_APPROVED",
			collectionId = "FX_STORY",
			audienceLane = "Crossover",
			energy = "Cinematic",
			dialogueSafe = true,
			loopQuality = "Acceptable",
			storyLocked = true,
			favoriteEnabled = true,
			assetId = 100000003,
			durationSeconds = 60,
			normalizedVolumeDb = -2,
			playbackStartSeconds = 0,
			playbackEndSeconds = 60,
		},
	},
	trackIndex = {
		FX_AMBIENT_ONE = 1,
		FX_AMBIENT_TWO = 2,
		FX_STORY_ONE = 3,
	},
	pools = {
		{
			id = "FX_AMBIENT",
			displayName = "Fixture Ambient",
			unlockRule = "Always",
			targetCount = 2,
			selectionPolicy = "ShuffledBag",
			entries = {
				{
					trackId = "FX_AMBIENT_ONE",
					weight = 1,
					recencyExclusion = 4,
				},
				{
					trackId = "FX_AMBIENT_TWO",
					weight = 0.5,
					recencyExclusion = 4,
					minimumProgression = 2,
				},
			},
		},
		{
			id = "FX_RECOVERY",
			displayName = "Fixture Recovery",
			unlockRule = "ContextualOnly",
			targetCount = 1,
			selectionPolicy = "WeightedContextual",
			entries = {
				{
					trackId = "FX_AMBIENT_ONE",
					weight = 1,
					recencyExclusion = 2,
				},
			},
		},
	},
	cues = {
		{
			id = "FX_INTRO",
			cueClass = "Cinematic",
			priority = 100,
			loopMode = "Loop",
			crossfadeSeconds = 2.5,
			fallbackPoolId = "FX_AMBIENT",
			storyMomentsControlled = true,
			assignments = {
				{
					trackId = "FX_STORY_ONE",
					role = "Primary",
					sequenceOrder = 1,
					startOffsetSeconds = 0,
					endBehavior = "Advance",
				},
				{
					trackId = "FX_AMBIENT_TWO",
					role = "Continuation",
					sequenceOrder = 2,
					startOffsetSeconds = 0,
					endBehavior = "Release",
				},
				{
					trackId = "FX_AMBIENT_ONE",
					role = "Fallback",
					sequenceOrder = 1,
					startOffsetSeconds = 0,
					endBehavior = "Release",
				},
			},
		},
		{
			id = "FX_STINGER",
			cueClass = "Stinger",
			priority = 30,
			loopMode = "NoLoop",
			crossfadeSeconds = 0.2,
			fallbackPoolId = "FX_AMBIENT",
			storyMomentsControlled = false,
			assignments = {
				{
					trackId = "FX_AMBIENT_ONE",
					role = "Primary",
					sequenceOrder = 1,
					startOffsetSeconds = 5,
					endBehavior = "CueDefault",
				},
			},
		},
	},
}
