-- MusicDirector -- the pure Orbit Radio playback director.
--
-- Owns the five music states, cue priority and presentation ownership, story
-- interruption and resume, load generations, and the immutable view state the UI
-- observes. It touches no audio instance: sound goes through the injected
-- MusicPlaybackBackend, and the clock, random source, catalog, unlock facts, and
-- persistence all arrive as injections, so the whole engine runs deterministically
-- in a plain Luau process with no Roblox globals.
--
-- The engine is synchronous. Nothing here yields, waits, or spawns: a backend
-- reports progress by calling notifyStarted/notifyEnded/notifyFailed with the
-- generation token it was given, and the host calls update() on a heartbeat to
-- age out load timeouts. Every asynchronous outcome is therefore a plain method
-- call that a test can make by hand.
--
-- Contracts that are easy to get wrong, stated once:
--   * A queue owns ambient time; a story cue only borrows it, then gives it back.
--   * requestCue is idempotent per requestId, and only the owner of the active
--     requestId can release or replace it. Equal-priority replacement is proved by
--     replacesRequestId or a shared ownerId, never by the flag alone.
--   * Only a completion release reason counts a moment as encountered.
--   * Story Moments off still counts the moment and still applies its progression
--     side effects; it only declines the takeover.
--   * MusicEnabled is a mute, not a pause: deck timing keeps running.
--   * A callback from an older generation can never mutate current state.
--   * Positions are absolute recording seconds inside the engine and the backend
--     request; every published or accepted position is elapsed time measured from
--     the playback region start.

local MusicTypes = require(script.Parent.MusicTypes)
local MusicConfig = require(script.Parent.MusicConfig)
local MusicQueue = require(script.Parent.MusicQueue)
local MusicSelector = require(script.Parent.MusicSelector)
local MusicUnlocks = require(script.Parent.MusicUnlocks)
local MusicRandom = require(script.Parent.MusicRandom)
local NullPlaybackBackend = require(script.Parent.NullPlaybackBackend)

local MusicDirector = {}
MusicDirector.__index = MusicDirector

local State = MusicTypes.State
local Source = MusicTypes.Source
local CueClass = MusicTypes.CueClass
local CueResult = MusicTypes.CueResult
local Command = MusicTypes.CommandResult
local Diagnostic = MusicTypes.Diagnostic
local Reason = MusicTypes.ReleaseReason
local Role = MusicTypes.AssignmentRole
local LoopMode = MusicTypes.LoopMode
local EndBehavior = MusicTypes.EndBehavior
local RepeatMode = MusicTypes.RepeatMode
local UnlockRule = MusicTypes.UnlockRule

MusicDirector.State = State
MusicDirector.CueResult = CueResult
MusicDirector.CommandResult = Command

local EMPTY = table.freeze({})

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function MusicDirector.new(options)
	assert(type(options) == "table", "MusicDirector.new requires options")
	assert(options.catalog, "MusicDirector requires a catalog")

	local config = MusicConfig.new(options.config)
	local catalog = options.catalog
	local unlocks = options.unlocks or MusicUnlocks.new(catalog, options.unlockOptions)
	local random = options.random or MusicRandom.new(options.seed)
	local selector = options.selector
		or MusicSelector.new({ catalog = catalog, unlocks = unlocks, config = config, random = random })
	local queue = options.queue or MusicQueue.new(config)
	local backend = options.backend or NullPlaybackBackend.new()

	local self = setmetatable({
		_catalog = catalog,
		_unlocks = unlocks,
		_selector = selector,
		_queue = queue,
		_backend = backend,
		_config = config,
		_now = options.now or os.clock,
		_onDiagnostic = options.onDiagnostic,
		_onCueEncountered = options.onCueEncountered,
		_onSnapshotDirty = options.onSnapshotDirty,

		_state = State.Stopped,
		_current = nil,
		_pending = nil,
		_generation = 0,

		_requests = {},
		_story = nil,
		_stinger = nil,
		_retainedCue = nil,
		_pendingRestore = nil,
		_resumeAfterStory = nil,

		_hydratedSettings = false,
		_hydratedPreferences = false,
		_userStopped = false,

		_musicEnabled = true,
		_volume = 1,
		_storyMomentsEnabled = true,

		_subscribers = {},
		_viewVersion = 0,
		_view = nil,
		_upNext = EMPTY,

		_metrics = {
			loadsStarted = 0,
			loadsFailed = 0,
			loadTimeouts = 0,
			fallbacksUsed = 0,
			cuesSuppressed = 0,
			skips = 0,
			resumesRestored = 0,
			resumesRejected = 0,
			tracksQuarantined = 0,
		},
	}, MusicDirector)

	if type(backend.bind) == "function" then
		backend:bind({
			onStarted = function(generation)
				return self:notifyStarted(generation)
			end,
			onEnded = function(generation)
				return self:notifyEnded(generation)
			end,
			onFailed = function(generation, reason)
				return self:notifyFailed(generation, reason)
			end,
			onStingerEnded = function(generation)
				return self:notifyStingerEnded(generation)
			end,
		})
	end

	self:_refreshUpNext()
	self:_publish()
	return self
end

--[[ Accessors ]]

function MusicDirector:getCatalog()
	return self._catalog
end

function MusicDirector:getQueue()
	return self._queue
end

function MusicDirector:getSelector()
	return self._selector
end

function MusicDirector:getUnlocks()
	return self._unlocks
end

function MusicDirector:getState()
	return self._state
end

function MusicDirector:getMetrics()
	return table.clone(self._metrics)
end

function MusicDirector:isHydrated()
	return self._hydratedSettings and self._hydratedPreferences
end

--[[ Internals: plumbing ]]

function MusicDirector:_clock()
	return self._now()
end

function MusicDirector:_backendCall(method, ...)
	local backend = self._backend
	local handler = backend and backend[method]
	if type(handler) ~= "function" then
		return nil
	end
	return handler(backend, ...)
end

function MusicDirector:_diagnose(kind, fields)
	if not self._onDiagnostic then
		return
	end
	local event = fields or {}
	event.kind = kind
	self._onDiagnostic(event)
