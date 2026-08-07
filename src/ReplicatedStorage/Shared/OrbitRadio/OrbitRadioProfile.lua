-- OrbitRadioProfile -- the pure half of ClickGame's Persistent.Music adapter.
--
-- Everything here is a plain function over plain tables: no Player, no profile, no
-- remote, no clock. MusicService is the Roblox shell that owns lifecycle, remotes,
-- and per-player state; this module owns every decision that has to be correct, so
-- fresh/old/malformed/expired/rebirthed reconciliation is testable without Studio.
--
-- Two boundaries are easy to get backwards, so they are stated once:
--
--   * STORED normalization is structural only. It repairs types, dedupes, sorts,
--     and enforces bounds, but it does NOT delete a well-formed id the current
--     runtime catalog happens to lack. The development catalog omits every track
--     whose asset id, moderation, or experience grant is not ready yet, so pruning
--     against it at load would permanently destroy a player's favorites the first
--     time a recording was unavailable. Catalog membership is enforced where it
--     actually protects something: on the write path, and on resume restore.
--
--   * PROJECTION is what the owning client is told. The saved sets go out as they
--     are stored (the client's unlock resolver already ignores ids its catalog does
--     not carry), while QueueResume is fully revalidated against the approved
--     catalog and the player's unlocks every single time it is delivered.

local MusicConfig = require(script.Parent.Parent.Music.MusicConfig)
local MusicPersistence = require(script.Parent.Parent.Music.MusicPersistence)
local MusicTypes = require(script.Parent.Parent.Music.MusicTypes)
local OrbitRadioConfig = require(script.Parent.OrbitRadioConfig)

local OrbitRadioProfile = {}

local MAX_REPAIRS = 12
local PREFERENCE_FIELDS = table.freeze({
	Volume = true,
	StoryMomentsEnabled = true,
	Vibe = true,
	ShuffleEnabled = true,
	RepeatMode = true,
})

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isWellFormedId(id)
	return type(id) == "string"
		and #id > 0
		and #id <= OrbitRadioConfig.MaxIdLength
		and string.match(id, OrbitRadioConfig.IdPattern) ~= nil
end

OrbitRadioProfile.isWellFormedId = isWellFormedId

local function isWellFormedPresentationId(id)
	return type(id) == "string"
		and #id > 0
		and #id <= OrbitRadioConfig.MaxPresentationIdLength
		and string.match(id, OrbitRadioConfig.PresentationIdPattern) ~= nil
end

OrbitRadioProfile.isWellFormedPresentationId = isWellFormedPresentationId

-- Repairs are field labels, never player content.
local function note(repairs, label)
	if repairs then
		table.insert(repairs, label)
	end
end

-- One bad array can produce one label per entry, so the log is capped before it
-- reaches a warn(): a single garbage profile must not be able to flood the output.
local function trimRepairs(repairs)
	local overflow = #repairs - MAX_REPAIRS
	if overflow <= 0 then
		return repairs
	end
	for index = #repairs, MAX_REPAIRS, -1 do
		repairs[index] = nil
	end
	table.insert(repairs, ("and %d more"):format(overflow + 1))
	return repairs
end

local function copyArray(source)
	local result = {}
	if type(source) == "table" then
		for _, value in ipairs(source) do
			table.insert(result, value)
		end
	end
	return result
end

local function indexOf(list, value)
	for index, entry in ipairs(list) do
		if entry == value then
			return index
		end
	end
	return nil
end

function OrbitRadioProfile.defaults()
	return MusicPersistence.defaults()
end

--[[ Stored normalization ]]

