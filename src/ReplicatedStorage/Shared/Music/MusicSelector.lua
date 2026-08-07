-- MusicSelector -- contextual automatic selection: the shuffled bag.
--
-- Automatic music is drawn without replacement from a bag of eligible entries
-- rather than by independent random rolls, so the same song cannot land twice in
-- a row while eight others wait. On top of the bag it applies the policy from
-- docs/music.md: per-entry recency exclusion, station lane bias, energy
-- smoothing, a temporary boost for newly unlocked floor music, a post-story
-- recovery pool, and session quarantine for assets that failed to load.
--
-- Selection state is one plain table, and the random source is clonable, so
-- preview() can look N picks into the future without disturbing live state. That
-- also makes preview()[1] exactly what the next select() returns while nothing
-- else changes, which is what makes Up Next honest instead of decorative.

local MusicTypes = require(script.Parent.MusicTypes)
local MusicConfig = require(script.Parent.MusicConfig)
local MusicRandom = require(script.Parent.MusicRandom)

local MusicSelector = {}
MusicSelector.__index = MusicSelector

function MusicSelector.new(options)
	assert(type(options) == "table", "MusicSelector.new requires options")
	assert(options.catalog, "MusicSelector requires a catalog")
	assert(options.unlocks, "MusicSelector requires an unlock resolver")

	local self = setmetatable({
		_catalog = options.catalog,
		_unlocks = options.unlocks,
		_config = options.config or MusicConfig.new(),
		_source = { kind = MusicTypes.SourceKind.Station, id = MusicTypes.Vibe.StoryMix },
		_vibe = MusicTypes.Vibe.StoryMix,
		_shuffleEnabled = true,
		_recoveryPoolId = nil,
		_quarantine = {},
		_state = nil,
	}, MusicSelector)

	self._state = {
		random = options.random or MusicRandom.new(options.seed),
		bag = {},
		bagKey = nil,
		history = {},
		boosts = {},
		recoveryRemaining = 0,
		lastLane = nil,
		lastEnergy = nil,
		cursor = 0,
	}

	self._trackOrder = {}
	for index, track in ipairs(self._catalog:getTracks()) do
		self._trackOrder[track.id] = index
	end

	return self
end

--[[ Source and preferences ]]

function MusicSelector:setSource(kind, id)
	kind = kind or MusicTypes.SourceKind.Station
	if self._source.kind == kind and self._source.id == id then
		return false
	end
	self._source = { kind = kind, id = id }
	self._state.bagKey = nil
	self._state.cursor = 0
	return true
end

function MusicSelector:getSource()
	return self._source.kind, self._source.id
end

function MusicSelector:setVibe(vibe)
	if not MusicTypes.Vibe[vibe] or self._vibe == vibe then
		return false
	end
	self._vibe = vibe
	if self._source.kind == MusicTypes.SourceKind.Station then
		self._source = { kind = MusicTypes.SourceKind.Station, id = vibe }
	end
	return true
end

function MusicSelector:getVibe()
	return self._vibe
end

function MusicSelector:setShuffleEnabled(enabled)
	enabled = enabled and true or false
	if self._shuffleEnabled == enabled then
		return false
	end
	self._shuffleEnabled = enabled
	self._state.cursor = 0
	return true
end

function MusicSelector:isShuffleEnabled()
	return self._shuffleEnabled
end

--[[ Context notes ]]

-- Newly unlocked floor music is preferred for a few picks after its reveal.
function MusicSelector:noteUnlock(poolId, now)
	if not self._catalog:getPool(poolId) then
		return false
	end
	self._state.boosts[poolId] = {
		remaining = self._config.unlockBoostSelections,
		expiresAt = (tonumber(now) or 0) + self._config.unlockBoostSeconds,
	}
	return true
end

-- After a somber or tense cue the next picks come from its recovery pool rather
-- than jumping straight back to maximum-energy playful music.
function MusicSelector:setRecoveryPool(poolId, selections)
	if not self._catalog:getPool(poolId) then
		return false
	end
	self._recoveryPoolId = poolId
	self._state.recoveryRemaining = math.max(tonumber(selections) or self._config.recoverySelections, 0)
	self._state.bagKey = nil
	return true
end

function MusicSelector:clearRecovery()
	self._recoveryPoolId = nil
	self._state.recoveryRemaining = 0
end

function MusicSelector:isRecovering()
	return self._state.recoveryRemaining > 0 and self._recoveryPoolId ~= nil
end

-- Called for every non-story recording that starts, whichever module chose it.
function MusicSelector:notePlayed(trackId)
	if type(trackId) ~= "string" then
		return
	end
	local state = self._state
	if state.history[1] == trackId then
		return
	end
	self:_remember(state, trackId)
end

function MusicSelector:quarantine(trackId)
	if type(trackId) == "string" then
		self._quarantine[trackId] = true
	end
end

function MusicSelector:isQuarantined(trackId)
	return self._quarantine[trackId] == true
end

function MusicSelector:clearQuarantine()
	self._quarantine = {}
end

function MusicSelector:getHistory()
	local result = {}
	for index, trackId in ipairs(self._state.history) do
		result[index] = trackId
	end
	return result