end

function MusicDirector:_markSnapshotDirty()
	if self._onSnapshotDirty then
		self._onSnapshotDirty()
	end
end

function MusicDirector:_isPlayable(trackId)
	return type(trackId) == "string" and self._unlocks:isTrackPlayable(trackId)
end

function MusicDirector:_regionStart(trackId)
	local from = self._catalog:getPlaybackRegion(trackId)
	return from or 0
end

-- The backend's own playhead, in absolute recording seconds, or nil when it cannot
-- answer. Only the audible deck has one: a pending load has not started, and an
-- older record's generation is no longer what the backend is playing, so the
-- generation goes with the question and a mismatched answer is refused here.
function MusicDirector:_reportedPosition(record)
	if record ~= self._current or not record.generation then
		return nil
	end
	local value = self:_backendCall("getPosition", record.generation)
	if not isFiniteNumber(value) then
		return nil
	end
	return value
end

-- Keeps a reported or estimated position inside the authored region: a normal track
-- clamps at its end, a looping one wraps through its loop region instead of growing
-- without bound.
function MusicDirector:_normalizePosition(record, position)
	local from, to = self._catalog:getPlaybackRegion(record.trackId)
	from = from or 0
	if not isFiniteNumber(position) then
		return from
	end
	if record.loop then
		local loopStart, loopEnd = self._catalog:getLoopRegion(record.trackId)
		loopStart = loopStart or from
		loopEnd = loopEnd or to
		if loopEnd and loopEnd > loopStart and position > loopEnd then
			position = loopStart + math.fmod(position - loopStart, loopEnd - loopStart)
		end
		return math.max(position, from)
	end
	position = math.max(position, from)
	if to then
		position = math.min(position, to)
	end
	return position
end

-- Where the recording actually is. Real playback drifts from a wall clock through
-- loading, crossfades, pausing, and loop wrap, so the backend is asked first and the
-- director clock is only the estimate for a backend that cannot answer.
function MusicDirector:_positionOf(record)
	if not record then
		return 0
	end
	if record.paused then
		return record.pausedPosition or record.startSeconds
	end
	if not record.startedAt then
		return record.startSeconds
	end
	local reported = self:_reportedPosition(record)
	if reported then
		return self:_normalizePosition(record, reported)
	end
	return self:_normalizePosition(record, record.startSeconds + (self:_clock() - record.startedAt))
end

function MusicDirector:_elapsedOf(record)
	if not record then
		return 0
	end
	return math.max(self:_positionOf(record) - self:_regionStart(record.trackId), 0)
end

--[[ Internals: playback ]]

function MusicDirector:_buildRequest(record, channel)
	local track = self._catalog:getTrack(record.trackId)
	local from, to = self._catalog:getPlaybackRegion(record.trackId)
	local loopStart, loopEnd = self._catalog:getLoopRegion(record.trackId)
	return {
		generation = record.generation,
		channel = channel or MusicTypes.Channel.Main,
		source = record.source,
		trackId = record.trackId,
		assetId = track and track.assetId,
		cueId = record.cueId,
		startSeconds = record.startSeconds,
		playbackStartSeconds = from or 0,
		playbackEndSeconds = to,
		loopStartSeconds = loopStart,
		loopEndSeconds = loopEnd,
		loop = record.loop == true,
		crossfadeSeconds = record.crossfadeSeconds,
		volumeDb = self._catalog:getVolumeDb(record.trackId, self._config.maxNormalizationGainDb),
		paused = record.paused == true,
	}
end

function MusicDirector:_beginPlayback(descriptor)
	self._generation += 1
	local record = {
		generation = self._generation,
		trackId = descriptor.trackId,
		source = descriptor.source,
		cueId = descriptor.cueId,
		requestId = descriptor.requestId,
		startSeconds = descriptor.startSeconds or self:_regionStart(descriptor.trackId),
		loop = descriptor.loop == true,
		crossfadeSeconds = descriptor.crossfadeSeconds or self._config.defaultCrossfadeSeconds,
		paused = descriptor.paused == true,
		skipHistory = descriptor.skipHistory == true,
		retries = descriptor.retries or 0,
		fallbackAttempts = descriptor.fallbackAttempts or 0,
		requestedAt = self:_clock(),
		previous = self._current,
	}

	self._pending = record
	self._state = State.Loading
	self._metrics.loadsStarted += 1
	self:_backendCall("play", self:_buildRequest(record))

	if self._pending == record then
		self:_publish()
	end
	return record
end

function MusicDirector:_playTrack(trackId, source, options)
	if not self._catalog:isTrackAvailable(trackId) then
		return nil
	end
	options = options or {}
	return self:_beginPlayback({
		trackId = trackId,
		source = source,
		startSeconds = options.startSeconds or self._catalog:resolveStart(trackId, 0),
		crossfadeSeconds = options.crossfadeSeconds,
		paused = options.paused,
		skipHistory = options.skipHistory,
		fallbackAttempts = options.fallbackAttempts,
	})
end

function MusicDirector:_enterStopped()
	self._pending = nil
	self._current = nil
	self._state = State.Stopped
	self:_backendCall("stop", {})
	self:_publish()
end

function MusicDirector:_prepareNext()
	if type(self._backend.prepare) ~= "function" or self._state == State.Story then
		return
	end
	local nextTrackId = self._queue:peek() or self._upNext[1]
	if not nextTrackId or (self._current and nextTrackId == self._current.trackId) then
		return
	end
	if not self._catalog:isTrackAvailable(nextTrackId) then
		return
	end
	local from, to = self._catalog:getPlaybackRegion(nextTrackId)
	local track = self._catalog:getTrack(nextTrackId)
	self._backend:prepare({
		generation = 0,
		channel = MusicTypes.Channel.Main,
		trackId = nextTrackId,
		assetId = track and track.assetId,
		startSeconds = from or 0,
		playbackStartSeconds = from or 0,
		playbackEndSeconds = to,
	})
end

--[[ Backend callbacks ]]