-- Structural repair of a saved resume snapshot. Catalog and entitlement checks
-- belong to acceptSnapshot (write) and project (restore); this only guarantees the
-- stored shape is sane and the six-hour window has not passed.
function OrbitRadioProfile.normalizeStoredSnapshot(raw, now, config, repairs)
	config = config or MusicConfig.new()
	if raw == nil then
		return nil
	end
	if type(raw) ~= "table" or not isFinite(raw.SavedAt) then
		note(repairs, "QueueResume")
		return nil
	end
	if MusicPersistence.isSnapshotExpired(raw, now, config) then
		note(repairs, "QueueResume.Expired")
		return nil
	end

	local snapshot = { SavedAt = raw.SavedAt, Paused = raw.Paused == true, Queue = {} }

	if isWellFormedId(raw.TrackId) then
		snapshot.TrackId = raw.TrackId
		if isFinite(raw.PositionSeconds) and raw.PositionSeconds >= 0 then
			snapshot.PositionSeconds = raw.PositionSeconds
		else
			snapshot.PositionSeconds = 0
			if raw.PositionSeconds ~= nil then
				note(repairs, "QueueResume.PositionSeconds")
			end
		end
	elseif raw.TrackId ~= nil then
		note(repairs, "QueueResume.TrackId")
	end

	if type(raw.Queue) == "table" then
		for _, trackId in ipairs(raw.Queue) do
			if #snapshot.Queue >= config.snapshotQueueLimit then
				note(repairs, "QueueResume.Queue.Limit")
				break
			end
			if isWellFormedId(trackId) then
				table.insert(snapshot.Queue, trackId)
			else
				note(repairs, "QueueResume.Queue")
			end
		end
	elseif raw.Queue ~= nil then
		note(repairs, "QueueResume.Queue")
	end

	if raw.SourceKind ~= nil then
		if MusicTypes.SourceKind[raw.SourceKind] and isWellFormedId(raw.SourceId) then
			snapshot.SourceKind = raw.SourceKind
			snapshot.SourceId = raw.SourceId
		else
			note(repairs, "QueueResume.Source")
		end
	end

	if not snapshot.TrackId and #snapshot.Queue == 0 then
		return nil
	end
	return snapshot
end

-- The load boundary. Always returns a fully formed domain, whatever it was handed:
-- nil (fresh profile), a table missing fields (old profile), or arbitrary garbage
-- (malformed profile). The second return is the bounded repair list.
function OrbitRadioProfile.normalizeStored(raw, now, config)
	config = config or MusicConfig.new()
	local repairs = {}
	local source = raw
	if source ~= nil and type(source) ~= "table" then
		note(repairs, "Music")
		source = nil
	end
	source = source or {}

	local stored = {
		Preferences = MusicPersistence.sanitizePreferences(source.Preferences, repairs),
		FavoriteTrackIds = MusicPersistence.sanitizeIdSet(
			source.FavoriteTrackIds,
			isWellFormedId,
			config.maxFavorites,
			"FavoriteTrackIds",
			repairs
		),
		EncounteredCueIds = MusicPersistence.sanitizeIdSet(
			source.EncounteredCueIds,
			isWellFormedId,
			nil,
			"EncounteredCueIds",
			repairs
		),
		UnlockedCollectionIds = MusicPersistence.sanitizeIdSet(
			source.UnlockedCollectionIds,
			isWellFormedId,
			nil,
			"UnlockedCollectionIds",
			repairs
		),
	}
	stored.QueueResume = OrbitRadioProfile.normalizeStoredSnapshot(source.QueueResume, now, config, repairs)

	return stored, trimRepairs(repairs)
end

--[[ Progression ]]

-- Current-run unlock rules. Automatic pool selection follows the run, which is why
-- a rebirth narrows Story Mix back to Ground even though nothing is forgotten.
function OrbitRadioProfile.grantsForFloorCount(unlockedFloorCount)
	local count = math.max(math.floor(tonumber(unlockedFloorCount) or 0), 0)
	local grants = { [MusicTypes.UnlockRule.Always] = true }
	for _, floor in ipairs(OrbitRadioConfig.Floors) do
		if floor.Order <= count then
			grants[floor.UnlockRule] = true
		end
	end
	return grants
end

