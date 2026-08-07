-- MusicCatalog -- typed read-only wrapper around MusicCatalog.generated.lua.
--
-- The generated module is flat data. This wrapper indexes it once, resolves cue
-- chains and playback regions, and is the only module that knows the generated
-- file exists. It never mutates the underlying tables, so several catalogs (the
-- shipped one, a fixture, another game's) can coexist in one process.

local MusicTypes = require(script.Parent.MusicTypes)

local MusicCatalog = {}
MusicCatalog.__index = MusicCatalog

MusicCatalog.SupportedFormatVersion = 1

local EMPTY = table.freeze({})

local function indexById(rows)
	local byId = {}
	for _, row in ipairs(rows or EMPTY) do
		byId[row.id] = row
	end
	return byId
end

function MusicCatalog.new(data)
	assert(type(data) == "table", "MusicCatalog.new requires generated catalog data")
	assert(
		data.formatVersion == MusicCatalog.SupportedFormatVersion,
		("MusicCatalog format version %s is not supported (expected %d)")
			:format(tostring(data.formatVersion), MusicCatalog.SupportedFormatVersion)
	)

	local self = setmetatable({
		_data = data,
		mode = data.mode,
		experienceId = data.experienceId,
		inputDigest = data.inputDigest,
	}, MusicCatalog)

	self._tracks = indexById(data.tracks)
	self._collections = indexById(data.collections)
	self._pools = indexById(data.pools)
	self._cues = indexById(data.cues)
	self._poolsByTrack = {}
	self._revealCues = {}
	self._chains = {}

	for _, pool in ipairs(data.pools or EMPTY) do
		for _, entry in ipairs(pool.entries or EMPTY) do
			local list = self._poolsByTrack[entry.trackId]
			if not list then
				list = {}
				self._poolsByTrack[entry.trackId] = list
			end
			table.insert(list, pool.id)
		end
	end

	for _, cue in ipairs(data.cues or EMPTY) do
		local primary, fallback = {}, {}
		for _, assignment in ipairs(cue.assignments or EMPTY) do
			if assignment.role == MusicTypes.AssignmentRole.Fallback then
				table.insert(fallback, assignment)
			else
				table.insert(primary, assignment)
			end

			local reveals = self._revealCues[assignment.trackId]
			if not reveals then
				reveals = {}
				self._revealCues[assignment.trackId] = reveals
			end
			reveals[cue.id] = true
		end

		local function bySequence(a, b)
			return a.sequenceOrder < b.sequenceOrder
		end
		table.sort(primary, bySequence)
		table.sort(fallback, bySequence)
		self._chains[cue.id] = { Primary = primary, Fallback = fallback }
	end

	return self
end

-- Convenience loader for the shipped catalog. Kept lazy so requiring this module
-- costs nothing in tests or in a game that supplies its own data.
function MusicCatalog.default()
	if not MusicCatalog._default then
		MusicCatalog._default = MusicCatalog.new(require(script.Parent["MusicCatalog.generated"]))
	end
	return MusicCatalog._default
end

function MusicCatalog:getMode()
	return self.mode
end

function MusicCatalog:getCredits()
	return self._data.credits or EMPTY
end

function MusicCatalog:getTrack(trackId)
	return trackId and self._tracks[trackId] or nil
end

function MusicCatalog:hasTrack(trackId)
	return self:getTrack(trackId) ~= nil
end

function MusicCatalog:getTracks()
	return self._data.tracks or EMPTY
end

function MusicCatalog:getCollection(collectionId)
	return collectionId and self._collections[collectionId] or nil
end

function MusicCatalog:getCollections()
	return self._data.collections or EMPTY
end

function MusicCatalog:getPool(poolId)
	return poolId and self._pools[poolId] or nil
end

function MusicCatalog:getPools()
	return self._data.pools or EMPTY
end

function MusicCatalog:getPoolEntries(poolId)
	local pool = self:getPool(poolId)
	return pool and pool.entries or EMPTY
end

function MusicCatalog:getCue(cueId)
	return cueId and self._cues[cueId] or nil
end

function MusicCatalog:getCues()
	return self._data.cues or EMPTY
end

-- Ordered assignments for one chain. "Primary" returns the primary recording
-- followed by its continuations; "Fallback" is the separate fallback chain.
function MusicCatalog:getCueChain(cueId, role)
	local chains = self._chains[cueId]
	if not chains then
		return EMPTY
	end
	if role == MusicTypes.AssignmentRole.Fallback then
		return chains.Fallback
	end
	return chains.Primary
end

function MusicCatalog:getTrackPools(trackId)
	return self._poolsByTrack[trackId] or EMPTY
end

-- Cue ids whose approved assignments include this recording. A story-locked
-- track becomes browsable once one of them has been encountered.
function MusicCatalog:getRevealingCueIds(trackId)
	local reveals = self._revealCues[trackId]
	if not reveals then
		return EMPTY
	end
	local result = {}
	for cueId in pairs(reveals) do
		table.insert(result, cueId)
	end
	table.sort(result)
	return result
end

function MusicCatalog:getCollectionTracks(collectionId)
	local collection = self:getCollection(collectionId)
	return collection and collection.trackIds or EMPTY
end

-- A recording only reaches playback when the build carries its asset id.
function MusicCatalog:isTrackAvailable(trackId)
	local track = self:getTrack(trackId)
	return track ~= nil and type(track.assetId) == "number"
end

function MusicCatalog:isEmpty()
	return #self:getTracks() == 0
end

function MusicCatalog:getPlaybackRegion(trackId)
	local track = self:getTrack(trackId)
	if not track then
		return nil, nil
	end
	local from = track.playbackStartSeconds or 0
	local to = track.playbackEndSeconds or track.durationSeconds
	return from, to
end

function MusicCatalog:getLoopRegion(trackId)
	local track = self:getTrack(trackId)
	if not track or track.loopStartSeconds == nil or track.loopEndSeconds == nil then
		return nil, nil
	end
	return track.loopStartSeconds, track.loopEndSeconds
end

-- Playable length of the authored region, not the raw file length.
function MusicCatalog:getDuration(trackId)
	local from, to = self:getPlaybackRegion(trackId)
	if not from or not to then
		return nil
	end
	return math.max(to - from, 0)
end

-- Absolute start position for a cue-point offset measured from the playback
-- region, so an authored trim and a cue start compose instead of fighting.
function MusicCatalog:resolveStart(trackId, offsetSeconds)
	local from, to = self:getPlaybackRegion(trackId)
	if not from then
		return 0
	end
	local start = from + math.max(tonumber(offsetSeconds) or 0, 0)
	if to then
		start = math.min(start, to)
	end
	return start
end

-- Clamps a resumed or seeked position into the usable region. A position is a
-- number or it is nothing: coercing "42" here would let a numeric string from a
-- remote message pass as a validated playback position.
function MusicCatalog:clampPosition(trackId, positionSeconds)
	local from, to = self:getPlaybackRegion(trackId)
	local value = type(positionSeconds) == "number" and positionSeconds or 0
	if value ~= value or value == math.huge or value == -math.huge then
		value = 0
	end
	if not from then
		return math.max(value, 0)
	end
	value = math.max(value, from)
	if to then
		value = math.min(value, to)
	end
	return value
end

-- Measured normalization converted to linear gain, with the positive-gain cap
-- from engine policy applied.
function MusicCatalog:getGain(trackId, maxGainDb)
	local track = self:getTrack(trackId)
	local db = track and track.normalizedVolumeDb or 0
	local cap = tonumber(maxGainDb) or 6
	return 10 ^ (math.min(db, cap) / 20)
end

function MusicCatalog:getVolumeDb(trackId, maxGainDb)
	local track = self:getTrack(trackId)
	local db = track and track.normalizedVolumeDb or 0
	return math.min(db, tonumber(maxGainDb) or 6)
end

return MusicCatalog