function MusicDirector:notifyStarted(generation)
	local pending = self._pending
	if not pending or pending.generation ~= generation then
		self:_diagnose(Diagnostic.StaleCallback, { generation = generation, reason = "Started" })
		return false
	end

	local previous = pending.previous
	pending.previous = nil
	pending.startedAt = self:_clock()
	self._pending = nil
	self._current = pending
	self._state = pending.source

	if
		previous
		and previous.source ~= Source.Story
		and pending.source ~= Source.Story
		and not pending.skipHistory
		and previous.trackId ~= pending.trackId
	then
		self._queue:pushHistory(previous.trackId)
	end

	if pending.source ~= Source.Story then
		self._selector:notePlayed(pending.trackId)
	end
	if pending.paused then
		pending.pausedPosition = pending.startSeconds
		self:_backendCall("pause")
	end

	self:_refreshUpNext()
	self:_prepareNext()
	self:_markSnapshotDirty()
	self:_publish()
	return true
end

function MusicDirector:notifyEnded(generation)
	local current = self._current
	if not current or current.generation ~= generation then
		self:_diagnose(Diagnostic.StaleCallback, { generation = generation, reason = "Ended" })
		return false
	end

	if current.source == Source.Story then
		return self:_advanceStory(current)
	end

	-- Repeat One applies to manual and ambient playback, never to a story cue.
	if self._queue:getRepeatMode() == RepeatMode.One then
		return self:_playTrack(current.trackId, current.source, { skipHistory = true }) ~= nil
	end
	return self:_advanceAutomatic()
end

function MusicDirector:notifyFailed(generation, reason)
	local record
	if self._pending and self._pending.generation == generation then
		record = self._pending
	elseif self._current and self._current.generation == generation then
		record = self._current
	end
	if not record then
		self:_diagnose(Diagnostic.StaleCallback, { generation = generation, reason = "Failed" })
		return false
	end

	self._metrics.loadsFailed += 1
	self:_diagnose(Diagnostic.LoadFailed, {
		trackId = record.trackId,
		cueId = record.cueId,
		generation = generation,
		reason = reason,
	})
	return self:_handleFailure(record, reason)
end

function MusicDirector:notifyStingerEnded(generation)
	local stinger = self._stinger
	if not stinger or stinger.generation ~= generation then
		self:_diagnose(Diagnostic.StaleCallback, { generation = generation, reason = "StingerEnded" })
		return false
	end
	self._stinger = nil
	self:_backendCall("setDuck", nil)

	local record = stinger.record
	if record and self._requests[record.requestId] == record then
		self._requests[record.requestId] = nil
		record.active = false
		self:_noteEncountered(record, Reason.Completed)
	end
	self:_publish()
	return true
end

-- Called on a heartbeat. Ages out load timeouts so a cinematic never blocks
-- gameplay while waiting for audio that will not arrive.
function MusicDirector:update()
	local pending = self._pending
	if not pending then
		return false
	end
	if (self:_clock() - pending.requestedAt) < self._config.loadTimeoutSeconds then
		return false
	end
	self._metrics.loadTimeouts += 1
	self:_diagnose(Diagnostic.LoadTimeout, {
		trackId = pending.trackId,
		cueId = pending.cueId,
		generation = pending.generation,
	})
	return self:_handleFailure(pending, "Timeout")
end

--[[ Failure recovery ]]

function MusicDirector:_pickFromPool(poolId)
	for _, entry in ipairs(self._catalog:getPoolEntries(poolId)) do
		if self._catalog:isTrackAvailable(entry.trackId) and not self._selector:isQuarantined(entry.trackId) then
			return entry.trackId
		end
	end
	return nil
end

function MusicDirector:_handleFailure(record, reason)
	if self._pending == record then
		self._pending = nil
	end
	if self._current == record then
		self._current = nil
	end

	if (record.retries or 0) < self._config.loadRetryLimit then
		return self:_beginPlayback({
			trackId = record.trackId,
			source = record.source,
			cueId = record.cueId,
			requestId = record.requestId,
			startSeconds = record.startSeconds,
			loop = record.loop,
			crossfadeSeconds = record.crossfadeSeconds,
			skipHistory = true,
			retries = (record.retries or 0) + 1,
			fallbackAttempts = record.fallbackAttempts,
		}) ~= nil
	end

	if self._config.quarantineFailedTracks then
		self._selector:quarantine(record.trackId)
		self._metrics.tracksQuarantined += 1
		self:_diagnose(Diagnostic.TrackQuarantined, { trackId = record.trackId, reason = reason })
	end

	if record.source == Source.Story then
		return self:_recoverStory(record)
	end
	return self:_recoverAutomatic(record)
end

function MusicDirector:_recoverStory(record)
	local story = self._story
	if not story or story.requestId ~= record.requestId then
		self._state = self._current and self._current.source or State.Stopped
		self:_publish()
		return false
	end

	local chain = self._catalog:getCueChain(story.cueId, Role.Fallback)
	local from = (story.chainRole == Role.Fallback) and (story.chainIndex + 1) or 1
	local index = self:_firstPlayableAssignment(chain, from)
	if index then
		story.chainRole = Role.Fallback
		story.chainIndex = index
		self._metrics.fallbacksUsed += 1
		self:_diagnose(Diagnostic.FallbackUsed, { cueId = story.cueId, requestId = story.requestId })
		self:_playAssignment(story)
		return true
	end

	local poolTrackId = story.cue.fallbackPoolId and self:_pickFromPool(story.cue.fallbackPoolId)
	if poolTrackId then
		story.chainRole = nil
		story.chainIndex = nil
		self._metrics.fallbacksUsed += 1
		self:_diagnose(Diagnostic.FallbackUsed, {
			cueId = story.cueId,
			requestId = story.requestId,
			poolId = story.cue.fallbackPoolId,
		})
		self:_beginPlayback({
			trackId = poolTrackId,
			source = Source.Story,
			cueId = story.cueId,
			requestId = story.requestId,
			startSeconds = self._catalog:resolveStart(poolTrackId, 0),
			loop = story.cue.loopMode == LoopMode.Loop,
			crossfadeSeconds = story.cue.crossfadeSeconds,
		})
		return true
	end

	-- Nothing left to try: give the scene back its silence and recover.
	self:_endStory(story, Reason.Failed, true)
	return true