-- Collection discovery is permanent, so this only ever adds. It doubles as the
-- backfill for a profile that owned floors before Orbit Radio existed.
function OrbitRadioProfile.unlockCollectionsForFloorCount(stored, unlockedFloorCount)
	local count = math.max(math.floor(tonumber(unlockedFloorCount) or 0), 0)
	local changed = false
	for _, floor in ipairs(OrbitRadioConfig.Floors) do
		if floor.Order <= count and OrbitRadioProfile.unlockCollection(stored, floor.CollectionId) then
			changed = true
		end
	end
	return changed
end

-- Only a floor identity is a discoverable collection. Universal/Ground are owned
-- from the first session, and Story opens one recording at a time through cue
-- encounters, so neither is ever written into the saved set.
function OrbitRadioProfile.unlockCollection(stored, collectionId)
	if type(stored) ~= "table" or type(stored.UnlockedCollectionIds) ~= "table" then
		return false
	end
	if not OrbitRadioConfig.GetFloorByCollectionId(collectionId) then
		return false
	end
	if indexOf(stored.UnlockedCollectionIds, collectionId) then
		return false
	end
	table.insert(stored.UnlockedCollectionIds, collectionId)
	table.sort(stored.UnlockedCollectionIds)
	return true
end

function OrbitRadioProfile.isCollectionUnlocked(stored, collectionId)
	local list = type(stored) == "table" and stored.UnlockedCollectionIds or nil
	return type(list) == "table" and indexOf(list, collectionId) ~= nil
end

--[[ Story encounters ]]

-- `facts` is authoritative server state, never anything the client sent:
--   IntroSeen, StoryStep, MixerUnlocked, HubCoreActivated booleans/strings, and
--   IsArcCompleted(arcId).
function OrbitRadioProfile.isEncounterEligible(stored, cueId, facts)
	local requirement = type(cueId) == "string" and OrbitRadioConfig.StoryCues[cueId] or nil
	if not requirement then
		return false
	end
	facts = type(facts) == "table" and facts or {}
	local kind = requirement.Requirement
	local Requirement = OrbitRadioConfig.Requirement

	if kind == Requirement.IntroSeen then
		return facts.IntroSeen == true
	elseif kind == Requirement.StoryStepAtLeast then
		local reached = OrbitRadioConfig.StoryStepRank[facts.StoryStep]
		local needed = OrbitRadioConfig.StoryStepRank[requirement.StoryStep]
		return reached ~= nil and needed ~= nil and reached >= needed
	elseif kind == Requirement.MixerUnlocked then
		return facts.MixerUnlocked == true
	elseif kind == Requirement.HubCoreActivated then
		return facts.HubCoreActivated == true
	elseif kind == Requirement.ArcCompleted then
		return type(facts.IsArcCompleted) == "function" and facts.IsArcCompleted(requirement.ArcId) == true
	elseif kind == Requirement.CollectionUnlocked then
		return OrbitRadioProfile.isCollectionUnlocked(stored, requirement.CollectionId)
	end
	return false
end

-- Idempotent by construction: recording the same completed scene twice is a no-op,
-- which is what lets a scene owner report on every replay without special casing.
function OrbitRadioProfile.recordEncounter(stored, cueId, facts)
	if type(stored) ~= "table" or type(stored.EncounteredCueIds) ~= "table" then
		return false, "NotReady"
	end
	if not OrbitRadioProfile.isEncounterEligible(stored, cueId, facts) then
		return false, "NotEligible"
	end
	if indexOf(stored.EncounteredCueIds, cueId) then
		return false, "AlreadyRecorded"
	end
	table.insert(stored.EncounteredCueIds, cueId)
	table.sort(stored.EncounteredCueIds)
	return true
end

--[[ Player commands ]]

-- Validated through the engine's own preference rules rather than a second copy of
-- them, so the saved domain can never drift from what the director accepts.
function OrbitRadioProfile.setPreference(stored, field, value)
	if type(stored) ~= "table" or type(stored.Preferences) ~= "table" then
		return false, "NotReady"
	end
	if not PREFERENCE_FIELDS[field] then
		return false, "UnknownField"
	end
	-- A missing value is not a request to restore the default. Sanitization would
	-- happily substitute one, which is right for an old save and wrong for a live
	-- command: this write path is strict, so an absent field is a broken message.
	if value == nil then
		return false, "Invalid"
	end

	local rejections = {}
	local candidate = MusicPersistence.sanitizePreferences({ [field] = value }, rejections)
	if #rejections > 0 then
		return false, "Invalid"
	end
	if stored.Preferences[field] == candidate[field] then
		return false, "Unchanged"
	end
	stored.Preferences[field] = candidate[field]
	return true, nil, candidate[field]
