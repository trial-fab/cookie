--!nocheck
-- Deterministic tests for ClickGame's Persistent.Music adapter.
--
-- MusicService is a Roblox shell; every decision it makes lives in
-- Shared/OrbitRadio/OrbitRadioProfile, which is pure. That is what makes the exit
-- gate for this stage checkable without Studio: fresh, old, malformed, expired, and
-- rebirthed profiles all reconcile safely, and every client message is validated,
-- bounded, and revalidated before it can touch a saved field.

local cache = {}
local function node(path)
	return setmetatable({ Path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return node(string.match(path, "^(.*)%.[^.]+$") or "")
			end
			return node(path == "" and key or path .. "." .. key)
		end,
	})
end

-- FloorConfig carries authored Color3/Enum presentation values. Orbit Radio reads
-- only ids, orders, and prices from it, so a shim is enough to load it here.
local RobloxShims = {
	Color3 = { fromRGB = function() return {} end },
	Enum = setmetatable({}, {
		__index = function()
			return setmetatable({}, { __index = function(_, key) return key end })
		end,
	}),
}

local function loadModule(name)
	if cache[name] then
		return cache[name]
	end
	local chunk = assert(loadstring(assert(SOURCES[name], "missing source " .. name)))
	local env
	env = setmetatable({
		script = node(name),
		require = function(target)
			return loadModule(assert(SOURCES[target.Path] and target.Path, "unknown module " .. tostring(target.Path)))
		end,
		warn = function() end,
	}, {
		__index = function(_, key)
			if RobloxShims[key] ~= nil then
				return RobloxShims[key]
			end
			return getfenv()[key]
		end,
	})
	setfenv(chunk, env)
	local result = chunk()
	cache[name] = result
	return result
end

local MusicTypes = loadModule("Music.MusicTypes")
local MusicConfig = loadModule("Music.MusicConfig")
local MusicCatalog = loadModule("Music.MusicCatalog")
local MusicUnlocks = loadModule("Music.MusicUnlocks")
local MusicPersistence = loadModule("Music.MusicPersistence")
local OrbitRadioConfig = loadModule("OrbitRadio.OrbitRadioConfig")
local OrbitRadioProfile = loadModule("OrbitRadio.OrbitRadioProfile")

local failures = 0
local function check(label, condition, detail)
	if condition then
		print("  ok   " .. label)
	else
		failures += 1
		print(("  FAIL %s%s"):format(label, detail and " -- " .. tostring(detail) or ""))
	end
end

local function section(name)
	print(name)
end

local function concat(list)
	local parts = {}
	for _, value in ipairs(list or {}) do
		table.insert(parts, tostring(value))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function contains(list, value)
	for _, entry in ipairs(list or {}) do
		if entry == value then
			return true
		end
	end
	return false
end

local function sameList(list, expected)
	if #list ~= #expected then
		return false
	end
	for index, value in ipairs(expected) do
		if list[index] ~= value then
			return false
		end
	end
	return true
end

local function hasRepair(repairs, label)
	return contains(repairs, label)
end

--[[ Fixture catalog: real ClickGame collection ids, tiny track set ]]

local function track(id, collectionId, options)
	options = options or {}
	-- Not `options.noAsset and nil or 100000`: that and-or always yields the number.
	local assetId = 100000
	if options.noAsset then
		assetId = nil
	end
	return {
		id = id,
		title = id,
		titleKey = "Music.Track." .. id .. ".Title",
		artist = "Fixture Composer",
		sourceId = "FIXTURE",
		collectionId = collectionId,
		audienceLane = "Crossover",
		energy = "Chill",
		dialogueSafe = true,
		loopQuality = "Good",
		storyLocked = options.storyLocked == true,
		favoriteEnabled = options.favoriteEnabled ~= false,
		assetId = assetId,
		durationSeconds = options.duration or 100,
		normalizedVolumeDb = -1,
		playbackStartSeconds = options.playbackStart or 0,
		playbackEndSeconds = options.playbackEnd or options.duration or 100,
	}
end

local function collection(id, unlockRule, trackIds)
	return {
		id = id,
		displayName = id,
		nameKey = "Music.Collection." .. id .. ".Name",
		unlockRule = unlockRule,
		unlockCopyKey = "Music.Collection." .. id .. ".Unlock",
		trackIds = trackIds,
	}
end

