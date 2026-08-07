-- MusicUnlocks -- the engine's unlock resolver.
--
-- The core must never read ClickGame progression, so the game hands it a plain
-- context: which unlock rules the current run has granted, which collections are
-- permanently discovered, which cues have been encountered, and a progression
-- number for pool gating. A reusing game either fills the same context or
-- replaces individual rule evaluators through options.rules.
--
-- Two deliberate asymmetries come straight from docs/music.md:
--   * Permanent collection unlocks survive rebirth, so a discovered collection
--     stays browsable and queueable even when the current run has no grant.
--   * Ambient pools follow current-run grants, because Story Mix weighting is
--     current-run context. Discovery never removes music, it only stops
--     automatic selection from drawing on a floor this run has not reached.

local MusicTypes = require(script.Parent.MusicTypes)

local MusicUnlocks = {}
MusicUnlocks.__index = MusicUnlocks

local EMPTY = table.freeze({})

local function toSet(value)
	local result = {}
	if type(value) ~= "table" then
		return result
	end
	for key, entry in pairs(value) do
		if type(key) == "number" then
			if type(entry) == "string" then
				result[entry] = true
			end
		elseif entry then
			result[key] = true
		end
	end
	return result
end

local function normalizeContext(context)
	local source = type(context) == "table" and context or EMPTY
	return {
		grants = toSet(source.grants),
		progression = tonumber(source.progression) or 0,
		encounteredCueIds = toSet(source.encounteredCueIds),
		unlockedCollectionIds = toSet(source.unlockedCollectionIds),
		permanentPoolIds = toSet(source.permanentPoolIds),
	}
end

function MusicUnlocks.new(catalog, options)
	assert(catalog, "MusicUnlocks.new requires a catalog")
	return setmetatable({
		_catalog = catalog,
		_rules = options and options.rules or nil,
		_context = normalizeContext(nil),
	}, MusicUnlocks)
end

function MusicUnlocks:setContext(context)
	self._context = normalizeContext(context)
	return self._context
end

-- Merges one or more fields without disturbing the rest of the context.
function MusicUnlocks:update(partial)
	if type(partial) ~= "table" then
		return self._context
	end
	local merged = {
		grants = partial.grants ~= nil and partial.grants or self._context.grants,
		progression = partial.progression ~= nil and partial.progression or self._context.progression,
		encounteredCueIds = partial.encounteredCueIds ~= nil and partial.encounteredCueIds
			or self._context.encounteredCueIds,
		unlockedCollectionIds = partial.unlockedCollectionIds ~= nil and partial.unlockedCollectionIds
			or self._context.unlockedCollectionIds,
		permanentPoolIds = partial.permanentPoolIds ~= nil and partial.permanentPoolIds
			or self._context.permanentPoolIds,
	}
	self._context = normalizeContext(merged)
	return self._context
end

function MusicUnlocks:getContext()
	return self._context
end

function MusicUnlocks:getProgression()
	return self._context.progression
end

function MusicUnlocks:isCueEncountered(cueId)
	return self._context.encounteredCueIds[cueId] == true
end

function MusicUnlocks:noteCueEncountered(cueId)
	if type(cueId) == "string" then
		self._context.encounteredCueIds[cueId] = true
	end
end

function MusicUnlocks:noteCollectionUnlocked(collectionId)
	if type(collectionId) == "string" then
		self._context.unlockedCollectionIds[collectionId] = true
	end
end

-- Evaluates one unlock rule token. A game may override any of these.
function MusicUnlocks:isRuleGranted(rule, subject)
	local override = self._rules and self._rules[rule]
	if override then
		return override(self._context, subject, self) == true
	end

	if rule == MusicTypes.UnlockRule.Always then
		return true
	elseif rule == MusicTypes.UnlockRule.NotBrowsable or rule == MusicTypes.UnlockRule.ContextualOnly then
		-- Contextual pools are reachable only when the director asks for them by
		-- id (post-story recovery); they never enter ordinary eligibility.
		return false
	elseif rule == MusicTypes.UnlockRule.StoryEncounter then
		return false
	end

	return self._context.grants[rule] == true