end

-- Adding requires the recording to be in the approved catalog AND playable for this
-- player, so a crafted id cannot smuggle an unreleased or story-locked track into a
-- saved set. Removing is always allowed: a favorite must stay removable after the
-- recording it points at has left the catalog.
--
-- `favorited` must be a real boolean. Reading anything else as "remove" would let a
-- malformed message delete a favorite the player never touched.
function OrbitRadioProfile.setFavorite(stored, trackId, favorited, options)
	if type(stored) ~= "table" or type(stored.FavoriteTrackIds) ~= "table" then
		return false, "NotReady"
	end
	if not isWellFormedId(trackId) or type(favorited) ~= "boolean" then
		return false, "Invalid"
	end
	options = options or {}
	local config = options.config or MusicConfig.new()
	local existing = indexOf(stored.FavoriteTrackIds, trackId)

	if not favorited then
		if not existing then
			return false, "Unchanged"
		end
		table.remove(stored.FavoriteTrackIds, existing)
		return true
	end

	if existing then
		return false, "Unchanged"
	end
	if #stored.FavoriteTrackIds >= config.maxFavorites then
		return false, "Full"
	end

	local catalog = options.catalog
	local track = catalog and catalog:getTrack(trackId)
	if not track or track.favoriteEnabled == false then
		return false, "NotInCatalog"
	end
	if options.unlocks and not options.unlocks:isTrackPlayable(trackId) then
		return false, "NotPlayable"
	end

	table.insert(stored.FavoriteTrackIds, trackId)
	table.sort(stored.FavoriteTrackIds)
	return true
end

-- Ingress typing for a live snapshot message. This is the strict half of the
-- asymmetry: an old saved profile is normalized field by field because it is the
-- only copy of a real player's state, but a message a client sends right now either
-- has the shape the client contract promises or it is broken, so it is refused
-- whole rather than half-read. Value handling (clamping into the region, discarding
-- unplayable entries in order) stays with sanitizeQueueResume.
local function hasIngressTypes(raw)
	if raw.TrackId ~= nil and type(raw.TrackId) ~= "string" then
		return false
	end
	if raw.PositionSeconds ~= nil and type(raw.PositionSeconds) ~= "number" then
		return false
	end
	if raw.Paused ~= nil and type(raw.Paused) ~= "boolean" then
		return false
	end
	if raw.Queue ~= nil and type(raw.Queue) ~= "table" then
		return false
	end
	if raw.SourceKind ~= nil and type(raw.SourceKind) ~= "string" then
		return false
	end
	if raw.SourceId ~= nil and type(raw.SourceId) ~= "string" then
		return false
	end
	return true
end

-- Should this mutation's outcome be answered with the authoritative projection?
-- An accepted change confirms itself, and a refusal has to correct a client that
-- already drew the change optimistically. "Unchanged" is the only quiet case: it
-- tells the client nothing it is not already showing.
function OrbitRadioProfile.shouldReconcile(accepted, problem)
	if accepted then
		return true
	end
	return problem ~= nil and problem ~= "Unchanged"
end