end

function MusicDirector:_recoverAutomatic(record)
	if (record.fallbackAttempts or 0) < self._config.fallbackAttemptLimit then
		local trackId = self._queue:takeNext()
		if trackId and not self:_isPlayable(trackId) then
			trackId = nil
		end
		trackId = trackId or self._selector:select(self:_clock())
		if trackId and self._catalog:isTrackAvailable(trackId) then
			self._metrics.fallbacksUsed += 1
			self:_diagnose(Diagnostic.FallbackUsed, { trackId = trackId })
			return self:_playTrack(trackId, record.source == Source.Manual and Source.Manual or Source.Ambient, {
				skipHistory = true,
				fallbackAttempts = (record.fallbackAttempts or 0) + 1,
			}) ~= nil
		end
	end

	self:_diagnose(Diagnostic.NoEligibleTrack, { reason = "RecoveryExhausted" })
	self:_enterStopped()
	return false
end

--[[ Automatic playback ]]

function MusicDirector:_startAutomatic()
	if not self:isHydrated() then
		return false
	end
	local trackId = self._selector:select(self:_clock())
	if not trackId then
		self:_diagnose(Diagnostic.NoEligibleTrack, { reason = "NoSelection" })
		self:_enterStopped()
		return false
	end
	return self:_playTrack(trackId, Source.Ambient) ~= nil
end

function MusicDirector:_advanceAutomatic()
	local guard = self._config.maxExplicitQueue + 1
	while guard > 0 do
		guard -= 1
		local trackId = self._queue:takeNext()
		if not trackId then
			break
		end
		if self:_isPlayable(trackId) then
			self:_markSnapshotDirty()
			return self:_playTrack(trackId, Source.Manual) ~= nil
		end
		-- A restored or stale entry that is no longer playable is discarded in order.
		self:_diagnose(Diagnostic.NoEligibleTrack, { trackId = trackId, reason = "QueueEntryInvalid" })
	end
	return self:_startAutomatic()
end

function MusicDirector:_refreshUpNext()
	self._upNext = self._selector:preview(self._config.upNextPreviewCount, self:_clock())
end

--[[ Cues ]]

function MusicDirector:_firstPlayableAssignment(chain, startIndex)
	for index = math.max(startIndex or 1, 1), #chain do
		local assignment = chain[index]
		if
			self._catalog:isTrackAvailable(assignment.trackId)
			and not self._selector:isQuarantined(assignment.trackId)
		then
			return index
		end
	end
	return nil
end

function MusicDirector:_assignmentAt(record)
	if not record.chainIndex then
		return nil
	end
	local chain = self._catalog:getCueChain(record.cueId, record.chainRole or Role.Primary)
	return chain[record.chainIndex]
end

function MusicDirector:_playAssignment(record)
	local assignment = self:_assignmentAt(record)
	if not assignment then
		return false
	end
	local cue = record.cue
	local loop = cue.loopMode == LoopMode.Loop
		or (cue.loopMode == LoopMode.LoopIfNeeded and assignment.endBehavior ~= EndBehavior.Advance)
	self:_beginPlayback({
		trackId = assignment.trackId,
		source = Source.Story,
		cueId = cue.id,
		requestId = record.requestId,
		startSeconds = self._catalog:resolveStart(assignment.trackId, assignment.startOffsetSeconds),
		loop = loop,
		crossfadeSeconds = cue.crossfadeSeconds,
	})
	return true
end

-- Progression side effects of a moment happen whether or not it takes over the
-- music, so a muted or Story-Moments-off player still gets the unlock boost.
function MusicDirector:_applyCueContext(cue)
	local pool = cue.fallbackPoolId and self._catalog:getPool(cue.fallbackPoolId)
	if not pool then
		return
	end
	if pool.unlockRule ~= UnlockRule.ContextualOnly and cue.cueClass == CueClass.MajorMilestone then
		self._selector:noteUnlock(pool.id, self:_clock())
	end
end

function MusicDirector:_captureInterrupted()
	self._resumeAfterStory = nil

	-- The newest Manual request is the selection, even while it is still loading: a
	-- Play Now, a queue entry, or a restored snapshot that a cue interrupts mid-load
	-- is still what the player chose, and dropping it would lose that choice silently.
	local record = self._pending
	if not record or record.source ~= Source.Manual then
		record = self._current
	end

	if record and record.source == Source.Manual then
		-- A manual selection resumes where it left off. An ambient track does not:
		-- the director picks a fresh contextual recording afterwards instead.
		self._resumeAfterStory = {
			trackId = record.trackId,
			position = self:_positionOf(record),
			paused = record.paused == true,
		}
	end
end

function MusicDirector:_restoreAfterStory()
	local resume = self._resumeAfterStory
	self._resumeAfterStory = nil
	if resume and self:_isPlayable(resume.trackId) then
		return self:_playTrack(resume.trackId, Source.Manual, {
			startSeconds = self._catalog:clampPosition(resume.trackId, resume.position),
			paused = resume.paused,
			skipHistory = true,
		}) ~= nil
	end
	if self._userStopped then
		self:_enterStopped()
		return false
	end
	return self:_advanceAutomatic()
end

function MusicDirector:_endStory(record, reason, restore)
	if self._story == record then
		self._story = nil
	end
	if record.played and not record.recoveryApplied then
		record.recoveryApplied = true
		local pool = record.cue.fallbackPoolId and self._catalog:getPool(record.cue.fallbackPoolId)
		if pool and pool.unlockRule == UnlockRule.ContextualOnly then
			-- A somber or tense cue hands the next picks to its recovery pool.
			self._selector:setRecoveryPool(pool.id, self._config.recoverySelections)
		end
	end
	record.lastReason = reason
	if restore then
		self:_restoreAfterStory()
	end
end

function MusicDirector:_noteEncountered(record, reason)
	self._unlocks:noteCueEncountered(record.cueId)
	if self._onCueEncountered then
		self._onCueEncountered(record.cueId, {
			requestId = record.requestId,
			reason = reason,
			played = record.played == true,
		})
	end