end

function MusicSelector:reset()
	local state = self._state
	state.bag = {}
	state.bagKey = nil
	state.history = {}
	state.boosts = {}
	state.recoveryRemaining = 0
	state.lastLane = nil
	state.lastEnergy = nil
	state.cursor = 0
	self._recoveryPoolId = nil
end

--[[ Selection ]]

function MusicSelector:select(now)
	local state = self._state
	local entry = self:_pick(state, now or 0)
	if not entry then
		return nil
	end
	self:_commit(state, entry, now or 0)
	return entry.trackId
end

-- Non-mutating look ahead used for the Up Next tail.
function MusicSelector:preview(count, now)
	local state = self:_cloneState(self._state)
	local result = {}
	for _ = 1, math.max(tonumber(count) or 0, 0) do
		local entry = self:_pick(state, now or 0)
		if not entry then
			break
		end
		self:_commit(state, entry, now or 0)
		table.insert(result, entry.trackId)
	end
	return result
end

-- True when nothing at all is selectable right now (empty catalog build, no
-- unlocked pools, everything quarantined).
function MusicSelector:hasEligibleTrack()
	local entries = self:_universe(self._state)
	for _, entry in ipairs(entries) do
		if not self:isQuarantined(entry.trackId) then
			return true
		end
	end
	return false
end

--[[ Internals ]]

function MusicSelector:_cloneState(state)
	local bag = {}
	for trackId in pairs(state.bag) do
		bag[trackId] = true
	end
	local history = {}
	for index, trackId in ipairs(state.history) do
		history[index] = trackId
	end
	local boosts = {}
	for poolId, boost in pairs(state.boosts) do
		boosts[poolId] = { remaining = boost.remaining, expiresAt = boost.expiresAt }
	end
	return {
		random = state.random:clone(),
		bag = bag,
		bagKey = state.bagKey,
		history = history,
		boosts = boosts,
		recoveryRemaining = state.recoveryRemaining,
		lastLane = state.lastLane,
		lastEnergy = state.lastEnergy,
		cursor = state.cursor,
	}
end

function MusicSelector:_remember(state, trackId)
	table.insert(state.history, 1, trackId)
	local limit = math.max(self._config.historyLimit, self._config.defaultRecencyExclusion) + 8
	while #state.history > limit do
		table.remove(state.history)
	end
	local track = self._catalog:getTrack(trackId)
	if track then
		state.lastLane = track.audienceLane
		state.lastEnergy = track.energy
	end
end

function MusicSelector:_poolUniverse(poolIds, ignoreEligibility)
	local entries, seen = {}, {}
	for _, poolId in ipairs(poolIds) do
		if ignoreEligibility or self._unlocks:isPoolEligible(poolId) then
			for _, entry in ipairs(self._catalog:getPoolEntries(poolId)) do
				if self._unlocks:isEntrySelectable(entry) then
					local existing = seen[entry.trackId]
					local weight = tonumber(entry.weight) or 1
					if existing then
						if weight > existing.weight then
							existing.weight = weight
							existing.poolId = poolId
						end
						existing.recencyExclusion = math.max(
							existing.recencyExclusion,
							tonumber(entry.recencyExclusion) or self._config.defaultRecencyExclusion
						)
					else
						local record = {
							trackId = entry.trackId,
							weight = weight,
							recencyExclusion = tonumber(entry.recencyExclusion)
								or self._config.defaultRecencyExclusion,
							poolId = poolId,
						}
						seen[entry.trackId] = record
						table.insert(entries, record)
					end
				end
			end
		end
	end
	return entries
end

function MusicSelector:_collectionUniverse(collectionId)
	local entries = {}
	for _, trackId in ipairs(self._catalog:getCollectionTracks(collectionId)) do
		if self._unlocks:isTrackPlayable(trackId) then
			table.insert(entries, {
				trackId = trackId,
				weight = 1,
				recencyExclusion = self._config.defaultRecencyExclusion,
				poolId = nil,
			})
		end
	end
	return entries
end

function MusicSelector:_universe(state)
	if state.recoveryRemaining > 0 and self._recoveryPoolId then
		local entries = self:_poolUniverse({ self._recoveryPoolId }, true)
		-- A recovery pool that is empty or entirely quarantined must not strand
		-- automatic selection: fall through to the ordinary source instead.
		for _, entry in ipairs(entries) do
			if not self:isQuarantined(entry.trackId) then
				return entries, "recovery:" .. self._recoveryPoolId
			end
		end
	end

	local kind, id = self._source.kind, self._source.id
	if kind == MusicTypes.SourceKind.Pool then
		return self:_poolUniverse({ id }, true), "pool:" .. tostring(id)
	elseif kind == MusicTypes.SourceKind.Collection then
		return self:_collectionUniverse(id), "collection:" .. tostring(id)
	end

	local poolIds = {}
	for _, pool in ipairs(self._catalog:getPools()) do
		if self._unlocks:isPoolEligible(pool.id) then
			table.insert(poolIds, pool.id)
		end
	end
	return self:_poolUniverse(poolIds, true), "station:" .. table.concat(poolIds, ",")