local catalog = MusicCatalog.new({
	formatVersion = 1,
	mode = "strict",
	experienceId = "CLICKGAME",
	inputDigest = "fixture",
	credits = {},
	collections = {
		collection("UNIVERSAL", "Always", { "U_ONE", "U_TWO", "NO_ASSET", "NO_FAV" }),
		collection("INDUSTRY", "IndustryFloor", { "I_ONE" }),
		collection("COMMERCE", "CommerceFloor", { "C_ONE" }),
		collection("STORY", "StoryEncounter", { "S_GOO" }),
	},
	tracks = {
		track("U_ONE", "UNIVERSAL"),
		track("U_TWO", "UNIVERSAL", { playbackStart = 5, playbackEnd = 65 }),
		track("NO_ASSET", "UNIVERSAL", { noAsset = true }),
		track("NO_FAV", "UNIVERSAL", { favoriteEnabled = false }),
		track("I_ONE", "INDUSTRY"),
		track("C_ONE", "COMMERCE"),
		track("S_GOO", "STORY", { storyLocked = true }),
	},
	trackIndex = {},
	pools = {
		{
			id = "UNIVERSAL",
			displayName = "Universal",
			unlockRule = "Always",
			targetCount = 8,
			selectionPolicy = "ShuffledBag",
			entries = { { trackId = "U_ONE", weight = 1, recencyExclusion = 2 } },
		},
		{
			id = "INDUSTRY",
			displayName = "Industry",
			unlockRule = "IndustryFloor",
			targetCount = 8,
			selectionPolicy = "ShuffledBagWithUnlockBoost",
			entries = { { trackId = "I_ONE", weight = 1, recencyExclusion = 2 } },
		},
	},
	cues = {
		{
			id = "GOO_REVEAL",
			cueClass = "Cinematic",
			priority = 100,
			loopMode = "NoLoop",
			crossfadeSeconds = 2,
			fallbackPoolId = "UNIVERSAL",
			storyMomentsControlled = true,
			assignments = {
				{ trackId = "S_GOO", role = "Primary", sequenceOrder = 1, startOffsetSeconds = 0, endBehavior = "CueDefault" },
			},
		},
		{
			id = "FLOOR_INDUSTRY_UNLOCK",
			cueClass = "MajorMilestone",
			priority = 80,
			loopMode = "NoLoop",
			crossfadeSeconds = 1.5,
			fallbackPoolId = "INDUSTRY",
			storyMomentsControlled = true,
			assignments = {},
		},
	},
})

local config = MusicConfig.new()
local NOW = 1_800_000_000

local function unlocksFor(stored, floorCount)
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext({
		grants = OrbitRadioProfile.grantsForFloorCount(floorCount),
		progression = floorCount,
		encounteredCueIds = stored.EncounteredCueIds,
		unlockedCollectionIds = stored.UnlockedCollectionIds,
	})
	return unlocks
end

local function facts(overrides)
	local result = {
		IntroSeen = false,
		StoryStep = "Meteor",
		MixerUnlocked = false,
		HubCoreActivated = false,
		IsArcCompleted = function()
			return false
		end,
	}
	for key, value in pairs(overrides or {}) do
		result[key] = value
	end
	return result
end

--[[ Fresh profiles ]]

