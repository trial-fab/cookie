-- MusicPersistence -- validation and projection for the saved Persistent.Music
-- domain. Pure: no DataStore, no profile implementation, no remotes.
--
-- The same functions run on both sides of the wire. The client projects a
-- validated view of its saved preferences and library; the server revalidates
-- everything a client sends, because a client may never make a track, an unlock,
-- or a queue entry authoritative by asking for it.
--
-- Shape:
--   Preferences.Volume               number 0..1
--   Preferences.StoryMomentsEnabled  boolean
--   Preferences.Vibe                 StoryMix | Playful | SynthSpace | Balanced
--   Preferences.ShuffleEnabled       boolean
--   Preferences.RepeatMode           Off | All | One
--   FavoriteTrackIds                 sorted catalog track ids
--   EncounteredCueIds                sorted catalog cue ids
--   UnlockedCollectionIds            sorted catalog collection ids
--   QueueResume                      bounded snapshot, six-hour rolling window
--
-- MusicEnabled stays in the existing universal settings contract; it is the
-- master mute and is deliberately not duplicated here.

local MusicTypes = require(script.Parent.MusicTypes)
local MusicConfig = require(script.Parent.MusicConfig)

local MusicPersistence = {}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function note(rejections, label)
	if rejections then
		table.insert(rejections, label)
	end
end

function MusicPersistence.defaults()
	return {
		Preferences = {
			Volume = 1,
			StoryMomentsEnabled = true,
			Vibe = MusicTypes.Vibe.StoryMix,
			ShuffleEnabled = true,
			RepeatMode = MusicTypes.RepeatMode.Off,
		},
		FavoriteTrackIds = {},
		EncounteredCueIds = {},
		UnlockedCollectionIds = {},
		QueueResume = nil,
	}
end

function MusicPersistence.sanitizePreferences(raw, rejections)
	local defaults = MusicPersistence.defaults().Preferences
	local source = type(raw) == "table" and raw or {}
	local result = {}

	if isFinite(source.Volume) and source.Volume >= 0 and source.Volume <= 1 then
		result.Volume = source.Volume
	else
		if source.Volume ~= nil then
			note(rejections, "Preferences.Volume")
		end
		result.Volume = defaults.Volume
	end

	if type(source.StoryMomentsEnabled) == "boolean" then
		result.StoryMomentsEnabled = source.StoryMomentsEnabled
	else
		if source.StoryMomentsEnabled ~= nil then
			note(rejections, "Preferences.StoryMomentsEnabled")
		end
		result.StoryMomentsEnabled = defaults.StoryMomentsEnabled
	end

	if MusicTypes.Vibe[source.Vibe] then
		result.Vibe = source.Vibe
	else
		if source.Vibe ~= nil then
			note(rejections, "Preferences.Vibe")
		end
		result.Vibe = defaults.Vibe
	end

	if type(source.ShuffleEnabled) == "boolean" then
		result.ShuffleEnabled = source.ShuffleEnabled
	else
		if source.ShuffleEnabled ~= nil then
			note(rejections, "Preferences.ShuffleEnabled")
		end
		result.ShuffleEnabled = defaults.ShuffleEnabled
	end

	if MusicTypes.RepeatMode[source.RepeatMode] then
		result.RepeatMode = source.RepeatMode
	else
		if source.RepeatMode ~= nil then
			note(rejections, "Preferences.RepeatMode")
		end
		result.RepeatMode = defaults.RepeatMode
	end

	return result
end

-- Set semantics with a deterministic order, so an identical library always saves
-- an identical table.
function MusicPersistence.sanitizeIdSet(raw, isValid, limit, label, rejections)
	local seen, result = {}, {}
	if type(raw) ~= "table" then
		if raw ~= nil then
			note(rejections, label)
		end
		return result
	end

	for index, id in ipairs(raw) do
		if type(id) == "string" and isValid(id) then
			if not seen[id] then
				seen[id] = true
				table.insert(result, id)
			end
		else
			note(rejections, ("%s[%d]"):format(label, index))
		end
	end

	table.sort(result)
	if limit and #result > limit then
		note(rejections, label .. ".Limit")
		while #result > limit do
			table.remove(result)
		end
	end
	return result
end

function MusicPersistence.isSnapshotExpired(snapshot, now, config)
	config = config or MusicConfig.new()
	if type(snapshot) ~= "table" or not isFinite(snapshot.SavedAt) then
		return true
	end
	if not isFinite(now) then
		return true
	end
	if snapshot.SavedAt > now + config.resumeClockSkewSeconds then
		return true
	end
	return (now - snapshot.SavedAt) > config.resumeTtlSeconds
end