end

function MusicUnlocks:isCollectionBrowsable(collectionId)
	local collection = self._catalog:getCollection(collectionId)
	return collection ~= nil and collection.unlockRule ~= MusicTypes.UnlockRule.NotBrowsable
end

function MusicUnlocks:isCollectionUnlocked(collectionId)
	local collection = self._catalog:getCollection(collectionId)
	if not collection then
		return false
	end
	if self._context.unlockedCollectionIds[collectionId] then
		return true
	end
	if collection.unlockRule == MusicTypes.UnlockRule.StoryEncounter then
		-- A story collection opens as soon as one of its scenes has completed.
		for _, trackId in ipairs(collection.trackIds or EMPTY) do
			if self:isTrackDiscovered(trackId) then
				return true
			end
		end
		return false
	end
	return self:isRuleGranted(collection.unlockRule, collection)
end

-- Story-locked recordings stay hidden until one of their cues has been
-- encountered, so browsing cannot spoil an active scene.
function MusicUnlocks:isTrackDiscovered(trackId)
	local track = self._catalog:getTrack(trackId)
	if not track then
		return false
	end
	if not track.storyLocked then
		return true
	end
	for _, cueId in ipairs(self._catalog:getRevealingCueIds(trackId)) do
		if self:isCueEncountered(cueId) then
			return true
		end
	end
	return false
end

-- Playable means the player may queue or play it directly.
function MusicUnlocks:isTrackPlayable(trackId)
	local track = self._catalog:getTrack(trackId)
	if not track or not self._catalog:isTrackAvailable(trackId) then
		return false
	end
	if not self:isCollectionBrowsable(track.collectionId) then
		return false
	end
	if not self:isTrackDiscovered(trackId) then
		return false
	end
	return self:isCollectionUnlocked(track.collectionId)
end

function MusicUnlocks:isPoolEligible(poolId)
	local pool = self._catalog:getPool(poolId)
	if not pool then
		return false
	end
	if self._context.permanentPoolIds[poolId] then
		return true
	end
	return self:isRuleGranted(pool.unlockRule, pool)
end

-- Automatic selection additionally honours the pool row's progression gate.
function MusicUnlocks:isEntrySelectable(entry)
	if not entry or not self:isTrackPlayable(entry.trackId) then
		return false
	end
	local minimum = tonumber(entry.minimumProgression)
	if minimum and self._context.progression < minimum then
		return false
	end
	return true
end

function MusicUnlocks:listPlayableTracks()
	local result = {}
	for _, track in ipairs(self._catalog:getTracks()) do
		if self:isTrackPlayable(track.id) then
			table.insert(result, track.id)
		end
	end
	return result
end

-- Browse state for one collection: locked collections stay visible with their
-- unlock copy, which is why this returns a row rather than a boolean.
function MusicUnlocks:getCollectionState(collectionId)
	local collection = self._catalog:getCollection(collectionId)
	if not collection then
		return nil
	end
	local unlocked = self:isCollectionUnlocked(collectionId)
	local tracks = {}
	if unlocked then
		for _, trackId in ipairs(collection.trackIds or EMPTY) do
			if self:isTrackPlayable(trackId) then
				table.insert(tracks, trackId)
			end
		end
	end
	return {
		id = collection.id,
		displayName = collection.displayName,
		nameKey = collection.nameKey,
		unlockRule = collection.unlockRule,
		unlockCopyKey = collection.unlockCopyKey,
		artworkAssetId = collection.artworkAssetId,
		browsable = self:isCollectionBrowsable(collectionId),
		unlocked = unlocked,
		trackIds = tracks,
	}
end

return MusicUnlocks