section("fresh profile")
do
	local stored, repairs = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	local defaults = MusicPersistence.defaults()
	check("nil music reconciles to the engine defaults", stored.Preferences.Volume == defaults.Preferences.Volume
		and stored.Preferences.Vibe == MusicTypes.Vibe.StoryMix
		and stored.Preferences.StoryMomentsEnabled == true
		and stored.Preferences.ShuffleEnabled == true
		and stored.Preferences.RepeatMode == MusicTypes.RepeatMode.Off)
	check("a fresh profile reports no repairs", #repairs == 0, concat(repairs))
	check("a fresh profile has empty library sets", #stored.FavoriteTrackIds == 0
		and #stored.EncounteredCueIds == 0
		and #stored.UnlockedCollectionIds == 0)
	check("a fresh profile has no resume snapshot", stored.QueueResume == nil)
end

--[[ Old profiles ]]

section("old profile")
do
	-- A save written before Orbit Radio existed: the field is simply absent.
	local stored, repairs = OrbitRadioProfile.normalizeStored({}, NOW, config)
	check("an absent domain fills without complaint", #repairs == 0 and stored.Preferences.Volume == 1)

	-- A partially written domain keeps what it had and fills the rest.
	local partial = OrbitRadioProfile.normalizeStored({
		Preferences = { Volume = 0.4, RepeatMode = "One" },
		FavoriteTrackIds = { "U_ONE" },
	}, NOW, config)
	check("saved preference values survive", partial.Preferences.Volume == 0.4
		and partial.Preferences.RepeatMode == "One")
	check("missing preference fields take defaults", partial.Preferences.Vibe == MusicTypes.Vibe.StoryMix
		and partial.Preferences.ShuffleEnabled == true)
	check("saved favorites survive", sameList(partial.FavoriteTrackIds, { "U_ONE" }))

	-- The regression this stage must not reintroduce: a development build omits
	-- every track whose asset, moderation, or grant is not ready, so pruning a
	-- saved set against the runtime catalog would delete real player data.
	local unknown = OrbitRadioProfile.normalizeStored({
		FavoriteTrackIds = { "TRACK_NOT_IN_THIS_BUILD" },
		UnlockedCollectionIds = { "INDUSTRY" },
	}, NOW, config)
	check("a well-formed id the build lacks is retained, not deleted",
		sameList(unknown.FavoriteTrackIds, { "TRACK_NOT_IN_THIS_BUILD" }))

	-- Backfill for a profile that owned floors before this system shipped.
	local backfill = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	local changed = OrbitRadioProfile.unlockCollectionsForFloorCount(backfill, 2)
	check("owned floors backfill their permanent collections", changed
		and sameList(backfill.UnlockedCollectionIds, { "COMMERCE", "INDUSTRY" }),
		concat(backfill.UnlockedCollectionIds))
	check("backfill is idempotent", OrbitRadioProfile.unlockCollectionsForFloorCount(backfill, 2) == false)
	check("backfill never removes a collection the run cannot reach",
		OrbitRadioProfile.unlockCollectionsForFloorCount(backfill, 0) == false
			and #backfill.UnlockedCollectionIds == 2)
end

--[[ Malformed profiles ]]

section("malformed profile")
do
	local stored, repairs = OrbitRadioProfile.normalizeStored("not a table", NOW, config)
	check("a non-table domain is replaced with defaults", stored.Preferences.Volume == 1
		and hasRepair(repairs, "Music"))

	local garbage, garbageRepairs = OrbitRadioProfile.normalizeStored({
		Preferences = { Volume = 4, Vibe = "Nope", ShuffleEnabled = "yes", RepeatMode = 7 },
		FavoriteTrackIds = "not a list",
		EncounteredCueIds = { 1, true, "GOO_REVEAL", "GOO_REVEAL" },
		UnlockedCollectionIds = { "INDUSTRY", "bad id!", string.rep("X", 200) },
		QueueResume = 12,
	}, NOW, config)
	check("an out-of-range volume falls back and is reported", garbage.Preferences.Volume == 1
		and hasRepair(garbageRepairs, "Preferences.Volume"))
	check("an unknown enum falls back", garbage.Preferences.Vibe == MusicTypes.Vibe.StoryMix
		and garbage.Preferences.RepeatMode == MusicTypes.RepeatMode.Off)
	check("a non-boolean toggle falls back", garbage.Preferences.ShuffleEnabled == true)
	check("a non-list set becomes empty", #garbage.FavoriteTrackIds == 0
		and hasRepair(garbageRepairs, "FavoriteTrackIds"))
	check("non-string and duplicate entries are dropped",
		sameList(garbage.EncounteredCueIds, { "GOO_REVEAL" }), concat(garbage.EncounteredCueIds))
	check("malformed and oversized ids are dropped",
		sameList(garbage.UnlockedCollectionIds, { "INDUSTRY" }), concat(garbage.UnlockedCollectionIds))
	check("a non-table snapshot is dropped", garbage.QueueResume == nil
		and hasRepair(garbageRepairs, "QueueResume"))

	local nonFinite = OrbitRadioProfile.normalizeStored({
		Preferences = { Volume = 0 / 0 },
	}, NOW, config)
	check("a NaN volume falls back", nonFinite.Preferences.Volume == 1)

	-- The repair list is a bounded field-name log, never player content.
	local wide = {}
	for index = 1, 60 do
		wide[index] = index
	end
	local _, wideRepairs = OrbitRadioProfile.normalizeStored({ FavoriteTrackIds = wide }, NOW, config)
	check("the repair log stays bounded", #wideRepairs <= 12, #wideRepairs)

	-- The favorites cap is a storage bound, enforced even against a saved profile.
	local many = {}
	for index = 1, config.maxFavorites + 5 do
		many[index] = ("T_%04d"):format(index)
	end
	local capped, cappedRepairs = OrbitRadioProfile.normalizeStored({ FavoriteTrackIds = many }, NOW, config)
	check("saved favorites are capped", #capped.FavoriteTrackIds == config.maxFavorites
		and hasRepair(cappedRepairs, "FavoriteTrackIds.Limit"), #capped.FavoriteTrackIds)
end

--[[ Expired and skewed resume windows ]]

section("resume window")
do
	local function storedWith(savedAt)
		return OrbitRadioProfile.normalizeStored({
			QueueResume = { SavedAt = savedAt, TrackId = "U_ONE", PositionSeconds = 10, Queue = {} },
		}, NOW, config)
	end

	check("a snapshot inside six hours survives",
		storedWith(NOW - config.resumeTtlSeconds + 60).QueueResume ~= nil)
	local expired, expiredRepairs = OrbitRadioProfile.normalizeStored({
		QueueResume = { SavedAt = NOW - config.resumeTtlSeconds - 1, TrackId = "U_ONE", Queue = {} },
	}, NOW, config)
	check("a snapshot past six hours is dropped", expired.QueueResume == nil
		and hasRepair(expiredRepairs, "QueueResume.Expired"))
	check("a snapshot from the future is dropped",
		storedWith(NOW + config.resumeClockSkewSeconds + 1).QueueResume == nil)
	check("small clock skew is tolerated",
		storedWith(NOW + config.resumeClockSkewSeconds - 1).QueueResume ~= nil)
	check("a snapshot without a timestamp is dropped", storedWith("soon").QueueResume == nil)

	local structural = OrbitRadioProfile.normalizeStored({
		QueueResume = {
			SavedAt = NOW,
			TrackId = "bad id!",
			PositionSeconds = -5,
			Queue = { "U_ONE", 7, "U_TWO" },
			SourceKind = "Nonsense",
			SourceId = "UNIVERSAL",
		},
	}, NOW, config)
	check("a malformed current track is dropped but the queue survives",
		structural.QueueResume ~= nil and structural.QueueResume.TrackId == nil
			and sameList(structural.QueueResume.Queue, { "U_ONE", "U_TWO" }))
	check("an unknown source kind is dropped", structural.QueueResume.SourceKind == nil)

	local overlong = { SavedAt = NOW, TrackId = "U_ONE", Queue = {} }
	for index = 1, config.snapshotQueueLimit + 10 do
		overlong.Queue[index] = "U_ONE"
	end
	local trimmed, trimRepairs = OrbitRadioProfile.normalizeStored({ QueueResume = overlong }, NOW, config)
	check("a saved queue is trimmed to the limit",
		#trimmed.QueueResume.Queue == config.snapshotQueueLimit
			and hasRepair(trimRepairs, "QueueResume.Queue.Limit"))
end

--[[ Rebirth ]]

section("rebirth")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	OrbitRadioProfile.unlockCollectionsForFloorCount(stored, 3)

	local beforeGrants = OrbitRadioProfile.grantsForFloorCount(3)
	check("owned floors grant their current-run rules", beforeGrants.IndustryFloor == true
		and beforeGrants.CommerceFloor == true
		and beforeGrants.ScienceFloor == true)

	-- Rebirth wipes the run. Persistent.Music is not touched at all, so the library
	-- is unchanged and only the derived grants narrow.
	local afterGrants = OrbitRadioProfile.grantsForFloorCount(0)
	check("a rebirth narrows the run grants", afterGrants.IndustryFloor == nil
		and afterGrants.Always == true)
	check("a rebirth keeps every discovered collection",
		sameList(stored.UnlockedCollectionIds, { "COMMERCE", "INDUSTRY", "SCIENCE" }),
		concat(stored.UnlockedCollectionIds))

	local unlocks = unlocksFor(stored, 0)
	check("a discovered floor collection stays playable after a rebirth",
		unlocks:isTrackPlayable("I_ONE") == true)
	check("its ambient pool follows the current run instead",
		unlocks:isPoolEligible("INDUSTRY") == false)

	local projection = OrbitRadioProfile.project(stored, {
		now = NOW,
		config = config,
		catalog = catalog,
		unlocks = unlocks,
		unlockedFloorCount = 0,
	})
	check("the projection reports discovery and run context separately",
		contains(projection.UnlockedCollectionIds, "INDUSTRY")
			and projection.Grants.IndustryFloor == nil
			and projection.Progression == 0)
end

--[[ Permanent collection discovery ]]

section("collection discovery")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	check("a floor identity is discoverable", OrbitRadioProfile.unlockCollection(stored, "INDUSTRY") == true)
	check("discovery is idempotent", OrbitRadioProfile.unlockCollection(stored, "INDUSTRY") == false)
	check("an always-available collection is never stored as a discovery",
		OrbitRadioProfile.unlockCollection(stored, "UNIVERSAL") == false
			and OrbitRadioProfile.unlockCollection(stored, "GROUND") == false)
	check("the story collection is never unlocked wholesale",
		OrbitRadioProfile.unlockCollection(stored, "STORY") == false)
	check("an unknown collection is refused", OrbitRadioProfile.unlockCollection(stored, "MADE_UP") == false)
	check("every configured floor binds to one identity",
		OrbitRadioConfig.GetFloorById("Floor1").CollectionId == "INDUSTRY"
			and OrbitRadioConfig.GetFloorById("Floor2").CueId == "FLOOR_COMMERCE_UNLOCK"
			and OrbitRadioConfig.GetFloorByOrder(3).UnlockRule == MusicTypes.UnlockRule.ScienceFloor)
end

--[[ Story encounters ]]

section("story encounters")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)

	check("an unknown cue can never be encountered",
		OrbitRadioProfile.isEncounterEligible(stored, "NOT_A_CUE", facts()) == false)
	check("a stinger is not an encounter",
		OrbitRadioProfile.isEncounterEligible(stored, "QUEST_COMPLETE_STINGER", facts()) == false)
	check("a non-string cue is refused", OrbitRadioProfile.isEncounterEligible(stored, 12, facts()) == false)

	check("the intro cues wait for the committed intro",
		OrbitRadioProfile.isEncounterEligible(stored, "INTRO_ORBIT", facts()) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "INTRO_ORBIT", facts({ IntroSeen = true })) == true)

	-- Healing is the whole clicking phase; StoryService only advances to Lore once the
	-- healing presentation has actually finished, so that is the step the reveal waits
	-- for. Anything earlier would make the track claimable before its moment happened.
	check("the goo reveal waits for completed healing, not the healing step",
		OrbitRadioProfile.isEncounterEligible(stored, "GOO_REVEAL", facts({ StoryStep = "Meteor" })) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "GOO_REVEAL", facts({ StoryStep = "Healing" })) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "GOO_REVEAL", facts({ StoryStep = "Lore" })) == true)
	check("a later story step still qualifies",
		OrbitRadioProfile.isEncounterEligible(stored, "GOO_REVEAL", facts({ StoryStep = "Complete" })) == true)
	check("an unknown story step never qualifies",
		OrbitRadioProfile.isEncounterEligible(stored, "GOO_REVEAL", facts({ StoryStep = "Bogus" })) == false)

	check("the lore cue waits for the Mixer handover",
		OrbitRadioProfile.isEncounterEligible(stored, "GOOB_LORE", facts()) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "GOOB_LORE", facts({ MixerUnlocked = true })) == true)

	check("the arc cue waits for the committed arc",
		OrbitRadioProfile.isEncounterEligible(stored, "OPENING_ARC_COMPLETE", facts()) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "OPENING_ARC_COMPLETE", facts({
				IsArcCompleted = function(arcId)
					return arcId == OrbitRadioConfig.OpeningArcId
				end,
			})) == true)

	check("the core cues wait for the server-accepted activation",
		OrbitRadioProfile.isEncounterEligible(stored, "CORE_EMERGENCE", facts()) == false
			and OrbitRadioProfile.isEncounterEligible(stored, "OLD_GOO_BACKSTORY", facts({ HubCoreActivated = true }))
				== true)

	check("the rebirth cue is not claimable until rebirth exists",
		OrbitRadioProfile.isEncounterEligible(stored, "REBIRTH_FINALE", facts({
			IntroSeen = true,
			MixerUnlocked = true,
			HubCoreActivated = true,
			StoryStep = "Complete",
		})) == false)

	-- A floor milestone keys off permanent discovery, so it stays claimable in the
	-- run after a rebirth has taken the floor away.
	check("a floor cue waits for its permanent collection",
		OrbitRadioProfile.isEncounterEligible(stored, "FLOOR_INDUSTRY_UNLOCK", facts()) == false)
	OrbitRadioProfile.unlockCollection(stored, "INDUSTRY")
	check("a floor cue is claimable once the collection is discovered",
		OrbitRadioProfile.isEncounterEligible(stored, "FLOOR_INDUSTRY_UNLOCK", facts()) == true)

	local recorded, reason = OrbitRadioProfile.recordEncounter(stored, "GOO_REVEAL", facts({ StoryStep = "Lore" }))
	check("an eligible encounter is recorded", recorded == true and contains(stored.EncounteredCueIds, "GOO_REVEAL"))
	local again, againReason = OrbitRadioProfile.recordEncounter(stored, "GOO_REVEAL", facts({ StoryStep = "Lore" }))
	check("recording the same scene twice is a no-op", again == false and againReason == "AlreadyRecorded"
		and #stored.EncounteredCueIds == 1)
	local blocked, blockedReason = OrbitRadioProfile.recordEncounter(stored, "INTRO_ORBIT", facts())
	check("an ineligible encounter is refused", blocked == false and blockedReason == "NotEligible", reason)

	-- The reveal itself: the story track is unplayable until its cue is encountered.
	local before = unlocksFor(OrbitRadioProfile.normalizeStored(nil, NOW, config), 0)
	check("a story track is hidden before its scene", before:isTrackPlayable("S_GOO") == false)
	check("the encounter reveals exactly that recording",
		unlocksFor(stored, 0):isTrackPlayable("S_GOO") == true)

	-- The completion report the remote accepts: a cue id, the presentation that ran
	-- it, and a completion reason. The presentation id is identity the server never
	-- issued, so it is bounded and well-formed rather than trusted; the facts above
	-- are what actually decide the reveal.
	check("a presentation id may carry adapter punctuation",
		OrbitRadioProfile.isWellFormedPresentationId("intro-descent:2") == true
			and OrbitRadioProfile.isWellFormedPresentationId("GOO_REVEAL.1") == true)
	check("a malformed presentation id is refused",
		OrbitRadioProfile.isWellFormedPresentationId("") == false
			and OrbitRadioProfile.isWellFormedPresentationId(12) == false
			and OrbitRadioProfile.isWellFormedPresentationId("has space") == false
			and OrbitRadioProfile.isWellFormedPresentationId(string.rep("x", 65)) == false)

	check("only a completion reason reports an encounter",
		MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.Completed) == true
			and MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.SceneEnded) == true)
	check("a cancelled, failed, replaced, or skipped scene is not one",
		MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.Cancelled) == false
			and MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.Failed) == false
			and MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.Replaced) == false
			and MusicTypes.isCompletionReason(MusicTypes.ReleaseReason.Skipped) == false)
	check("and neither is a missing or invented reason",
		MusicTypes.isCompletionReason(nil) == false and MusicTypes.isCompletionReason("Done") == false)