end

function MusicDirector:_cancelStinger()
	local stinger = self._stinger
	if not stinger then
		return false
	end
	self._stinger = nil
	self:_backendCall("stopStinger", { generation = stinger.generation })
	self:_backendCall("setDuck", nil)
	return true
end

function MusicDirector:_requestStinger(record)
	-- A higher-priority presentation owns the moment: an arc celebration must not
	-- be preceded by its own quest stingers.
	if self._story and self._story.active and self._story.priority > record.priority then
		self._metrics.cuesSuppressed += 1
		self:_diagnose(Diagnostic.CueSuppressed, { cueId = record.cueId, requestId = record.requestId })
		record.silent = true
		return CueResult.Suppressed
	end
	-- Equal priority collapses: cascaded completions produce one stinger.
	if self._stinger then
		self._metrics.cuesSuppressed += 1
		self:_diagnose(Diagnostic.CueSuppressed, { cueId = record.cueId, requestId = record.requestId })
		record.silent = true
		return CueResult.Suppressed
	end

	local chain = self._catalog:getCueChain(record.cueId, Role.Primary)
	local index = self:_firstPlayableAssignment(chain, 1)
	if not index then
		self:_diagnose(Diagnostic.CueWithoutRecording, { cueId = record.cueId, requestId = record.requestId })
		record.silent = true
		return CueResult.NoRecording
	end

	local assignment = chain[index]
	self._generation += 1
	local playback = {
		generation = self._generation,
		trackId = assignment.trackId,
		source = Source.Story,
		cueId = record.cueId,
		startSeconds = self._catalog:resolveStart(assignment.trackId, assignment.startOffsetSeconds),
		loop = false,
		crossfadeSeconds = record.cue.crossfadeSeconds,
	}
	record.played = true
	self._stinger = { generation = playback.generation, record = record, trackId = assignment.trackId }

	-- The stinger is music: it obeys music mute and volume while ducking only the
	-- two main decks.
	self:_backendCall("setDuck", {
		gainDb = self._config.stingerDuckDb,
		attackSeconds = self._config.stingerDuckAttackSeconds,
		releaseSeconds = self._config.stingerDuckReleaseSeconds,
	})
	self:_backendCall("playStinger", self:_buildRequest(playback, MusicTypes.Channel.Stinger))
	self:_publish()
	return CueResult.Started
end

function MusicDirector:_startCue(record)
	local role = Role.Primary
	local chain = self._catalog:getCueChain(record.cueId, role)
	local index = self:_firstPlayableAssignment(chain, 1)
	if not index then
		role = Role.Fallback
		chain = self._catalog:getCueChain(record.cueId, role)
		index = self:_firstPlayableAssignment(chain, 1)
	end
	if not index then
		self:_diagnose(Diagnostic.CueWithoutRecording, { cueId = record.cueId, requestId = record.requestId })
		record.silent = true
		self:_publish()
		return CueResult.NoRecording
	end

	-- A cinematic takeover cancels an active stinger and restores the ducking
	-- envelope before its own crossfade.
	self:_cancelStinger()
	self:_captureInterrupted()

	record.chainRole = role
	record.chainIndex = index
	record.played = true
	record.retained = nil
	self._story = record
	-- An authored cue overrides an explicit stop for the length of the scene, but
	-- does not undo it: silence returns when the scene releases.
	self:_playAssignment(record)
	return CueResult.Started
end

function MusicDirector:_advanceStory(current)
	local record = self._requests[current.requestId] or self._story
	if not record or self._story ~= record then
		return self:_restoreAfterStory()
	end

	-- A pool fallback has no assignment left to consult, so it simply completes.
	local assignment = self:_assignmentAt(record)
	if assignment then
		local behavior = assignment.endBehavior or EndBehavior.CueDefault
		if behavior == EndBehavior.Advance then
			local chain = self._catalog:getCueChain(record.cueId, record.chainRole or Role.Primary)
			local nextIndex = self:_firstPlayableAssignment(chain, record.chainIndex + 1)
			if nextIndex then
				record.chainIndex = nextIndex
				self:_playAssignment(record)
				return true
			end
		elseif
			behavior == EndBehavior.CueDefault
			and (record.cue.loopMode == LoopMode.Loop or record.cue.loopMode == LoopMode.LoopIfNeeded)
			and self:_playAssignment(record)
		then
			return true
		end
	end

	record.musicFinished = true
	self:_endStory(record, Reason.Completed, true)
	return true
end

-- May `record` take the deck (or the retained slot) from `active`? Higher priority
-- always may and lower never does. Equal priority is a presentation-owner privilege
-- rather than a public one: setting replaceEqualPriority is not proof of anything, so
-- the caller must also name the request it replaces, or carry the same stable
-- ownerId its own presentation used for the cue it is replacing.
function MusicDirector:_mayReplace(record, active, context)
	if record.priority > active.priority then
		return true
	end
	if record.priority < active.priority then
		return false, "LowerPriority"
	end
	if context.replaceEqualPriority ~= true then
		return false, "EqualPriority"
	end

	local replaces = context.replacesRequestId
	if type(replaces) == "string" and replaces == active.requestId then
		return true
	end
	local ownerId = context.ownerId
	local activeOwnerId = active.context and active.context.ownerId
	if type(ownerId) == "string" and #ownerId > 0 and ownerId == activeOwnerId then
		return true
	end
	return false, "NotPresentationOwner"
end