-- Validates a resume snapshot against the approved catalog and the player's
-- permanent unlocks. Invalid queue entries are discarded in order; an invalid
-- current track drops Now Playing but keeps a usable queue.
function MusicPersistence.sanitizeQueueResume(raw, options)
	options = options or {}
	local config = options.config or MusicConfig.new()
	local catalog = options.catalog
	local unlocks = options.unlocks
	local rejections = options.rejections

	if raw == nil then
		return nil
	end
	if type(raw) ~= "table" or not catalog then
		note(rejections, "QueueResume")
		return nil
	end
	if MusicPersistence.isSnapshotExpired(raw, options.now, config) then
		note(rejections, "QueueResume.Expired")
		return nil
	end

	local function isPlayable(trackId)
		if options.isPlayable then
			return options.isPlayable(trackId) == true
		end
		if not catalog:isTrackAvailable(trackId) then
			return false
		end
		if unlocks then
			return unlocks:isTrackPlayable(trackId)
		end
		return true
	end

	local snapshot = {
		SavedAt = raw.SavedAt,
		Paused = raw.Paused == true,
		Queue = {},
	}
	-- A wrong-typed flag is reported rather than quietly read as false, so a broken
	-- client is visible instead of looking like a player who never paused.
	if raw.Paused ~= nil and type(raw.Paused) ~= "boolean" then
		note(rejections, "QueueResume.Paused")
	end

	if type(raw.TrackId) == "string" and isPlayable(raw.TrackId) then
		snapshot.TrackId = raw.TrackId
		if isFinite(raw.PositionSeconds) and raw.PositionSeconds >= 0 then
			snapshot.PositionSeconds = catalog:clampPosition(raw.TrackId, raw.PositionSeconds)
		else
			-- Anything that is not a finite, non-negative number is not a position:
			-- resume at the start of the region rather than at a coerced value.
			if raw.PositionSeconds ~= nil then
				note(rejections, "QueueResume.PositionSeconds")
			end
			snapshot.PositionSeconds = catalog:clampPosition(raw.TrackId, 0)
		end
	elseif raw.TrackId ~= nil then
		note(rejections, "QueueResume.TrackId")
	end

	if type(raw.Queue) == "table" then
		for index, trackId in ipairs(raw.Queue) do
			if #snapshot.Queue >= config.snapshotQueueLimit then
				note(rejections, "QueueResume.Queue.Limit")
				break
			end
			if type(trackId) == "string" and isPlayable(trackId) then
				table.insert(snapshot.Queue, trackId)
			else
				note(rejections, ("QueueResume.Queue[%d]"):format(index))
			end
		end
	elseif raw.Queue ~= nil then
		note(rejections, "QueueResume.Queue")
	end

	if raw.SourceKind ~= nil then
		local kind, id = raw.SourceKind, raw.SourceId
		local valid = false
		if kind == MusicTypes.SourceKind.Station and MusicTypes.Vibe[id] then
			valid = true
		elseif kind == MusicTypes.SourceKind.Collection and catalog:getCollection(id) then
			valid = not unlocks or unlocks:isCollectionUnlocked(id)
		elseif kind == MusicTypes.SourceKind.Pool and catalog:getPool(id) then
			valid = not unlocks or unlocks:isPoolEligible(id)
		end
		if valid then
			snapshot.SourceKind = kind
			snapshot.SourceId = id
		else
			note(rejections, "QueueResume.Source")
		end
	end

	if not snapshot.TrackId and #snapshot.Queue == 0 then
		return nil
	end
	return snapshot
end

-- Full domain validation. Returns the sanitized value plus every rejected field,
-- so a caller can log a bounded diagnostic without echoing player content.
function MusicPersistence.sanitize(raw, options)
	options = options or {}
	local config = options.config or MusicConfig.new()
	local catalog = options.catalog
	local rejections = options.rejections or {}
	local source = type(raw) == "table" and raw or {}

	local result = {
		Preferences = MusicPersistence.sanitizePreferences(source.Preferences, rejections),
		FavoriteTrackIds = {},
		EncounteredCueIds = {},
		UnlockedCollectionIds = {},
	}

	if catalog then
		result.FavoriteTrackIds = MusicPersistence.sanitizeIdSet(source.FavoriteTrackIds, function(id)
			local track = catalog:getTrack(id)
			return track ~= nil and track.favoriteEnabled ~= false
		end, config.maxFavorites, "FavoriteTrackIds", rejections)

		result.EncounteredCueIds = MusicPersistence.sanitizeIdSet(source.EncounteredCueIds, function(id)
			return catalog:getCue(id) ~= nil
		end, nil, "EncounteredCueIds", rejections)

		result.UnlockedCollectionIds = MusicPersistence.sanitizeIdSet(source.UnlockedCollectionIds, function(id)
			return catalog:getCollection(id) ~= nil
		end, nil, "UnlockedCollectionIds", rejections)

		result.QueueResume = MusicPersistence.sanitizeQueueResume(source.QueueResume, {
			catalog = catalog,
			unlocks = options.unlocks,
			isPlayable = options.isPlayable,
			now = options.now,
			config = config,
			rejections = rejections,
		})
	end

	return result, rejections
end

-- Reset All Settings clears preferences only: favorites, encountered music,
-- permanent collection unlocks, and the short-lived snapshot survive.
function MusicPersistence.resetPreferences(existing)
	local source = type(existing) == "table" and existing or {}
	return {
		Preferences = MusicPersistence.defaults().Preferences,
		FavoriteTrackIds = source.FavoriteTrackIds or {},
		EncounteredCueIds = source.EncounteredCueIds or {},
		UnlockedCollectionIds = source.UnlockedCollectionIds or {},
		QueueResume = source.QueueResume,
	}
end

-- Rate limit for position-only refreshes. A meaningful playback or queue change
-- sends immediately; a moving playhead waits out the interval.
function MusicPersistence.shouldSendSnapshot(lastSentAt, now, changed, config)
	config = config or MusicConfig.new()
	if changed then
		return true
	end
	if not isFinite(lastSentAt) then
		return true
	end
	return isFinite(now) and (now - lastSentAt) >= config.snapshotPositionSeconds
end

return MusicPersistence