end

--[[ Preferences ]]

section("preferences")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)

	local ok, _, value = OrbitRadioProfile.setPreference(stored, "Volume", 0.25)
	check("a valid preference is stored", ok == true and value == 0.25 and stored.Preferences.Volume == 0.25)
	check("an unchanged write is reported", select(2, OrbitRadioProfile.setPreference(stored, "Volume", 0.25))
		== "Unchanged")
	check("an out-of-range value is refused", select(2, OrbitRadioProfile.setPreference(stored, "Volume", 5))
		== "Invalid" and stored.Preferences.Volume == 0.25)
	check("a wrong type is refused", select(2, OrbitRadioProfile.setPreference(stored, "ShuffleEnabled", "yes"))
		== "Invalid")
	check("an unknown enum value is refused", select(2, OrbitRadioProfile.setPreference(stored, "Vibe", "Loud"))
		== "Invalid")
	check("a known enum value is accepted", OrbitRadioProfile.setPreference(stored, "Vibe", "SynthSpace") == true)
	check("an unknown field is refused", select(2, OrbitRadioProfile.setPreference(stored, "Volumes", 1))
		== "UnknownField")
	-- A live command is strict where a saved profile is normalized: an absent value
	-- must not be read as "restore the default".
	check("a missing value is refused rather than defaulted",
		select(2, OrbitRadioProfile.setPreference(stored, "Volume", nil)) == "Invalid"
			and stored.Preferences.Volume == 0.25)
	check("a client cannot write the library through preferences",
		select(2, OrbitRadioProfile.setPreference(stored, "FavoriteTrackIds", { "I_ONE" })) == "UnknownField")

	-- Reconciliation: an accepted change confirms itself and a refusal corrects a
	-- client that already drew it, so only "Unchanged" stays quiet.
	check("an accepted mutation is answered", OrbitRadioProfile.shouldReconcile(true, nil) == true)
	check("so is a refused one", OrbitRadioProfile.shouldReconcile(false, "Invalid") == true
		and OrbitRadioProfile.shouldReconcile(false, "NotPlayable") == true
		and OrbitRadioProfile.shouldReconcile(false, "Full") == true
		and OrbitRadioProfile.shouldReconcile(false, "UnknownField") == true)
	check("a no-op is not", OrbitRadioProfile.shouldReconcile(false, "Unchanged") == false)

	-- Reset All Settings: preferences only.
	stored.FavoriteTrackIds = { "U_ONE" }
	stored.EncounteredCueIds = { "GOO_REVEAL" }
	stored.UnlockedCollectionIds = { "INDUSTRY" }
	stored.QueueResume = { SavedAt = NOW, TrackId = "U_ONE", Queue = {}, Paused = false }
	local reset = OrbitRadioProfile.resetPreferences(stored)
	check("reset returns preferences to defaults", reset.Preferences.Volume == 1
		and reset.Preferences.Vibe == MusicTypes.Vibe.StoryMix)
	check("reset keeps favorites, encounters, collections, and the snapshot",
		sameList(reset.FavoriteTrackIds, { "U_ONE" })
			and sameList(reset.EncounteredCueIds, { "GOO_REVEAL" })
			and sameList(reset.UnlockedCollectionIds, { "INDUSTRY" })
			and reset.QueueResume ~= nil)