end

function MusicSelector:_isRecent(state, trackId, exclusion)
	local limit = math.min(math.max(tonumber(exclusion) or 0, 0), #state.history)
	for index = 1, limit do
		if state.history[index] == trackId then
			return true
		end
	end
	return false
end

function MusicSelector:_filter(entries, state, useBag, useRecency)
	local result = {}
	for _, entry in ipairs(entries) do
		local keep = not self:isQuarantined(entry.trackId)
		if keep and useBag and not state.bag[entry.trackId] then
			keep = false
		end
		if keep and useRecency and self:_isRecent(state, entry.trackId, entry.recencyExclusion) then
			keep = false
		end
		if keep then
			table.insert(result, entry)
		end
	end
	return result
end

function MusicSelector:_weightOf(entry, state, now)
	local track = self._catalog:getTrack(entry.trackId)
	if not track then
		return 0
	end

	local weight = math.max(tonumber(entry.weight) or 1, 0)

	local laneWeights = self._config.laneWeights[self._vibe] or self._config.laneWeights.StoryMix
	weight = weight * (tonumber(laneWeights[track.audienceLane]) or 1)

	if
		self._vibe == MusicTypes.Vibe.Balanced
		and state.lastLane
		and track.audienceLane == state.lastLane
		and track.audienceLane ~= MusicTypes.AudienceLane.Crossover
	then
		weight = weight * (tonumber(self._config.balancedRepeatLaneWeight) or 1)
	end

	local lastRank = state.lastEnergy and tonumber(self._config.energyRank[state.lastEnergy])
	local rank = track.energy and tonumber(self._config.energyRank[track.energy])
	if lastRank and rank and math.abs(rank - lastRank) >= 2 then
		weight = weight * (tonumber(self._config.energyPenalty) or 1)
	end

	local boost = entry.poolId and state.boosts[entry.poolId]
	if boost and boost.remaining > 0 and now < boost.expiresAt then
		weight = weight * (tonumber(self._config.unlockBoostMultiplier) or 1)
	end

	return math.max(weight, 0)
end

function MusicSelector:_bagHasAny(state, entries)
	for _, entry in ipairs(entries) do
		if state.bag[entry.trackId] and not self:isQuarantined(entry.trackId) then
			return true
		end
	end
	return false
end

function MusicSelector:_refillBag(state, entries)
	state.bag = {}
	for _, entry in ipairs(entries) do
		state.bag[entry.trackId] = true
	end
end

function MusicSelector:_orderedEntries(entries)
	local ordered = table.clone(entries)
	local order = self._trackOrder
	table.sort(ordered, function(a, b)
		local rankA = order[a.trackId] or math.huge
		local rankB = order[b.trackId] or math.huge
		if rankA == rankB then
			return a.trackId < b.trackId
		end
		return rankA < rankB
	end)
	return ordered
end

function MusicSelector:_pickSequential(state, entries)
	local ordered = self:_orderedEntries(entries)
	local count = #ordered
	if count == 0 then
		return nil
	end
	for offset = 1, count do
		local index = ((state.cursor + offset - 1) % count) + 1
		local entry = ordered[index]
		if not self:isQuarantined(entry.trackId) then
			state.cursor = index
			return entry
		end
	end
	return nil
end

function MusicSelector:_pick(state, now)
	local entries, key = self:_universe(state)
	if #entries == 0 then
		return nil
	end

	if state.bagKey ~= key then
		state.bagKey = key
		state.cursor = 0
		self:_refillBag(state, entries)
	elseif not self:_bagHasAny(state, entries) then
		self:_refillBag(state, entries)
	end

	if not self._shuffleEnabled then
		return self:_pickSequential(state, entries)
	end

	local candidates = self:_filter(entries, state, true, true)
	if #candidates == 0 then
		candidates = self:_filter(entries, state, false, true)
	end
	if #candidates == 0 then
		candidates = self:_filter(entries, state, false, false)
	end
	if #candidates == 0 then
		return nil
	end

	local weights, total = {}, 0
	for index, entry in ipairs(candidates) do
		local weight = self:_weightOf(entry, state, now)
		weights[index] = weight
		total = total + weight
	end

	if total <= 0 then
		return candidates[state.random:nextInteger(1, #candidates)]
	end

	local roll = state.random:nextNumber() * total
	local accumulated = 0
	for index, entry in ipairs(candidates) do
		accumulated = accumulated + weights[index]
		if roll <= accumulated then
			return entry
		end
	end
	return candidates[#candidates]
end

function MusicSelector:_commit(state, entry, now)
	state.bag[entry.trackId] = nil
	self:_remember(state, entry.trackId)

	if state.recoveryRemaining > 0 then
		state.recoveryRemaining = state.recoveryRemaining - 1
	end

	for poolId, boost in pairs(state.boosts) do
		if now >= boost.expiresAt then
			state.boosts[poolId] = nil
		elseif poolId == entry.poolId then
			boost.remaining = boost.remaining - 1
			if boost.remaining <= 0 then
				state.boosts[poolId] = nil
			end
		end
	end
end

return MusicSelector
