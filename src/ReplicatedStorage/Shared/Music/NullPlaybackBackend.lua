-- NullPlaybackBackend -- the MusicPlaybackBackend contract, with no audio graph.
--
-- MusicDirector reaches audio only through these methods, which is what keeps the
-- engine core free of AudioPlayer, Wire, AudioFader, and every other Roblox
-- instance. This implementation is both the written contract and the safe
-- degradation path: if the audio graph cannot be built, the director keeps
-- running silently instead of stalling gameplay or retrying forever.
--
-- Contract
-- --------
-- backend:bind(handlers)
--   handlers.onStarted(generation)          the requested recording is audible
--   handlers.onEnded(generation)            it reached the end of its region
--   handlers.onFailed(generation, reason)   load/permission/moderation failure
--   handlers.onStingerEnded(generation)     the overlay stinger finished
--
-- backend:play(request) / backend:playStinger(request)
--   request = {
--     generation           = number,  -- stale callbacks are ignored by the director
--     channel              = "Main" | "Stinger",
--     source               = "Ambient" | "Manual" | "Story",
--     trackId              = string,
--     assetId              = number,
--     cueId                = string?,
--     startSeconds         = number,  -- absolute position inside the recording
--     playbackStartSeconds = number,
--     playbackEndSeconds   = number?,
--     loopStartSeconds     = number?,
--     loopEndSeconds       = number?,
--     loop                 = boolean,
--     crossfadeSeconds     = number,
--     volumeDb             = number,  -- catalog normalization, already capped
--     paused               = boolean,
--   }
--
-- backend:prepare(request)      optional prefetch of the likely next recording
-- backend:stop(options)         options = { generation, fadeSeconds }
-- backend:pause() / :resume() / :seek(seconds)   seconds is absolute recording time
-- backend:getPosition(generation) -> number?
--   The audible playhead in absolute recording seconds. Return nil unless the deck
--   is actually playing that generation -- the director prefers this over its own
--   clock estimate, because loading, crossfades, pausing, and loop wrap all make
--   real playback drift from wall time. A non-finite or mismatched answer is
--   refused and the clock estimate is used instead; the director clamps a normal
--   track to its region and wraps a looping one through its loop region, so a
--   backend never has to do that itself.
-- backend:setMuted(muted) / :setMasterVolume(volume)
-- backend:setDuck(config | nil) config = { gainDb, attackSeconds, releaseSeconds }
--
-- Every method is optional: the director probes before calling, so a partial
-- backend (or this one) never errors.

local NullPlaybackBackend = {}
NullPlaybackBackend.__index = NullPlaybackBackend

function NullPlaybackBackend.new()
	return setmetatable({
		_handlers = {},
		current = nil,
		stinger = nil,
		muted = false,
		masterVolume = 1,
		paused = false,
		duck = nil,
	}, NullPlaybackBackend)
end

function NullPlaybackBackend:bind(handlers)
	self._handlers = handlers or {}
end

-- Reports the recording as audible immediately and never ends it, so a missing
-- audio graph degrades to silence rather than to a retry loop.
function NullPlaybackBackend:play(request)
	self.current = request
	self.paused = request.paused == true
	local onStarted = self._handlers.onStarted
	if onStarted then
		onStarted(request.generation)
	end
end

function NullPlaybackBackend:playStinger(request)
	self.stinger = request
	local onStingerEnded = self._handlers.onStingerEnded
	if onStingerEnded then
		onStingerEnded(request.generation)
	end
end

function NullPlaybackBackend:prepare()
end

function NullPlaybackBackend:stop()
	self.current = nil
	self.paused = false
end

function NullPlaybackBackend:stopStinger()
	self.stinger = nil
end

function NullPlaybackBackend:pause()
	self.paused = true
end

function NullPlaybackBackend:resume()
	self.paused = false
end

function NullPlaybackBackend:seek()
end

-- No audio graph means no playhead. nil is the honest answer, and the director
-- estimates from its own clock instead.
function NullPlaybackBackend:getPosition()
	return nil
end

function NullPlaybackBackend:setMuted(muted)
	self.muted = muted and true or false
end

function NullPlaybackBackend:setMasterVolume(volume)
	self.masterVolume = volume
end

function NullPlaybackBackend:setDuck(config)
	self.duck = config
end

return NullPlaybackBackend