end

--[[ Favorites ]]

section("favorites")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	local function options(floorCount)
		return { config = config, catalog = catalog, unlocks = unlocksFor(stored, floorCount or 0) }
	end

	check("a playable track can be favorited", OrbitRadioProfile.setFavorite(stored, "U_ONE", true, options()) == true)
	check("favoriting twice is a no-op", select(2, OrbitRadioProfile.setFavorite(stored, "U_ONE", true, options()))
		== "Unchanged")
	check("a malformed id is refused", select(2, OrbitRadioProfile.setFavorite(stored, "nope!", true, options()))
		== "Invalid")
	check("an id absent from the catalog is refused",
		select(2, OrbitRadioProfile.setFavorite(stored, "MADE_UP", true, options())) == "NotInCatalog")
	check("a track the catalog cannot favorite is refused",
		select(2, OrbitRadioProfile.setFavorite(stored, "NO_FAV", true, options())) == "NotInCatalog")
	check("an unavailable recording is refused",
		select(2, OrbitRadioProfile.setFavorite(stored, "NO_ASSET", true, options())) == "NotPlayable")
	check("a locked collection cannot be favorited",
		select(2, OrbitRadioProfile.setFavorite(stored, "I_ONE", true, options())) == "NotPlayable")
	check("an undiscovered story track cannot be favorited",
		select(2, OrbitRadioProfile.setFavorite(stored, "S_GOO", true, options())) == "NotPlayable")
	check("an owned floor makes its tracks favoritable",
		OrbitRadioProfile.setFavorite(stored, "I_ONE", true, options(1)) == true)
	check("favorites stay sorted", sameList(stored.FavoriteTrackIds, { "I_ONE", "U_ONE" }),
		concat(stored.FavoriteTrackIds))

	-- Removal must never depend on the catalog: a favorite has to stay removable
	-- after the recording it points at is gone.
	stored.FavoriteTrackIds = { "GONE_FROM_CATALOG" }
	check("a stale favorite can still be removed",
		OrbitRadioProfile.setFavorite(stored, "GONE_FROM_CATALOG", false, options()) == true
			and #stored.FavoriteTrackIds == 0)
	check("removing a favorite that is not there is a no-op",
		select(2, OrbitRadioProfile.setFavorite(stored, "U_ONE", false, options())) == "Unchanged")

	-- A malformed flag is not "remove": reading it that way would let a broken or
	-- crafted message delete a favorite the player never touched.
	stored.FavoriteTrackIds = { "U_ONE" }
	check("a non-boolean favorite value is refused",
		select(2, OrbitRadioProfile.setFavorite(stored, "U_ONE", nil, options())) == "Invalid"
			and select(2, OrbitRadioProfile.setFavorite(stored, "U_ONE", "false", options())) == "Invalid"
			and select(2, OrbitRadioProfile.setFavorite(stored, "U_ONE", 0, options())) == "Invalid")
	check("and the favorite survives it", sameList(stored.FavoriteTrackIds, { "U_ONE" }))

	local full = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	for index = 1, config.maxFavorites do
		full.FavoriteTrackIds[index] = ("T_%04d"):format(index)
	end
	check("the favorites cap is enforced on write", select(2, OrbitRadioProfile.setFavorite(full, "U_ONE", true, {
		config = config,
		catalog = catalog,
		unlocks = unlocksFor(full, 0),
	})) == "Full")
end

--[[ Resume snapshot ingress ]]

section("resume snapshot ingress")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	local function accept(raw, floorCount, now)
		return OrbitRadioProfile.acceptSnapshot(stored, raw, {
			now = now or NOW,
			config = config,
			catalog = catalog,
			unlocks = unlocksFor(stored, floorCount or 0),
		})
	end

	-- The timestamp is the server's, always. A client cannot extend its own window.
	accept({ SavedAt = NOW + 10 * 60 * 60, TrackId = "U_ONE", PositionSeconds = 3, Queue = {} })
	check("SavedAt is stamped by the server", stored.QueueResume.SavedAt == NOW, stored.QueueResume.SavedAt)

	accept({ SavedAt = 1, TrackId = "U_ONE", PositionSeconds = 3, Queue = {} }, 0, NOW)
	check("a backdated client timestamp is overwritten too", stored.QueueResume.SavedAt == NOW)

	accept({ TrackId = "U_TWO", PositionSeconds = 1, Queue = {} })
	check("a position before the playback region is clamped up", stored.QueueResume.PositionSeconds == 5,
		stored.QueueResume.PositionSeconds)
	accept({ TrackId = "U_TWO", PositionSeconds = 900, Queue = {} })
	check("a position past the playback region is clamped down", stored.QueueResume.PositionSeconds == 65)
	accept({ TrackId = "U_TWO", PositionSeconds = 0 / 0, Queue = {} })
	check("a non-finite position falls back into the region", stored.QueueResume.PositionSeconds == 5)
	accept({ TrackId = "U_TWO", PositionSeconds = -20, Queue = {} })
	check("a negative position falls back into the region", stored.QueueResume.PositionSeconds == 5)

	accept({ TrackId = "U_ONE", PositionSeconds = 0, Queue = { "U_ONE", "I_ONE", "MADE_UP", "U_TWO", "S_GOO" } })
	check("locked, unknown, and hidden queue entries are discarded in order",
		sameList(stored.QueueResume.Queue, { "U_ONE", "U_TWO" }), concat(stored.QueueResume.Queue))

	local overlong = { TrackId = "U_ONE", PositionSeconds = 0, Queue = {} }
	for index = 1, config.snapshotQueueLimit + 25 do
		overlong.Queue[index] = "U_ONE"
	end
	accept(overlong)
	check("an oversized incoming queue is trimmed", #stored.QueueResume.Queue == config.snapshotQueueLimit)

	accept({ TrackId = "U_ONE", Queue = {}, SourceKind = "Station", SourceId = "Playful" })
	check("a valid station source is kept", stored.QueueResume.SourceKind == "Station"
		and stored.QueueResume.SourceId == "Playful")
	accept({ TrackId = "U_ONE", Queue = {}, SourceKind = "Collection", SourceId = "INDUSTRY" })
	check("a collection the player has not unlocked is dropped", stored.QueueResume.SourceKind == nil)
	accept({ TrackId = "U_ONE", Queue = {}, SourceKind = "Pool", SourceId = "INDUSTRY" }, 1)
	check("an owned pool source is kept", stored.QueueResume.SourceKind == "Pool")

	accept({ TrackId = "I_ONE", Queue = { "MADE_UP" } })
	check("a snapshot with nothing resumable is cleared", stored.QueueResume == nil)

	accept({ TrackId = "U_ONE", Queue = {} })
	local cleared, clearedReason = OrbitRadioProfile.acceptSnapshot(stored, nil, { now = NOW, config = config })
	check("an explicit nil clears the snapshot", cleared == true and clearedReason == "Cleared"
		and stored.QueueResume == nil)
	check("clearing an absent snapshot is a no-op",
		select(2, OrbitRadioProfile.acceptSnapshot(stored, nil, { now = NOW, config = config })) == "Unchanged")

	check("a non-table snapshot is refused",
		select(2, OrbitRadioProfile.acceptSnapshot(stored, "junk", { now = NOW, config = config })) == "Invalid")
	check("a snapshot without a server clock is refused",
		select(2, OrbitRadioProfile.acceptSnapshot(stored, { TrackId = "U_ONE" }, { config = config })) == "Invalid")

	-- Ingress typing is strict. A saved profile is repaired field by field because it
	-- is the only copy of a real player's state; a message arriving right now either
	-- has the shape the client contract promises or it is broken, so it is refused
	-- whole rather than half-read into the profile.
	accept({ TrackId = "U_ONE", PositionSeconds = 3, Queue = {} })
	local kept = stored.QueueResume
	check("a numeric string is not a position",
		select(2, accept({ TrackId = "U_ONE", PositionSeconds = "42", Queue = {} })) == "Invalid"
			and stored.QueueResume == kept)
	check("a non-boolean Paused is not false",
		select(2, accept({ TrackId = "U_ONE", PositionSeconds = 3, Paused = "yes", Queue = {} })) == "Invalid"
			and stored.QueueResume == kept)
	check("a non-string track id is refused",
		select(2, accept({ TrackId = 12, Queue = {} })) == "Invalid")
	check("a non-table queue is refused",
		select(2, accept({ TrackId = "U_ONE", Queue = "U_TWO" })) == "Invalid")
	check("a non-string source is refused",
		select(2, accept({ TrackId = "U_ONE", Queue = {}, SourceKind = 7, SourceId = "Playful" })) == "Invalid")
	check("the well-formed snapshot is still there afterwards", stored.QueueResume == kept)

	-- Value handling is unchanged: the right type with a bad value still normalizes.
	accept({ TrackId = "U_TWO", PositionSeconds = 0 / 0, Queue = {} })
	check("a non-finite position still falls back into the region", stored.QueueResume.PositionSeconds == 5)
end

--[[ Projection and restore revalidation ]]

section("projection")
do
	local stored = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	OrbitRadioProfile.unlockCollection(stored, "INDUSTRY")
	stored.FavoriteTrackIds = { "U_ONE" }
	stored.QueueResume = {
		SavedAt = NOW,
		TrackId = "U_ONE",
		PositionSeconds = 12,
		Paused = true,
		Queue = { "I_ONE", "U_TWO" },
	}

	local function projectAt(now, floorCount, includeResume)
		return OrbitRadioProfile.project(stored, {
			now = now,
			config = config,
			catalog = catalog,
			unlocks = unlocksFor(stored, floorCount),
			unlockedFloorCount = floorCount,
			includeResume = includeResume,
		})
	end

	local hydrate = projectAt(NOW, 1, true)
	check("the hydrate carries the resume snapshot", hydrate.QueueResume ~= nil
		and hydrate.QueueResume.TrackId == "U_ONE"
		and hydrate.QueueResume.Paused == true)
	check("a later push carries no snapshot", projectAt(NOW, 1, false).QueueResume == nil)
	check("the projection reports grants and progression", hydrate.Grants.IndustryFloor == true
		and hydrate.Progression == 1)
	check("the projection carries the library", sameList(hydrate.FavoriteTrackIds, { "U_ONE" })
		and contains(hydrate.UnlockedCollectionIds, "INDUSTRY"))
	check("the projection carries validated preferences", hydrate.Preferences.Vibe == MusicTypes.Vibe.StoryMix
		and hydrate.Preferences.Volume == 1)

	-- Restore is revalidated every delivery, not just at the write.
	check("an expired window is ignored at restore",
		projectAt(NOW + config.resumeTtlSeconds + 1, 1, true).QueueResume == nil)

	-- The saved snapshot keeps I_ONE, but this run cannot reach it any more.
	local rebirthed = OrbitRadioProfile.normalizeStored(nil, NOW, config)
	rebirthed.QueueResume = { SavedAt = NOW, TrackId = "U_ONE", PositionSeconds = 0, Queue = { "I_ONE", "U_TWO" } }
	local narrow = OrbitRadioProfile.project(rebirthed, {
		now = NOW,
		config = config,
		catalog = catalog,
		unlocks = unlocksFor(rebirthed, 0),
		unlockedFloorCount = 0,
		includeResume = true,
	})
	check("entries the player can no longer reach are discarded at restore",
		sameList(narrow.QueueResume.Queue, { "U_TWO" }), concat(narrow.QueueResume.Queue))

	local empty = OrbitRadioProfile.project(nil, { now = NOW, config = config, catalog = catalog })
	check("projecting a missing domain still returns defaults", empty.Preferences.Volume == 1
		and empty.Progression == 0 and empty.Grants.Always == true)
end

--[[ Ingress rate limits ]]

section("rate limits")
do
	local limit = { Limit = 3, WindowSeconds = 10 }
	local state
	local allowed
	for index = 1, 3 do
		allowed, state = OrbitRadioProfile.allowRate(state, 100, limit)
		check(("message %d inside the limit is allowed"):format(index), allowed == true)
	end
	allowed, state = OrbitRadioProfile.allowRate(state, 100, limit)
	check("the message past the limit is dropped", allowed == false)
	allowed, state = OrbitRadioProfile.allowRate(state, 109.9, limit)
	check("the window does not reset early", allowed == false)
	allowed, state = OrbitRadioProfile.allowRate(state, 110, limit)
	check("a fresh window allows again", allowed == true and state.Count == 1)
	check("a non-finite clock is refused", OrbitRadioProfile.allowRate(state, 0 / 0, limit) == false)
	check("a missing limit is refused", OrbitRadioProfile.allowRate(nil, 100, nil) == false)

	for name, configured in pairs(OrbitRadioConfig.Limits) do
		check(("%s declares a usable bound"):format(name),
			type(configured.Limit) == "number" and configured.Limit > 0
				and type(configured.WindowSeconds) == "number" and configured.WindowSeconds > 0)
	end
end

print("")
if failures == 0 then
	print("orbit radio persistence: all checks passed")
else
	print(("orbit radio persistence: %d check(s) failed"):format(failures))
end
return failures == 0 and 0 or 1