-- The resume write path. `now` is the server's clock and becomes SavedAt: a client
-- never gets to say when its own snapshot was taken, so it cannot extend the
-- six-hour window or backdate a snapshot out of it.
function OrbitRadioProfile.acceptSnapshot(stored, raw, options)
	if type(stored) ~= "table" then
		return false, "NotReady"
	end
	options = options or {}
	local config = options.config or MusicConfig.new()
	local now = options.now

	-- An explicit nil is the client saying it has nothing to resume (it stopped, or
	-- cleared everything). Honour it: keeping the old snapshot would resume music the
	-- player deliberately left behind.
	if raw == nil then
		local had = stored.QueueResume ~= nil
		stored.QueueResume = nil
		return had, had and "Cleared" or "Unchanged"
	end
	if type(raw) ~= "table" or not isFinite(now) or not hasIngressTypes(raw) then
		return false, "Invalid"
	end

	local stamped = {
		SavedAt = now,
		TrackId = raw.TrackId,
		PositionSeconds = raw.PositionSeconds,
		Paused = raw.Paused,
		Queue = raw.Queue,
		SourceKind = raw.SourceKind,
		SourceId = raw.SourceId,
	}
	local rejections = {}
	local snapshot = MusicPersistence.sanitizeQueueResume(stamped, {
		catalog = options.catalog,
		unlocks = options.unlocks,
		now = now,
		config = config,
		rejections = rejections,
	})
	if not snapshot then
		-- Nothing survived revalidation. Clear rather than keep a stale snapshot:
		-- the client just told us its listening state, and none of it is resumable.
		local had = stored.QueueResume ~= nil
		stored.QueueResume = nil
		return had, "Empty", rejections
	end

	stored.QueueResume = snapshot
	return true, nil, rejections
end

-- Reset All Settings. Preferences and the separate MusicEnabled override go back to
-- their defaults; the library and the short-lived snapshot are not settings and
-- survive untouched.
function OrbitRadioProfile.resetPreferences(stored)
	return MusicPersistence.resetPreferences(stored)
end

--[[ Projection ]]

-- What the owning client is told. QueueResume is revalidated against the approved
-- catalog and the player's unlocks on every delivery, so a track that left the
-- catalog, a collection the run cannot reach, or an expired window all fall back to
-- a fresh contextual selection instead of blocking startup.
function OrbitRadioProfile.project(stored, options)
	options = options or {}
	local config = options.config or MusicConfig.new()
	local source = type(stored) == "table" and stored or OrbitRadioProfile.defaults()

	local projection = {
		Kind = options.kind or OrbitRadioConfig.ProjectionKind.Hydrate,
		ServerTime = options.now,
		Preferences = {
			Volume = source.Preferences and source.Preferences.Volume,
			StoryMomentsEnabled = source.Preferences and source.Preferences.StoryMomentsEnabled,
			Vibe = source.Preferences and source.Preferences.Vibe,
			ShuffleEnabled = source.Preferences and source.Preferences.ShuffleEnabled,
			RepeatMode = source.Preferences and source.Preferences.RepeatMode,
		},
		FavoriteTrackIds = copyArray(source.FavoriteTrackIds),
		EncounteredCueIds = copyArray(source.EncounteredCueIds),
		UnlockedCollectionIds = copyArray(source.UnlockedCollectionIds),
		Grants = OrbitRadioProfile.grantsForFloorCount(options.unlockedFloorCount),
		Progression = math.max(math.floor(tonumber(options.unlockedFloorCount) or 0), 0),
	}

	if options.includeResume then
		projection.QueueResume = MusicPersistence.sanitizeQueueResume(source.QueueResume, {
			catalog = options.catalog,
			unlocks = options.unlocks,
			now = options.now,
			config = config,
			rejections = options.rejections,
		})
	end

	return projection
end

--[[ Ingress bounds ]]

-- Fixed-window counter, kept pure so the limits are testable: the caller owns the
-- per-player state table and passes the previous window back in.
function OrbitRadioProfile.allowRate(state, now, limit)
	local windowSeconds = limit and limit.WindowSeconds or 0
	local maximum = limit and limit.Limit or 0
	if not isFinite(now) or maximum <= 0 then
		return false, state
	end
	if type(state) ~= "table" or not isFinite(state.StartedAt) or now - state.StartedAt >= windowSeconds then
		return true, { StartedAt = now, Count = 1 }
	end
	if state.Count >= maximum then
		return false, state
	end
	return true, { StartedAt = state.StartedAt, Count = state.Count + 1 }
end

return OrbitRadioProfile