-- Requests a story, milestone, or stinger cue. context.requestId is required and
-- makes the call idempotent; context.replaceEqualPriority, paired with
-- context.replacesRequestId or context.ownerId, lets a presentation owner hand its
-- own scene from one cue to the next.
function MusicDirector:requestCue(cueId, context)
	context = context or {}
	local requestId = context.requestId
	assert(type(requestId) == "string" and #requestId > 0, "MusicDirector:requestCue requires context.requestId")

	if self._requests[requestId] then
		return CueResult.Duplicate
	end

	local cue = self._catalog:getCue(cueId)
	if not cue then
		self:_diagnose(Diagnostic.UnknownCue, { cueId = cueId, requestId = requestId })
		return CueResult.UnknownCue
	end

	local record = {
		requestId = requestId,
		cueId = cueId,
		cue = cue,
		priority = cue.priority or 0,
		context = context,
		active = true,
		played = false,
		silent = false,
	}
	self._requests[requestId] = record
	self:_applyCueContext(cue)

	if cue.storyMomentsControlled and not self._storyMomentsEnabled then
		record.silent = true
		self:_publish()
		return CueResult.Acknowledged
	end

	if cue.cueClass == CueClass.Stinger then
		return self:_requestStinger(record)
	end

	local active = self._story
	if active and active.active then
		local replaces, refusal = self:_mayReplace(record, active, context)
		if not replaces then
			-- Lower priority is suppressed outright, never stored as a stale
			-- backlog that could begin late. So is an equal-priority request that
			-- cannot show it owns the presentation it is trying to replace.
			self._metrics.cuesSuppressed += 1
			self:_diagnose(Diagnostic.CueSuppressed, {
				cueId = cueId,
				requestId = requestId,
				activeCueId = active.cueId,
				reason = refusal,
			})
			record.silent = true
			return CueResult.Suppressed
		end
		self:_diagnose(Diagnostic.CueReplaced, {
			cueId = cueId,
			requestId = requestId,
			replacedCueId = active.cueId,
			replacedRequestId = active.requestId,
		})
		active.active = false
		self:_endStory(active, Reason.Replaced, false)
	end

	if not self:isHydrated() then
		-- Held, not played: it starts on hydration only while its owner still
		-- holds the presentation. The retained slot changes hands under exactly the
		-- rule the audible deck uses, so an equal-priority cue cannot take the
		-- intro's slot unless it owns the intro.
		local held = self._retainedCue
		local takesSlot, heldRefusal = true, nil
		if held and held.active then
			takesSlot, heldRefusal = self:_mayReplace(record, held, context)
		end
		if not takesSlot then
			self._metrics.cuesSuppressed += 1
			self:_diagnose(Diagnostic.CueSuppressed, {
				cueId = cueId,
				requestId = requestId,
				activeCueId = held.cueId,
				reason = heldRefusal,
			})
			record.silent = true
			return CueResult.Suppressed
		end
		record.retained = true
		self._retainedCue = record
		self:_publish()
		return CueResult.Retained
	end

	return self:_startCue(record)
end

-- Releases only the matching presentation, so an older scene can never stop a
-- newer cue. The reason is what the owner says actually happened, and only a
-- completion reason counts the moment as encountered.
function MusicDirector:releaseCue(requestId, reason)
	local record = self._requests[requestId]
	if not record then
		return false
	end
	reason = reason or Reason.SceneEnded

	self._requests[requestId] = nil
	if self._retainedCue == record then
		self._retainedCue = nil
	end
	if self._stinger and self._stinger.record == record then
		self:_cancelStinger()
	end

	local owned = self._story == record
	record.active = false
	if owned then
		self:_endStory(record, reason, true)
	end

	-- Only a presentation that reached its end counts: a cancelled, replaced, failed,
	-- or skipped scene must not reveal its recording or report a moment the player
	-- never actually had.
	if MusicTypes.isCompletionReason(reason) then
		self:_noteEncountered(record, reason)
	end
	self:_publish()
	return true
end

-- Stops the cue's music while the scene keeps running; the presentation stays
-- active so its owner still releases it normally.
function MusicDirector:skipStorySong()
	local record = self._story
	if not record then
		return Command.Rejected
	end
	self._metrics.skips += 1
	record.songSkipped = true
	self:_endStory(record, Reason.Skipped, true)
	self:_publish()
	return Command.Accepted
end

function MusicDirector:getActiveCue()
	local record = self._story
	if not record then
		return nil
	end
	return record.cueId, record.requestId
end

--[[ Player commands ]]

function MusicDirector:playNow(trackId)
	if not self:_isPlayable(trackId) then
		return Command.NotPlayable
	end
	self._userStopped = false
	if self._story then
		-- The scene keeps the deck; the choice becomes what resumes afterwards.
		self._resumeAfterStory = {
			trackId = trackId,
			position = self._catalog:resolveStart(trackId, 0),
			paused = false,
		}
		self:_publish()
		return Command.StoryActive
	end
	self:_playTrack(trackId, Source.Manual)
	self:_markSnapshotDirty()
	return Command.Accepted
end

function MusicDirector:playNext(trackId)
	if not self:_isPlayable(trackId) then
		return Command.NotPlayable
	end
	if not self._queue:insertNext(trackId) then
		self:_diagnose(Diagnostic.QueueFull, {})
		return Command.QueueFull
	end
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:addToQueue(trackId)
	if not self:_isPlayable(trackId) then
		return Command.NotPlayable
	end
	if not self._queue:append(trackId) then
		self:_diagnose(Diagnostic.QueueFull, {})
		return Command.QueueFull
	end
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:moveInQueue(fromIndex, toIndex)
	if not self._queue:move(fromIndex, toIndex) then
		return Command.Rejected
	end
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:removeFromQueue(index)
	if not self._queue:remove(index) then
		return Command.Rejected
	end
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:clearUpcoming()
	self._queue:clearUpcoming()
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:next()
	if self._story then
		return Command.StoryActive
	end
	self._userStopped = false
	self._metrics.skips += 1
	if not self._current and not self._pending then
		self:_startAutomatic()
		return Command.Accepted
	end
	self:_advanceAutomatic()
	return Command.Accepted
end

function MusicDirector:previous()
	if self._story then
		return Command.StoryActive
	end
	local current = self._current

	-- Past the restart threshold Previous restarts the current recording.
	if current and self:_elapsedOf(current) >= self._config.previousRestartSeconds then
		self:_playTrack(current.trackId, current.source, { skipHistory = true })
		return Command.Accepted
	end

	local trackId = self._queue:popHistory()
	while trackId and not self:_isPlayable(trackId) do
		trackId = self._queue:popHistory()
	end
	if not trackId then
		if current then
			self:_playTrack(current.trackId, current.source, { skipHistory = true })
			return Command.Accepted
		end
		return Command.Rejected
	end

	self._userStopped = false
	self:_playTrack(trackId, Source.Manual, { skipHistory = true })
	self:_markSnapshotDirty()
	return Command.Accepted
end

function MusicDirector:pause()
	if self._story then
		-- The transport shows Skip Story Song during a cue instead.
		return Command.StoryActive
	end
	local current = self._current
	if not current or current.paused then
		return Command.Rejected
	end
	current.pausedPosition = self:_positionOf(current)
	current.paused = true
	self:_backendCall("pause")
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:resume()
	local current = self._current
	if not current then
		if not self._pending and not self._story then
			self._userStopped = false
			self:_startAutomatic()
			return Command.Accepted
		end
		return Command.Rejected
	end
	if not current.paused then
		return Command.Rejected
	end
	current.startSeconds = current.pausedPosition or current.startSeconds
	current.startedAt = self:_clock()
	current.paused = false
	current.pausedPosition = nil
	self:_backendCall("resume")
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

-- `elapsedSeconds` is measured from the start of the playback region -- exactly the
-- number Now Playing publishes -- so a UI slider never has to know the authored trim.
-- Only the backend request speaks absolute recording time.
function MusicDirector:seek(elapsedSeconds)
	if self._story then
		-- Story cues show progress but cannot be sought.
		return Command.StoryActive
	end
	local current = self._current
	if not current or not isFiniteNumber(elapsedSeconds) then
		return Command.Rejected
	end
	local absolute =
		self._catalog:clampPosition(current.trackId, self:_regionStart(current.trackId) + elapsedSeconds)
	current.startSeconds = absolute
	current.startedAt = self:_clock()
	if current.paused then
		current.pausedPosition = absolute
	end
	self:_backendCall("seek", absolute)
	self:_markSnapshotDirty()
	self:_publish()
	return Command.Accepted
end

function MusicDirector:stop()
	self._userStopped = true
	self:_enterStopped()
	return Command.Accepted
end

--[[ Settings, preferences, and progression ]]

function MusicDirector:setSettingsReady(ready)
	local value = ready ~= false
	if self._hydratedSettings == value then
		return false
	end
	self._hydratedSettings = value
	self:_onHydrationChanged()
	return true
end

function MusicDirector:setPreferences(preferences)
	local values = type(preferences) == "table" and preferences or EMPTY
	if values.Volume ~= nil then
		self:setVolume(values.Volume)
	end
	if values.StoryMomentsEnabled ~= nil then
		self:setStoryMomentsEnabled(values.StoryMomentsEnabled)
	end
	if values.Vibe ~= nil then
		self:setVibe(values.Vibe)
	end
	if values.ShuffleEnabled ~= nil then
		self:setShuffleEnabled(values.ShuffleEnabled)
	end
	if values.RepeatMode ~= nil then
		self:setRepeatMode(values.RepeatMode)
	end
	self._hydratedPreferences = true
	self:_onHydrationChanged()
	return true
end

function MusicDirector:_onHydrationChanged()
	if not self:isHydrated() then
		self:_publish()
		return
	end

	local restore = self._pendingRestore
	if restore then
		self._pendingRestore = nil
		self:restoreSnapshot(restore)
	end

	local retained = self._retainedCue
	if retained then
		self._retainedCue = nil
		if retained.active and self._requests[retained.requestId] == retained then
			self:_startCue(retained)
		end
	end

	if not self._current and not self._pending and not self._story and not self._userStopped then
		self:_startAutomatic()
	end
	self:_publish()
end

-- The master mute. Deck timing continues so restoring returns to the current
-- moment instead of restarting or choosing a different song.
function MusicDirector:setMusicEnabled(enabled)
	local value = enabled ~= false
	if self._musicEnabled == value then
		return false
	end
	self._musicEnabled = value
	self:_backendCall("setMuted", not value)
	self:_publish()
	return true
end

function MusicDirector:isMusicEnabled()
	return self._musicEnabled
end

function MusicDirector:setVolume(volume)
	local value = tonumber(volume)
	if not value or value ~= value then
		return false
	end
	value = math.clamp(value, 0, 1)
	if self._volume == value then
		return false
	end
	self._volume = value
	self:_backendCall("setMasterVolume", value)
	self:_publish()
	return true
end

function MusicDirector:setStoryMomentsEnabled(enabled)
	local value = enabled ~= false
	if self._storyMomentsEnabled == value then
		return false
	end
	self._storyMomentsEnabled = value

	if not value then
		self._retainedCue = nil
		local record = self._story
		if record and record.cue.storyMomentsControlled then
			record.silent = true
			self:_endStory(record, Reason.Cancelled, true)
		end
	end
	self:_publish()
	return true
end

function MusicDirector:setVibe(vibe)
	if not MusicTypes.Vibe[vibe] then
		return false
	end
	if not self._selector:setVibe(vibe) then
		return false
	end
	self:_refreshUpNext()
	self:_publish()
	return true
end

function MusicDirector:setShuffleEnabled(enabled)
	local changed = self._queue:setShuffleEnabled(enabled)
	changed = self._selector:setShuffleEnabled(enabled) or changed
	if not changed then
		return false
	end
	-- Regenerating the automatic tail leaves Now Playing and the explicit queue
	-- untouched by construction: neither lives in the selector.
	self:_refreshUpNext()
	self:_publish()
	return true
end

function MusicDirector:setRepeatMode(mode)
	if not self._queue:setRepeatMode(mode) then
		return false
	end
	self:_publish()
	return true
end

function MusicDirector:setSource(kind, id)
	if not self._selector:setSource(kind, id) then
		return false
	end
	self:_refreshUpNext()
	self:_publish()
	return true
end

-- Committed progression facts from the game: granted unlock rules, permanent
-- collection discovery, encountered cues, and the progression number.
function MusicDirector:setUnlockContext(context)
	self._unlocks:setContext(context)
	self:_refreshUpNext()
	if not self._current and not self._pending and not self._story and not self._userStopped then
		self:_startAutomatic()
	end
	self:_publish()
	return true
end

function MusicDirector:updateUnlockContext(partial)
	self._unlocks:update(partial)
	self:_refreshUpNext()
	self:_publish()
	return true
end

--[[ Resume snapshot ]]

-- Bounded, client-owned listening state. Never contains a story cue or the
-- automatic history; SavedAt is stamped by the server.
function MusicDirector:captureSnapshot()
	local snapshot = { Queue = self._queue:list(), Paused = false }

	local current = self._current
	if current and current.source ~= Source.Story then
		snapshot.TrackId = current.trackId
		snapshot.PositionSeconds = self:_positionOf(current)
		snapshot.Paused = current.paused == true
	elseif self._resumeAfterStory then
		snapshot.TrackId = self._resumeAfterStory.trackId
		snapshot.PositionSeconds = self._resumeAfterStory.position
		snapshot.Paused = self._resumeAfterStory.paused == true
	end

	local kind, id = self._selector:getSource()
	snapshot.SourceKind = kind
	snapshot.SourceId = id

	if not snapshot.TrackId and #snapshot.Queue == 0 then
		return nil
	end
	return snapshot
end

-- Applies an already-sanitized snapshot (see MusicPersistence.sanitizeQueueResume).
-- Before hydration it is held and applied once preferences arrive.
function MusicDirector:restoreSnapshot(snapshot)
	if type(snapshot) ~= "table" then
		self._metrics.resumesRejected += 1
		self:_diagnose(Diagnostic.ResumeRejected, { reason = "Invalid" })
		return false
	end
	if not self:isHydrated() then
		self._pendingRestore = snapshot
		return false
	end

	if snapshot.SourceKind then
		self._selector:setSource(snapshot.SourceKind, snapshot.SourceId)
	end
	if snapshot.Queue then
		self._queue:setExplicit(snapshot.Queue)
	end

	if snapshot.TrackId and self:_isPlayable(snapshot.TrackId) then
		self._userStopped = false
		self._metrics.resumesRestored += 1
		self:_diagnose(Diagnostic.ResumeRestored, { trackId = snapshot.TrackId })
		self:_playTrack(snapshot.TrackId, Source.Manual, {
			startSeconds = self._catalog:clampPosition(snapshot.TrackId, snapshot.PositionSeconds),
			paused = snapshot.Paused == true,
			skipHistory = true,
		})
		self:_refreshUpNext()
		return true
	end

	self._metrics.resumesRejected += 1
	self:_diagnose(Diagnostic.ResumeRejected, { reason = "TrackUnavailable" })
	if not self._current and not self._pending and not self._story and not self._userStopped then
		self:_advanceAutomatic()
	end
	self:_publish()
	return false
end

--[[ View state ]]

function MusicDirector:subscribe(callback)
	assert(type(callback) == "function", "MusicDirector:subscribe requires a function")
	table.insert(self._subscribers, callback)
	return function()
		for index, entry in ipairs(self._subscribers) do
			if entry == callback then
				table.remove(self._subscribers, index)
				return
			end
		end
	end
end

function MusicDirector:getViewState()
	if not self._view then
		self:_publish()
	end
	return self._view
end

function MusicDirector:getUpNext()
	return self._upNext
end

-- The live playhead, as elapsed and total seconds inside the playback region. The
-- published view carries the same number, but only as it stood at the last publish:
-- this is what a progress bar polls in between, so the UI never needs a clock of its
-- own and never disagrees with the backend about where the recording is.
function MusicDirector:getPlaybackPosition()
	local current = self._current
	if not current then
		return 0, nil
	end
	return self:_elapsedOf(current), self._catalog:getDuration(current.trackId)
end

function MusicDirector:_nowPlayingView()
	local current = self._current
	if not current then
		return nil
	end
	local track = self._catalog:getTrack(current.trackId)
	local collection = track and self._catalog:getCollection(track.collectionId)
	local isStory = current.source == Source.Story
	return table.freeze({
		trackId = current.trackId,
		title = track and track.title,
		titleKey = track and track.titleKey,
		artist = track and track.artist,
		collectionId = track and track.collectionId,
		artworkAssetId = collection and collection.artworkAssetId,
		source = current.source,
		cueId = current.cueId,
		isStory = isStory,
		positionSeconds = self:_elapsedOf(current),
		durationSeconds = self._catalog:getDuration(current.trackId),
		paused = current.paused == true,
		canSeek = not isStory,
		loop = current.loop == true,
	})
end

function MusicDirector:_transportAction()
	if self._story then
		return MusicTypes.TransportAction.SkipStory
	end
	local current = self._current
	if not current then
		return MusicTypes.TransportAction.Play
	end
	if current.paused then
		return MusicTypes.TransportAction.Resume
	end
	return MusicTypes.TransportAction.Pause
end

function MusicDirector:_buildView()
	local kind, id = self._selector:getSource()
	local pending = self._pending
	return table.freeze({
		version = self._viewVersion,
		state = self._state,
		pending = pending and table.freeze({ kind = pending.source, trackId = pending.trackId }) or nil,
		nowPlaying = self:_nowPlayingView(),
		nextInQueue = table.freeze(self._queue:list()),
		upNext = table.freeze(table.clone(self._upNext)),
		resumesAfterStory = self._resumeAfterStory and self._resumeAfterStory.trackId or nil,
		activeCueId = self._story and self._story.cueId or nil,
		stingerCueId = self._stinger and self._stinger.record.cueId or nil,
		transportAction = self:_transportAction(),
		repeatMode = self._queue:getRepeatMode(),
		shuffleEnabled = self._queue:isShuffleEnabled(),
		vibe = self._selector:getVibe(),
		sourceKind = kind,
		sourceId = id,
		storyMomentsEnabled = self._storyMomentsEnabled,
		musicEnabled = self._musicEnabled,
		volume = self._volume,
		hydrated = self:isHydrated(),
	})
end

function MusicDirector:_publish()
	self._viewVersion += 1
	self._view = self:_buildView()
	for _, callback in ipairs(self._subscribers) do
		callback(self._view)
	end
end

return MusicDirector
