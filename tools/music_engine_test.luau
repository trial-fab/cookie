--!nocheck
-- Deterministic tests for the Orbit Radio engine core. No Roblox globals, no
-- audio instances, no clocks: a fake backend and a fake clock drive every
-- asynchronous outcome by hand, so each row of the docs/music.md acceptance
-- matrix that is text-verifiable is asserted here.

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
	}, { __index = getfenv() })
	setfenv(chunk, env)
	local result = chunk()
	cache[name] = result
	return result
end

local MusicTypes = loadModule("MusicTypes")
local MusicConfig = loadModule("MusicConfig")
local MusicRandom = loadModule("MusicRandom")
local MusicCatalog = loadModule("MusicCatalog")
local MusicUnlocks = loadModule("MusicUnlocks")
local MusicSelector = loadModule("MusicSelector")
local MusicQueue = loadModule("MusicQueue")
local MusicPersistence = loadModule("MusicPersistence")
local MusicDirector = loadModule("MusicDirector")

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

local function contains(list, value)
	for _, entry in ipairs(list) do
		if entry == value then
			return true
		end
	end
	return false
end

local function concat(list)
	return "{" .. table.concat(list, ",") .. "}"
end

--[[ Fixture catalog ]]

local function track(id, collectionId, lane, energy, options)
	options = options or {}
	local assetId = options.assetId or 100000
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
		audienceLane = lane,
		energy = energy,
		dialogueSafe = true,
		loopQuality = "Good",
		storyLocked = options.storyLocked == true,
		favoriteEnabled = options.favoriteEnabled ~= false,
		assetId = assetId,
		durationSeconds = options.duration or 100,
		normalizedVolumeDb = options.db or -1,
		playbackStartSeconds = options.playbackStart or 0,
		playbackEndSeconds = options.playbackEnd or options.duration or 100,
		loopStartSeconds = options.loopStart,
		loopEndSeconds = options.loopEnd,
	}
end

local function entry(trackId, weight, recency, minimumProgression)
	return {
		trackId = trackId,
		weight = weight or 1,
		recencyExclusion = recency or 2,
		minimumProgression = minimumProgression,
	}
end

local function assignment(trackId, role, order, endBehavior, offset)
	return {
		trackId = trackId,
		role = role,
		sequenceOrder = order,
		startOffsetSeconds = offset or 0,
		endBehavior = endBehavior,
	}
end

local function fixtureData()
	return {
		formatVersion = 1,
		mode = "strict",
		experienceId = "FIXTURE",
		inputDigest = "fixture",
		credits = { { sourceId = "FIXTURE", provider = "Fixture", artist = "Fixture Composer" } },
		collections = {
			{
				id = "FX_UNIVERSAL",
				displayName = "Universal",
				nameKey = "Music.Collection.FX_UNIVERSAL.Name",
				unlockRule = "Always",
				unlockCopyKey = "Music.Collection.FX_UNIVERSAL.Unlock",
				artworkAssetId = 900001,
				trackIds = {
					"U_CALM",
					"U_BRIGHT",
					"U_MID",
					"U_DRIFT",
					"U_PULSE",
					"U_HAZE",
					"R_CALM",
					"G_LATE",
					"ST_ONE",
					"NO_ASSET",
				},
			},
			{
				id = "FX_INDUSTRY",
				displayName = "Industry",
				nameKey = "Music.Collection.FX_INDUSTRY.Name",
				unlockRule = "IndustryFloor",
				unlockCopyKey = "Music.Collection.FX_INDUSTRY.Unlock",
				trackIds = { "I_ONE", "I_TWO" },
			},
			{
				id = "FX_STORY",
				displayName = "Story",
				nameKey = "Music.Collection.FX_STORY.Name",
				unlockRule = "StoryEncounter",
				unlockCopyKey = "Music.Collection.FX_STORY.Unlock",
				trackIds = { "S_INTRO", "S_DESCENT", "S_CORE" },
			},
		},
		tracks = {
			track("U_CALM", "FX_UNIVERSAL", "Playful", "Chill"),
			track("U_BRIGHT", "FX_UNIVERSAL", "Synth", "Energetic"),
			track("U_MID", "FX_UNIVERSAL", "Crossover", "Cinematic", { playbackStart = 5, playbackEnd = 65 }),
			track("U_DRIFT", "FX_UNIVERSAL", "Synth", "Chill"),
			track("U_PULSE", "FX_UNIVERSAL", "Playful", "Energetic"),
			track("U_HAZE", "FX_UNIVERSAL", "Crossover", "Cinematic"),
			track("R_CALM", "FX_UNIVERSAL", "Crossover", "Chill"),
			track("G_LATE", "FX_UNIVERSAL", "Playful", "Chill"),
			track("ST_ONE", "FX_UNIVERSAL", "Crossover", "Cinematic", { duration = 4, favoriteEnabled = false }),
			track("NO_ASSET", "FX_UNIVERSAL", "Playful", "Chill", { noAsset = true }),
			track("I_ONE", "FX_INDUSTRY", "Playful", "Energetic"),
			track("I_TWO", "FX_INDUSTRY", "Synth", "Chill"),
			track("S_INTRO", "FX_STORY", "Crossover", "Cinematic", { storyLocked = true, loopStart = 8, loopEnd = 92 }),
			track("S_DESCENT", "FX_STORY", "Crossover", "Cinematic", { storyLocked = true }),
			track("S_CORE", "FX_STORY", "Crossover", "Cinematic", { storyLocked = true }),
		},
		trackIndex = {},
		pools = {
			{
				id = "P_UNIVERSAL",
				displayName = "Universal",
				unlockRule = "Always",
				targetCount = 3,
				selectionPolicy = "ShuffledBag",
				entries = {
					entry("U_CALM"),
					entry("U_BRIGHT"),
					entry("U_MID"),
					entry("U_DRIFT"),
					entry("U_PULSE"),
					entry("U_HAZE"),
					entry("G_LATE", 1, 2, 5),
				},
			},
			{
				id = "P_INDUSTRY",
				displayName = "Industry",
				unlockRule = "IndustryFloor",
				targetCount = 2,
				selectionPolicy = "ShuffledBagWithUnlockBoost",
				entries = { entry("I_ONE"), entry("I_TWO") },
			},
			{
				id = "P_RECOVERY",
				displayName = "Recovery",
				unlockRule = "ContextualOnly",
				targetCount = 1,
				selectionPolicy = "WeightedContextual",
				entries = { entry("R_CALM", 1, 0) },
			},
		},
		cues = {
			{
				id = "FX_INTRO_ORBIT",
				cueClass = "Cinematic",
				priority = 100,
				loopMode = "Loop",
				crossfadeSeconds = 2.5,
				fallbackPoolId = "P_UNIVERSAL",
				storyMomentsControlled = true,
				assignments = { assignment("S_INTRO", "Primary", 1, "CueDefault") },
			},
			{
				id = "FX_INTRO_DESCENT",
				cueClass = "Cinematic",
				priority = 100,
				loopMode = "NoLoop",
				crossfadeSeconds = 1.5,
				fallbackPoolId = "P_UNIVERSAL",
				storyMomentsControlled = true,
				assignments = { assignment("S_DESCENT", "Primary", 1, "CueDefault") },
			},
			{
				id = "FX_CHAIN",
				cueClass = "Cinematic",
				priority = 90,
				loopMode = "NoLoop",
				crossfadeSeconds = 2,
				fallbackPoolId = "P_UNIVERSAL",
				storyMomentsControlled = true,
				assignments = {
					assignment("S_INTRO", "Primary", 1, "Advance", 12),
					assignment("S_DESCENT", "Continuation", 2, "Release"),
					assignment("U_CALM", "Fallback", 1, "Release"),
				},
			},
			{
				id = "FX_CORE",
				cueClass = "Cinematic",
				priority = 100,
				loopMode = "LoopIfNeeded",
				crossfadeSeconds = 3,
				fallbackPoolId = "P_RECOVERY",
				storyMomentsControlled = true,
				assignments = { assignment("S_CORE", "Primary", 1, "Release") },
			},
			{
				id = "FX_FLOOR_INDUSTRY",
				cueClass = "MajorMilestone",
				priority = 80,
				loopMode = "NoLoop",
				crossfadeSeconds = 1.5,
				fallbackPoolId = "P_INDUSTRY",
				storyMomentsControlled = true,
				assignments = { assignment("I_ONE", "Primary", 1, "Release") },
			},
			{
				id = "FX_ARC_COMPLETE",
				cueClass = "MajorMilestone",
				priority = 70,
				loopMode = "NoLoop",
				crossfadeSeconds = 1.5,
				fallbackPoolId = "P_UNIVERSAL",
				storyMomentsControlled = true,
				assignments = { assignment("U_MID", "Primary", 1, "Release") },
			},
			{
				id = "FX_STINGER",
				cueClass = "Stinger",
				priority = 30,
				loopMode = "NoLoop",
				crossfadeSeconds = 0.2,
				fallbackPoolId = "P_UNIVERSAL",
				storyMomentsControlled = false,
				assignments = { assignment("ST_ONE", "Primary", 1, "Release") },
			},
		},
	}
end

--[[ Fake backend ]]

local FakeBackend = {}
FakeBackend.__index = FakeBackend

function FakeBackend.new()
	return setmetatable({
		handlers = {},
		autoStart = true,
		failTracks = {},
		requests = {},
		prepares = {},
		stingers = {},
		stopCount = 0,
		stingerStopCount = 0,
		current = nil,
		muted = false,
		masterVolume = 1,
		paused = false,
		duck = nil,
		seeks = {},
	}, FakeBackend)
end

function FakeBackend:bind(handlers)
	self.handlers = handlers
end

function FakeBackend:play(request)
	table.insert(self.requests, request)
	self.current = request
	self.paused = request.paused == true
	local failure = self.failTracks[request.trackId]
	if failure then
		self.handlers.onFailed(request.generation, failure)
		return
	end
	if self.autoStart then
		self.handlers.onStarted(request.generation)
	end
end

function FakeBackend:playStinger(request)
	table.insert(self.stingers, request)
	if self.autoStingerEnd then
		self.handlers.onStingerEnded(request.generation)
	end
end

function FakeBackend:prepare(request)
	table.insert(self.prepares, request)
end

function FakeBackend:stop()
	self.stopCount += 1
	self.current = nil
end

function FakeBackend:stopStinger()
	self.stingerStopCount += 1
end

function FakeBackend:pause()
	self.paused = true
end

function FakeBackend:resume()
	self.paused = false
end

function FakeBackend:seek(position)
	table.insert(self.seeks, position)
end

-- Silent by default (nil = "ask your own clock"). A test sets reportPosition to
-- drive the real playhead, and reportGeneration to answer for a different load
-- than the one the director is asking about.
function FakeBackend:getPosition(generation)
	if self.reportGeneration ~= nil and self.reportGeneration ~= generation then
		return nil
	end
	return self.reportPosition
end

function FakeBackend:setMuted(muted)
	self.muted = muted
end

function FakeBackend:setMasterVolume(volume)
	self.masterVolume = volume
end

function FakeBackend:setDuck(config)
	self.duck = config
end

-- Test helpers
function FakeBackend:start(generation)
	return self.handlers.onStarted(generation or self.requests[#self.requests].generation)
end

function FakeBackend:finish()
	return self.handlers.onEnded(self.requests[#self.requests].generation)
end

function FakeBackend:fail(reason)
	return self.handlers.onFailed(self.requests[#self.requests].generation, reason or "Failed")
end

function FakeBackend:lastTrack()
	local request = self.requests[#self.requests]
	return request and request.trackId
end

function FakeBackend:playCount()
	return #self.requests
end

--[[ Engine harness ]]

local function newEngine(options)
	options = options or {}
	local clock = { value = 1000 }
	local catalog = MusicCatalog.new(options.data or fixtureData())
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext(options.context or { grants = {}, progression = 0 })
	local config = MusicConfig.new(options.config)
	local random = MusicRandom.new(options.seed or 20260806)
	local selector = MusicSelector.new({ catalog = catalog, unlocks = unlocks, config = config, random = random })
	local queue = MusicQueue.new(config)
	local backend = FakeBackend.new()
	backend.autoStart = options.autoStart ~= false
	backend.autoStingerEnd = options.autoStingerEnd ~= false

	local diagnostics, encounters = {}, {}
	local director = MusicDirector.new({
		catalog = catalog,
		unlocks = unlocks,
		selector = selector,
		queue = queue,
		backend = backend,
		config = options.config,
		now = function()
			return clock.value
		end,
		onDiagnostic = function(event)
			table.insert(diagnostics, event)
		end,
		onCueEncountered = function(cueId, context)
			table.insert(encounters, { cueId = cueId, context = context })
		end,
	})

	local harness = {
		clock = clock,
		catalog = catalog,
		unlocks = unlocks,
		selector = selector,
		queue = queue,
		backend = backend,
		director = director,
		diagnostics = diagnostics,
		encounters = encounters,
	}

	function harness.hydrate(preferences)
		director:setSettingsReady(true)
		director:setPreferences(preferences or {})
		return harness
	end

	function harness.advance(seconds)
		clock.value += seconds
		return harness
	end

	function harness.diagnosticCount(kind)
		local count = 0
		for _, event in ipairs(diagnostics) do
			if event.kind == kind then
				count += 1
			end
		end
		return count
	end

	function harness.encounteredCues()
		local result = {}
		for _, record in ipairs(encounters) do
			table.insert(result, record.cueId)
		end
		return result
	end

	return harness
end

--[[ Catalog wrapper ]]

section("catalog wrapper")
do
	local catalog = MusicCatalog.new(fixtureData())
	check("indexes tracks by id", catalog:getTrack("U_CALM") ~= nil and catalog:getTrack("NOPE") == nil)
	check("reports availability", catalog:isTrackAvailable("U_CALM") and not catalog:isTrackAvailable("NO_ASSET"))

	local from, to = catalog:getPlaybackRegion("U_MID")
	check("reads the authored playback region", from == 5 and to == 65, ("%s..%s"):format(from, to))
	check("duration is the region, not the file", catalog:getDuration("U_MID") == 60)
	check("cue offsets compose with the trim", catalog:resolveStart("U_MID", 10) == 15)
	check("clamps a position into the region", catalog:clampPosition("U_MID", 900) == 65 and catalog:clampPosition("U_MID", -5) == 5)
	check("clamps a non-finite position", catalog:clampPosition("U_CALM", 0 / 0) == 0)

	local loopStart, loopEnd = catalog:getLoopRegion("S_INTRO")
	check("reads the loop region", loopStart == 8 and loopEnd == 92)

	local chain = catalog:getCueChain("FX_CHAIN", "Primary")
	check("orders the primary chain", #chain == 2 and chain[1].trackId == "S_INTRO" and chain[2].trackId == "S_DESCENT")
	local fallback = catalog:getCueChain("FX_CHAIN", "Fallback")
	check("keeps the fallback chain separate", #fallback == 1 and fallback[1].trackId == "U_CALM")

	check("indexes revealing cues", contains(catalog:getRevealingCueIds("S_CORE"), "FX_CORE"))
	check("indexes pools by track", contains(catalog:getTrackPools("I_ONE"), "P_INDUSTRY"))
	check("caps positive normalization gain", math.abs(MusicCatalog.new(fixtureData()):getVolumeDb("U_CALM", 6) + 1) < 1e-9)

	local ok = pcall(function()
		return MusicCatalog.new({ formatVersion = 99 })
	end)
	check("rejects an unsupported format version", not ok)
end

--[[ Shipped development catalog ]]

section("shipped development catalog")
do
	local generated = loadModule("MusicCatalog.generated")
	local catalog = MusicCatalog.new(generated)
	check("loads the committed generated module", catalog ~= nil and catalog:getMode() == "development")
	check("has cue policy with no playable tracks yet", catalog:isEmpty() and #catalog:getCues() > 0)

	local harness = newEngine({ data = generated })
	harness.hydrate()
	check("stays silent with an empty catalog", harness.director:getState() == MusicTypes.State.Stopped)
	check("reports no eligible track once", harness.diagnosticCount(MusicTypes.Diagnostic.NoEligibleTrack) >= 1)

	local result = harness.director:requestCue("INTRO_ORBIT", { requestId = "intro-1" })
	check("a cue without a recording never breaks playback", result == MusicTypes.CueResult.NoRecording)
	check("no audio was requested", harness.backend:playCount() == 0)
	harness.director:releaseCue("intro-1", MusicTypes.ReleaseReason.SceneEnded)
	check("the moment still counts as encountered", contains(harness.encounteredCues(), "INTRO_ORBIT"))
end

--[[ Hydration and first ambient selection ]]

section("hydration and first selection")
do
	local harness = newEngine()
	check("boots silently", harness.director:getState() == MusicTypes.State.Stopped)
	check("nothing is requested before hydration", harness.backend:playCount() == 0)

	harness.director:setSettingsReady(true)
	check("settings alone do not start playback", harness.backend:playCount() == 0)

	harness.director:setPreferences({ Volume = 0.8, Vibe = "StoryMix" })
	check("one ambient track begins after hydration", harness.backend:playCount() == 1, harness.backend:playCount())
	check("state is Ambient", harness.director:getState() == MusicTypes.State.Ambient)
	check("the library is not bulk preloaded", #harness.backend.prepares <= 1, #harness.backend.prepares)
	check("saved volume reached the master fader", harness.backend.masterVolume == 0.8)

	local view = harness.director:getViewState()
	check("view state exposes Now Playing", view.nowPlaying ~= nil and view.nowPlaying.trackId == harness.backend:lastTrack())
	check("view state is frozen", table.isfrozen(view))
	check("story track ids never start ambient playback", not string.match(harness.backend:lastTrack(), "^S_"))

	-- A returning save hydrates owned progression; unlock state is not an event.
	local returning = newEngine({
		context = {
			grants = { IndustryFloor = true },
			progression = 3,
			unlockedCollectionIds = { "FX_INDUSTRY" },
		},
	})
	returning.hydrate()
	check("owned floors make their pool eligible", returning.unlocks:isPoolEligible("P_INDUSTRY"))
	check("no floor cue plays during hydration", returning.director:getActiveCue() == nil)
	local hydrationRequest = returning.backend.requests[#returning.backend.requests]
	check("hydration starts ambient music only", hydrationRequest.cueId == nil, tostring(hydrationRequest.cueId))
	check("and stays in Ambient", returning.director:getState() == MusicTypes.State.Ambient)

	-- The committed purchase response is what requests the cue.
	local plays = returning.backend:playCount()
	local floor = returning.director:requestCue("FX_FLOOR_INDUSTRY", { requestId = "floor-commit-1" })
	check("a committed floor unlock starts exactly one cue", floor == MusicTypes.CueResult.Started and returning.backend:playCount() == plays + 1)
	check("from the cue's own assignment", returning.backend:lastTrack() == "I_ONE")
	check("a redelivered purchase response does nothing", returning.director:requestCue("FX_FLOOR_INDUSTRY", { requestId = "floor-commit-1" }) == MusicTypes.CueResult.Duplicate)
	check("and playback is unchanged", returning.backend:playCount() == plays + 1)
end

--[[ Preference hydration ordering ]]

section("retained cue")
do
	local harness = newEngine()
	local result = harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("a cue before hydration is retained", result == MusicTypes.CueResult.Retained)
	check("nothing plays while retained", harness.backend:playCount() == 0)

	harness.hydrate()
	check("the retained cue starts on hydration", harness.backend:lastTrack() == "S_INTRO")
	check("state is Story", harness.director:getState() == MusicTypes.State.Story)

	local ranked = newEngine()
	ranked.director:requestCue("FX_ARC_COMPLETE", { requestId = "arc-1" })
	check(
		"a higher priority cue takes the retained slot",
		ranked.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-3" }) == MusicTypes.CueResult.Retained
	)
	check(
		"a lower priority cue cannot displace it",
		ranked.director:requestCue("FX_ARC_COMPLETE", { requestId = "arc-2" }) == MusicTypes.CueResult.Suppressed
	)
	ranked.hydrate()
	check("the highest priority retained cue plays", ranked.backend:lastTrack() == "S_INTRO")

	local other = newEngine()
	other.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-2" })
	other.director:releaseCue("orbit-2", MusicTypes.ReleaseReason.SceneEnded)
	other.hydrate()
	check("a released retained cue never begins late", other.backend:lastTrack() ~= "S_INTRO", other.backend:lastTrack())
	check("ambient takes over instead", other.director:getState() == MusicTypes.State.Ambient)
end

--[[ Cue ownership and priority ]]

section("cue ownership and priority")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	local afterFirst = harness.backend:playCount()

	local duplicate = harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("a duplicate requestId has no second effect", duplicate == MusicTypes.CueResult.Duplicate)
	check("no extra playback for the duplicate", harness.backend:playCount() == afterFirst)

	local lower = harness.director:requestCue("FX_ARC_COMPLETE", { requestId = "arc-1" })
	check("a lower priority cue is suppressed", lower == MusicTypes.CueResult.Suppressed)
	check("the cinematic keeps the deck", harness.backend:lastTrack() == "S_INTRO")

	harness.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	local resumedRequest = harness.backend.requests[#harness.backend.requests]
	check("the suppressed cue does not play late", resumedRequest.cueId == nil, tostring(resumedRequest.cueId))
	check("no presentation owns playback", harness.director:getActiveCue() == nil)
	check("ambient music takes over", harness.director:getState() == MusicTypes.State.Ambient)
	check("suppression is counted", harness.director:getMetrics().cuesSuppressed == 1)

	local equal = newEngine()
	equal.hydrate()
	equal.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-a" })
	local blocked = equal.director:requestCue("FX_INTRO_DESCENT", { requestId = "descent-a" })
	check("equal priority does not replace by default", blocked == MusicTypes.CueResult.Suppressed)

	local unproven = equal.director:requestCue("FX_INTRO_DESCENT", {
		requestId = "descent-flag",
		replaceEqualPriority = true,
	})
	check("the flag alone does not prove ownership", unproven == MusicTypes.CueResult.Suppressed)
	local wrongOwner = equal.director:requestCue("FX_INTRO_DESCENT", {
		requestId = "descent-wrong",
		replaceEqualPriority = true,
		replacesRequestId = "some-other-scene",
		ownerId = "someone-else",
	})
	check("naming another scene does not prove it either", wrongOwner == MusicTypes.CueResult.Suppressed)
	check("the cinematic still owns the deck", equal.backend:lastTrack() == "S_INTRO")

	local replaced = equal.director:requestCue("FX_INTRO_DESCENT", {
		requestId = "descent-b",
		replaceEqualPriority = true,
		replacesRequestId = "orbit-a",
	})
	check("the presentation owner may replace its own scene", replaced == MusicTypes.CueResult.Started)
	check("the replacement crossfades once", equal.backend:lastTrack() == "S_DESCENT")

	-- The other proof of ownership: one stable id carried across the presentation's
	-- own cue transitions.
	local owned = newEngine()
	owned.hydrate()
	owned.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-own", ownerId = "intro-presentation" })
	local byOwner = owned.director:requestCue("FX_INTRO_DESCENT", {
		requestId = "descent-own",
		replaceEqualPriority = true,
		ownerId = "intro-presentation",
	})
	check("a shared ownerId replaces its own scene", byOwner == MusicTypes.CueResult.Started)
	check("and the handover played", owned.backend:lastTrack() == "S_DESCENT")

	-- The retained slot changes hands under the same rule as the audible deck.
	local retained = newEngine()
	retained.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-held", ownerId = "intro-presentation" })
	check(
		"an unowned equal cue cannot take the retained slot",
		retained.director:requestCue("FX_INTRO_DESCENT", { requestId = "descent-held", replaceEqualPriority = true })
			== MusicTypes.CueResult.Suppressed
	)
	check(
		"its owner may hand the slot over",
		retained.director:requestCue("FX_INTRO_DESCENT", {
			requestId = "descent-held-2",
			replaceEqualPriority = true,
			ownerId = "intro-presentation",
		}) == MusicTypes.CueResult.Retained
	)
	retained.hydrate()
	check("and the handed-over cue is what starts", retained.backend:lastTrack() == "S_DESCENT")

	local plays = equal.backend:playCount()
	equal.director:releaseCue("orbit-a", MusicTypes.ReleaseReason.SceneEnded)
	check("the old request cannot release the new cue", equal.director:getState() == MusicTypes.State.Story)
	check("and cannot restore playback", equal.backend:playCount() == plays)

	equal.director:releaseCue("descent-b", MusicTypes.ReleaseReason.SceneEnded)
	check("the owning request restores playback", equal.director:getState() == MusicTypes.State.Ambient)
end

--[[ Story interruption and resume ]]

section("story interruption and resume")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.director:playNext("U_BRIGHT")
	check("a manual choice plays", harness.director:getState() == MusicTypes.State.Manual)

	harness.advance(10)
	harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	local view = harness.director:getViewState()
	check("the interrupted manual track is retained", view.resumesAfterStory == "U_CALM")
	check("the queue survives the interruption", concat(view.nextInQueue) == "{U_BRIGHT}")
	check("Now Playing shows the story cue", view.nowPlaying.isStory and view.nowPlaying.cueId == "FX_INTRO_ORBIT")
	check("story cues cannot be sought", harness.director:seek(5) == MusicTypes.CommandResult.StoryActive)

	harness.advance(30)
	harness.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	local resumed = harness.backend.requests[#harness.backend.requests]
	check("the manual track resumes", resumed.trackId == "U_CALM")
	check("it resumes at its saved position", math.abs(resumed.startSeconds - 10) < 1e-6, resumed.startSeconds)
	check("the explicit queue is untouched", concat(harness.director:getViewState().nextInQueue) == "{U_BRIGHT}")

	-- A selection that is still loading is still the selection. All three of these
	-- lost the player's choice while only the audible deck was inspected.
	local loading = newEngine({ autoStart = false })
	loading.hydrate()
	loading.director:playNow("U_CALM")
	check("the manual choice is still loading", loading.director:getState() == MusicTypes.State.Loading)
	loading.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-loading" })
	check("a cue during the load still retains it", loading.director:getViewState().resumesAfterStory == "U_CALM")
	loading.director:releaseCue("orbit-loading", MusicTypes.ReleaseReason.SceneEnded)
	local afterLoad = loading.backend.requests[#loading.backend.requests]
	check("and it resumes when the scene ends", afterLoad.trackId == "U_CALM", afterLoad.trackId)
	check("as a manual selection", afterLoad.source == MusicTypes.Source.Manual)

	local hydrating = newEngine({ autoStart = false })
	hydrating.director:restoreSnapshot({ TrackId = "U_CALM", PositionSeconds = 30, Queue = {} })
	hydrating.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-hydrate" })
	hydrating.hydrate()
	check("a retained cue takes the deck on hydration", hydrating.backend:lastTrack() == "S_INTRO")
	check(
		"the restoring snapshot track is retained, not dropped",
		hydrating.director:getViewState().resumesAfterStory == "U_CALM"
	)
	hydrating.director:releaseCue("orbit-hydrate", MusicTypes.ReleaseReason.SceneEnded)
	local restored = hydrating.backend.requests[#hydrating.backend.requests]
	check(
		"and it resumes at its saved position",
		restored.trackId == "U_CALM" and math.abs(restored.startSeconds - 30) < 1e-6,
		restored.startSeconds
	)

	local queued = newEngine()
	queued.hydrate()
	queued.director:addToQueue("U_BRIGHT")
	queued.backend.autoStart = false
	queued.backend:finish()
	check("the queue entry is loading", queued.director:getState() == MusicTypes.State.Loading)
	queued.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-queued" })
	check(
		"a queue-driven manual load is retained too",
		queued.director:getViewState().resumesAfterStory == "U_BRIGHT",
		tostring(queued.director:getViewState().resumesAfterStory)
	)

	local ambient = newEngine()
	ambient.hydrate()
	local first = ambient.backend:lastTrack()
	ambient.advance(20)
	ambient.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-2" })
	check("an ambient track is not retained", ambient.director:getViewState().resumesAfterStory == nil)
	ambient.director:releaseCue("orbit-2", MusicTypes.ReleaseReason.SceneEnded)
	local fresh = ambient.backend.requests[#ambient.backend.requests]
	check("a fresh contextual selection follows", fresh.trackId ~= first or fresh.startSeconds == 0, fresh.trackId)
	check("the old ambient position is not resumed", fresh.startSeconds == ambient.catalog:resolveStart(fresh.trackId, 0))
end

--[[ Playback position ]]

section("playback position")
do
	-- U_MID is trimmed to 5..65, so absolute recording seconds and the elapsed
	-- seconds the UI shows are deliberately different numbers here.
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_MID")
	harness.advance(10)
	-- The published view is a snapshot taken at the last publish; the live playhead
	-- is what a progress bar polls in between.
	local function elapsed()
		return (harness.director:getPlaybackPosition())
	end
	check("the director estimates from its own clock", math.abs(elapsed() - 10) < 1e-6, elapsed())
	check(
		"the published view agrees at publish time",
		math.abs(harness.director:getViewState().nowPlaying.positionSeconds) < 1e-6
	)
	local _, duration = harness.director:getPlaybackPosition()
	check("the live playhead reports the region length", duration == 60, duration)

	harness.backend.reportPosition = 25
	check("the backend playhead wins when it answers", math.abs(elapsed() - 20) < 1e-6, elapsed())
	harness.backend.reportPosition = 900
	check("a runaway report clamps to the region", math.abs(elapsed() - 60) < 1e-6, elapsed())
	harness.backend.reportPosition = 0 / 0
	check("a non-finite report falls back to the clock", math.abs(elapsed() - 10) < 1e-6, elapsed())
	harness.backend.reportPosition = "soon"
	check("a wrong-typed report falls back to the clock", math.abs(elapsed() - 10) < 1e-6, elapsed())

	harness.backend.reportPosition = 40
	harness.backend.reportGeneration = 9999
	check("a position for another generation is refused", math.abs(elapsed() - 10) < 1e-6, elapsed())
	harness.backend.reportGeneration = nil

	harness.director:pause()
	check("pause captures the backend position", math.abs(elapsed() - 35) < 1e-6, elapsed())
	harness.backend.reportPosition = nil
	harness.director:resume()
	harness.advance(5)
	check("resume continues from it", math.abs(elapsed() - 40) < 1e-6, elapsed())

	local snapshot = harness.director:captureSnapshot()
	check(
		"the snapshot stores absolute recording time",
		math.abs(snapshot.PositionSeconds - 45) < 1e-6,
		snapshot.PositionSeconds
	)

	-- A looping cue must wrap through its loop region instead of growing forever.
	local looping = newEngine()
	looping.hydrate()
	looping.director:requestCue("FX_INTRO_ORBIT", { requestId = "loop-1" })
	check("the looping cue plays", looping.backend:lastTrack() == "S_INTRO")
	looping.backend.reportPosition = 100
	local looped = looping.director:getPlaybackPosition()
	check("a report past the loop end wraps", math.abs(looped - 16) < 1e-6, looped)
	looping.backend.reportPosition = nil
	looping.advance(200)
	local drifted = looping.director:getPlaybackPosition()
	check("and an estimate never grows without bound", drifted >= 0 and drifted <= 92, drifted)

	local capped = newEngine()
	capped.hydrate()
	capped.director:playNow("U_MID")
	capped.advance(500)
	check(
		"a normal track stops at the end of its region",
		math.abs(capped.director:getPlaybackPosition() - 60) < 1e-6,
		capped.director:getPlaybackPosition()
	)
end

--[[ Seek ]]

section("seek is region relative")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_MID")

	check("seek accepts the number Now Playing publishes", harness.director:seek(10) == MusicTypes.CommandResult.Accepted)
	check("the backend is asked in absolute recording time", harness.backend.seeks[#harness.backend.seeks] == 15,
		harness.backend.seeks[#harness.backend.seeks])
	check(
		"and the UI reads back what it asked for",
		math.abs(harness.director:getViewState().nowPlaying.positionSeconds - 10) < 1e-6,
		harness.director:getViewState().nowPlaying.positionSeconds
	)

	harness.director:seek(900)
	check("a seek past the end clamps into the region", harness.backend.seeks[#harness.backend.seeks] == 65)
	harness.director:seek(-5)
	check("a seek before the start clamps into the region", harness.backend.seeks[#harness.backend.seeks] == 5)

	local seeks = #harness.backend.seeks
	check("a non-numeric seek is refused", harness.director:seek("10") == MusicTypes.CommandResult.Rejected)
	check("a non-finite seek is refused", harness.director:seek(math.huge) == MusicTypes.CommandResult.Rejected)
	check("and neither reached the backend", #harness.backend.seeks == seeks)

	harness.director:pause()
	harness.director:seek(20)
	check("seeking while paused moves the paused position", math.abs(harness.director:getViewState().nowPlaying.positionSeconds - 20) < 1e-6)
end

--[[ Completion reasons ]]

section("story completion reasons")
do
	local function releaseWith(reason)
		local harness = newEngine()
		harness.hydrate()
		harness.director:requestCue("FX_CORE", { requestId = "core-" .. reason })
		harness.director:releaseCue("core-" .. reason, reason)
		return harness
	end

	local cancelled = releaseWith(MusicTypes.ReleaseReason.Cancelled)
	check("a cancelled scene reports no encounter", #cancelled.encounteredCues() == 0, concat(cancelled.encounteredCues()))
	check("and reveals nothing", not cancelled.unlocks:isTrackPlayable("S_CORE"))
	check("but playback still recovers", cancelled.director:getState() == MusicTypes.State.Ambient)
	check("and the presentation is released", cancelled.director:getActiveCue() == nil)

	check("a failed scene reports no encounter", #releaseWith(MusicTypes.ReleaseReason.Failed).encounteredCues() == 0)
	check("a replaced scene reports no encounter", #releaseWith(MusicTypes.ReleaseReason.Replaced).encounteredCues() == 0)
	check("a skipped scene reports no encounter", #releaseWith(MusicTypes.ReleaseReason.Skipped).encounteredCues() == 0)

	local completed = releaseWith(MusicTypes.ReleaseReason.Completed)
	check("a completed scene is encountered", contains(completed.encounteredCues(), "FX_CORE"))
	check("and reveals its recording", completed.unlocks:isTrackPlayable("S_CORE"))
	local ended = releaseWith(MusicTypes.ReleaseReason.SceneEnded)
	check("so is a scene that ended", contains(ended.encounteredCues(), "FX_CORE"))

	local default = newEngine()
	default.hydrate()
	default.director:requestCue("FX_CORE", { requestId = "core-default" })
	default.director:releaseCue("core-default")
	check("a release with no reason counts as SceneEnded", contains(default.encounteredCues(), "FX_CORE"))
	check("the reported reason travels with it", default.encounters[1].context.reason == MusicTypes.ReleaseReason.SceneEnded)
	check("and so does the presentation id", default.encounters[1].context.requestId == "core-default")
end

--[[ Removing Now Playing ]]

section("removing now playing")
do
	-- The engine's queue indices address upcoming explicit entries only, so the UI
	-- maps "remove Now Playing" onto Next rather than onto an index.
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.director:addToQueue("U_BRIGHT")
	check("queue indices never address Now Playing", harness.director:removeFromQueue(2) == MusicTypes.CommandResult.Rejected)
	check("the upcoming entry is untouched", concat(harness.queue:list()) == "{U_BRIGHT}")

	check("Next is the mapping for removing Now Playing", harness.director:next() == MusicTypes.CommandResult.Accepted)
	check("it advances to the next explicit entry", harness.backend:lastTrack() == "U_BRIGHT")
	harness.director:next()
	check("and to a fresh automatic selection once the queue drains", harness.director:getState() == MusicTypes.State.Ambient)
end

--[[ Skip story song ]]

section("skip story song")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.advance(5)
	harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("the transport offers Skip Story Song", harness.director:getViewState().transportAction == MusicTypes.TransportAction.SkipStory)
	check("pause is not the story control", harness.director:pause() == MusicTypes.CommandResult.StoryActive)

	harness.director:skipStorySong()
	check("the interrupted track resumes", harness.backend:lastTrack() == "U_CALM")
	check("the scene keeps its presentation", harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" }) == MusicTypes.CueResult.Duplicate)
	check("skipping the song does not reveal the track", not harness.unlocks:isTrackPlayable("S_INTRO"))

	local plays = harness.backend:playCount()
	harness.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	check("releasing after a skip does not restart playback", harness.backend:playCount() == plays)
	check("scene completion reveals the story track", harness.unlocks:isTrackPlayable("S_INTRO"))
	check("the encounter is reported once", #harness.encounteredCues() == 1)
end

--[[ Story Moments disabled ]]

section("story moments disabled")
do
	local harness = newEngine()
	harness.hydrate({ StoryMomentsEnabled = false })
	local playing = harness.backend:lastTrack()
	local plays = harness.backend:playCount()

	local result = harness.director:requestCue("FX_FLOOR_INDUSTRY", { requestId = "floor-1" })
	check("the request is acknowledged", result == MusicTypes.CueResult.Acknowledged)
	check("music is not taken over", harness.backend:playCount() == plays and harness.backend:lastTrack() == playing)
	check("state is unchanged", harness.director:getState() == MusicTypes.State.Ambient)

	harness.director:releaseCue("floor-1", MusicTypes.ReleaseReason.SceneEnded)
	check("the moment still counts as encountered", contains(harness.encounteredCues(), "FX_FLOOR_INDUSTRY"))

	-- A stinger cue is not story-moments controlled, so it still plays.
	harness.director:requestCue("FX_STINGER", { requestId = "sting-1" })
	check("a non story-controlled cue still plays", #harness.backend.stingers == 1)
end

--[[ Stingers ]]

section("stingers and cascades")
do
	local harness = newEngine({ autoStingerEnd = false })
	harness.hydrate()
	local ambient = harness.backend:lastTrack()

	harness.director:requestCue("FX_STINGER", { requestId = "sting-1" })
	check("the stinger uses the overlay channel", #harness.backend.stingers == 1)
	check("it does not become the director state", harness.director:getState() == MusicTypes.State.Ambient)
	check("music keeps playing underneath", harness.backend:lastTrack() == ambient)
	check("the main decks duck", harness.backend.duck ~= nil and harness.backend.duck.gainDb == 6)

	local second = harness.director:requestCue("FX_STINGER", { requestId = "sting-2" })
	check("a cascaded stinger collapses into one", second == MusicTypes.CueResult.Suppressed)
	check("only one stinger played", #harness.backend.stingers == 1)

	harness.backend.handlers.onStingerEnded(harness.backend.stingers[1].generation)
	check("the ducking envelope is restored", harness.backend.duck == nil)

	local arc = newEngine({ autoStingerEnd = false })
	arc.hydrate()
	arc.director:requestCue("FX_ARC_COMPLETE", { requestId = "arc-1" })
	local suppressed = arc.director:requestCue("FX_STINGER", { requestId = "sting-3" })
	check("an arc cue supersedes its quest stingers", suppressed == MusicTypes.CueResult.Suppressed)
	check("no stinger played under the arc cue", #arc.backend.stingers == 0)

	local takeover = newEngine({ autoStingerEnd = false })
	takeover.hydrate()
	takeover.director:requestCue("FX_STINGER", { requestId = "sting-4" })
	takeover.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("a cinematic cancels an active stinger", takeover.backend.stingerStopCount == 1)
	check("and restores the ducking envelope first", takeover.backend.duck == nil)
end

--[[ Mute ]]

section("mute is not pause")
do
	local harness = newEngine()
	harness.hydrate()
	local plays = harness.backend:playCount()
	harness.advance(10)
	harness.director:setMusicEnabled(false)
	check("muting reaches the master fader", harness.backend.muted == true)
	check("muting starts no new playback", harness.backend:playCount() == plays)

	harness.advance(10)
	harness.director:setMusicEnabled(true)
	local view = harness.director:getViewState()
	check("deck timing continued while muted", math.abs(view.nowPlaying.positionSeconds - 20) < 1e-6, view.nowPlaying.positionSeconds)
	check("unmuting restarts nothing", harness.backend:playCount() == plays)
	check("the recording is unchanged", harness.backend:lastTrack() == view.nowPlaying.trackId)
end

--[[ Queue semantics ]]

section("queue command semantics")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:addToQueue("U_CALM")
	harness.director:addToQueue("U_BRIGHT")
	check("Add to Queue appends in selection order", concat(harness.queue:list()) == "{U_CALM,U_BRIGHT}")

	harness.director:playNext("U_MID")
	harness.director:playNext("R_CALM")
	check(
		"the newest Play Next becomes next and the rest keep order",
		concat(harness.queue:list()) == "{R_CALM,U_MID,U_CALM,U_BRIGHT}",
		concat(harness.queue:list())
	)

	harness.director:addToQueue("U_CALM")
	check("duplicate track ids are allowed", concat(harness.queue:list()) == "{R_CALM,U_MID,U_CALM,U_BRIGHT,U_CALM}")

	harness.director:moveInQueue(1, 3)
	check("move reorders explicit entries", concat(harness.queue:list()) == "{U_MID,U_CALM,R_CALM,U_BRIGHT,U_CALM}")
	harness.director:removeFromQueue(2)
	check("remove drops one entry", concat(harness.queue:list()) == "{U_MID,R_CALM,U_BRIGHT,U_CALM}")

	local queued = concat(harness.queue:list())
	harness.director:playNow("U_BRIGHT")
	check("Play Now preserves the upcoming queue", concat(harness.queue:list()) == queued)
	check("Play Now plays immediately", harness.backend:lastTrack() == "U_BRIGHT")

	harness.director:clearUpcoming()
	check("Clear Queue empties upcoming entries", #harness.queue:list() == 0)
	check("Clear Queue does not stop Now Playing", harness.director:getState() == MusicTypes.State.Manual)

	harness.director:addToQueue("U_MID")
	harness.backend:finish()
	check("the explicit queue plays before the automatic tail", harness.backend:lastTrack() == "U_MID")
	harness.backend:finish()
	check("the station resumes when the queue drains", harness.director:getState() == MusicTypes.State.Ambient)

	local full = newEngine({ config = { maxExplicitQueue = 2 } })
	full.hydrate()
	full.director:addToQueue("U_CALM")
	full.director:addToQueue("U_BRIGHT")
	check("the live queue is bounded", full.director:addToQueue("U_MID") == MusicTypes.CommandResult.QueueFull)

	local locked = newEngine()
	locked.hydrate()
	check("a locked collection cannot be queued", locked.director:addToQueue("I_ONE") == MusicTypes.CommandResult.NotPlayable)
	check("an undiscovered story track cannot be queued", locked.director:playNow("S_INTRO") == MusicTypes.CommandResult.NotPlayable)
end

--[[ Repeat ]]

section("repeat modes")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:setRepeatMode("One")
	harness.director:playNow("U_CALM")
	harness.backend:finish()
	check("Repeat One repeats a manual recording", harness.backend:lastTrack() == "U_CALM")

	harness.advance(5)
	harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("a story cue never inherits Repeat One", harness.backend:lastTrack() == "S_INTRO")
	harness.backend:finish()
	check("the cinematic loops rather than repeating via the queue", harness.backend:lastTrack() == "S_INTRO")

	harness.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	check("the manual track resumes", harness.backend:lastTrack() == "U_CALM")
	harness.backend:finish()
	check("and keeps repeating", harness.backend:lastTrack() == "U_CALM")

	local all = newEngine()
	all.hydrate()
	all.director:setRepeatMode("All")
	all.director:playNow("U_CALM")
	all.director:addToQueue("U_BRIGHT")
	all.director:addToQueue("U_MID")
	all.backend:finish()
	all.backend:finish()
	check("Repeat All consumes the explicit list", all.backend:lastTrack() == "U_MID")
	all.backend:finish()
	check("Repeat All recycles it instead of draining", all.backend:lastTrack() == "U_BRIGHT", all.backend:lastTrack())
end

--[[ Previous ]]

section("previous behavior")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.advance(1)
	harness.director:playNow("U_BRIGHT")

	harness.advance(1)
	harness.director:previous()
	check("within three seconds Previous goes back", harness.backend:lastTrack() == "U_CALM")

	harness.advance(4)
	harness.director:previous()
	check("past three seconds Previous restarts", harness.backend:lastTrack() == "U_CALM")
	local request = harness.backend.requests[#harness.backend.requests]
	check("and it restarts from the region start", request.startSeconds == 0)

	local story = newEngine()
	story.hydrate()
	story.director:playNow("U_CALM")
	story.advance(1)
	story.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	story.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	check("story cues never enter Previous history", not contains(story.queue:historyList(), "S_INTRO"), concat(story.queue:historyList()))

	local bounded = newEngine({ config = { historyLimit = 3 } })
	bounded.hydrate()
	for _ = 1, 6 do
		bounded.director:next()
	end
	check("history is bounded", bounded.queue:historyCount() <= 3, bounded.queue:historyCount())
end

--[[ Generation tokens ]]

section("generation tokens")
do
	local harness = newEngine({ autoStart = false })
	harness.hydrate()
	local firstGeneration = harness.backend.requests[1].generation

	harness.director:playNow("U_CALM")
	local secondGeneration = harness.backend.requests[#harness.backend.requests].generation
	check("each load carries a new generation", secondGeneration > firstGeneration)

	check("a stale start is ignored", harness.backend:start(firstGeneration) == false)
	check("state is still Loading", harness.director:getState() == MusicTypes.State.Loading)
	check("a stale callback is diagnosed", harness.diagnosticCount(MusicTypes.Diagnostic.StaleCallback) >= 1)

	check("the latest load wins", harness.backend:start(secondGeneration) == true)
	check("and becomes Now Playing", harness.director:getViewState().nowPlaying.trackId == "U_CALM")
	check("a stale ended callback does nothing", harness.backend.handlers.onEnded(firstGeneration) == false)
	check("a stale failure callback does nothing", harness.backend.handlers.onFailed(firstGeneration, "Late") == false)
	check("Now Playing is unaffected", harness.director:getViewState().nowPlaying.trackId == "U_CALM")

	-- A queue edit while a track is loading: the newest command wins.
	local editing = newEngine({ autoStart = false })
	editing.hydrate()
	editing.director:playNow("U_CALM")
	local pendingGeneration = editing.backend.requests[#editing.backend.requests].generation
	editing.director:playNow("U_BRIGHT")
	editing.backend:start(pendingGeneration)
	check("a superseded load cannot become current", editing.director:getState() == MusicTypes.State.Loading)
	editing.backend:start()
	check("the latest valid command plays", editing.backend:lastTrack() == "U_BRIGHT")
end

--[[ Load failure and timeout ]]

section("load failure and recovery")
do
	local harness = newEngine({ config = { loadRetryLimit = 1 } })
	harness.hydrate()
	harness.backend.failTracks = { S_INTRO = "Moderated", S_DESCENT = "Moderated" }
	harness.director:requestCue("FX_CHAIN", { requestId = "chain-1" })
	check("the cue falls back to its fallback chain", harness.backend:lastTrack() == "U_CALM", harness.backend:lastTrack())
	check("failures are counted", harness.director:getMetrics().loadsFailed >= 2)
	check("fallback use is counted", harness.director:getMetrics().fallbacksUsed >= 1)
	check("the failed asset is quarantined for the session", harness.selector:isQuarantined("S_INTRO"))

	local exhausted = newEngine()
	exhausted.hydrate()
	exhausted.backend.failTracks = { S_CORE = "Denied", R_CALM = "Denied" }
	exhausted.director:requestCue("FX_CORE", { requestId = "core-1" })
	check("an unplayable cue recovers instead of blocking", exhausted.director:getState() ~= MusicTypes.State.Story)
	check("gameplay continues with ambient music", exhausted.director:getState() == MusicTypes.State.Ambient)

	local pooled = newEngine()
	pooled.hydrate()
	pooled.backend.failTracks = { S_CORE = "Denied" }
	pooled.director:requestCue("FX_CORE", { requestId = "core-2" })
	check("a cue with no fallback chain uses its fallback pool", pooled.backend:lastTrack() == "R_CALM")
	check("and the presentation still owns playback", pooled.director:getState() == MusicTypes.State.Story)
	pooled.backend:finish()
	check("a finished pool fallback completes the cue", pooled.director:getState() == MusicTypes.State.Ambient)
	check("without stranding the presentation", pooled.director:getActiveCue() == nil)

	local timeout = newEngine({ autoStart = false, config = { loadTimeoutSeconds = 8, loadRetryLimit = 0 } })
	timeout.hydrate()
	local stalled = timeout.backend:lastTrack()
	timeout.advance(3)
	check("the load has not timed out yet", timeout.director:update() == false)
	timeout.advance(6)
	timeout.director:update()
	check("a timed out load is diagnosed", timeout.diagnosticCount(MusicTypes.Diagnostic.LoadTimeout) == 1)
	check("and the stalled track is quarantined", timeout.selector:isQuarantined(stalled))
	check("another track is attempted", timeout.backend:lastTrack() ~= stalled, timeout.backend:lastTrack())
end

--[[ Shuffled bag ]]

section("shuffled bag and history")
do
	local function sequence(seed, count)
		local catalog = MusicCatalog.new(fixtureData())
		local unlocks = MusicUnlocks.new(catalog)
		unlocks:setContext({ grants = {}, progression = 0 })
		local selector = MusicSelector.new({
			catalog = catalog,
			unlocks = unlocks,
			config = MusicConfig.new(),
			random = MusicRandom.new(seed),
		})
		local result = {}
		for _ = 1, count do
			table.insert(result, selector:select(0))
		end
		return result, selector
	end

	local first = sequence(4242, 12)
	local second = sequence(4242, 12)
	check("the same seed produces the same sequence", concat(first) == concat(second))
	check("a different seed diverges", concat(sequence(99, 12)) ~= concat(first))

	local repeated = false
	for index = 2, #first do
		if first[index] == first[index - 1] then
			repeated = true
		end
	end
	check("no track repeats back to back", not repeated, concat(first))

	local recent = false
	for index = 3, #first do
		if first[index] == first[index - 1] or first[index] == first[index - 2] then
			recent = true
		end
	end
	check("the recency window is respected", not recent, concat(first))

	local counts = {}
	for _, trackId in ipairs(first) do
		counts[trackId] = (counts[trackId] or 0) + 1
	end
	check("the bag spreads picks across the pool", counts.U_CALM and counts.U_BRIGHT and counts.U_MID, concat(first))
	check("a progression-gated entry stays out", counts.G_LATE == nil)

	local _, live = sequence(777, 3)
	local preview = live:preview(3, 0)
	check("preview does not consume live state", concat(live:preview(3, 0)) == concat(preview))
	check("preview predicts the next selection", live:select(0) == preview[1], preview[1])

	-- Progression opens the gated entry.
	local catalog = MusicCatalog.new(fixtureData())
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext({ grants = {}, progression = 5 })
	local gated = MusicSelector.new({
		catalog = catalog,
		unlocks = unlocks,
		config = MusicConfig.new(),
		random = MusicRandom.new(31337),
	})
	local seen = {}
	for _ = 1, 12 do
		seen[gated:select(0)] = true
	end
	check("a met progression gate opens the entry", seen.G_LATE == true)

	-- Quarantine keeps a failed asset out of automatic selection.
	local quarantined = MusicSelector.new({
		catalog = catalog,
		unlocks = unlocks,
		config = MusicConfig.new(),
		random = MusicRandom.new(5),
	})
	quarantined:quarantine("U_CALM")
	local clean = true
	for _ = 1, 12 do
		if quarantined:select(0) == "U_CALM" then
			clean = false
		end
	end
	check("a quarantined track is never selected", clean)
end

--[[ Selection context ]]

section("selection context")
do
	-- Energy smoothing: with the penalty at zero a large jump is unreachable.
	local catalog = MusicCatalog.new(fixtureData())
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext({ grants = {}, progression = 0 })
	local selector = MusicSelector.new({
		catalog = catalog,
		unlocks = unlocks,
		config = MusicConfig.new({ energyPenalty = 0 }),
		random = MusicRandom.new(11),
	})
	selector:notePlayed("U_BRIGHT")
	local afterEnergetic = catalog:getTrack(selector:select(0)).energy
	check("a large energy jump is smoothed away", afterEnergetic ~= "Chill", afterEnergetic)

	-- Unlock boost: newly unlocked floor music is preferred for a few picks.
	local boosted = MusicSelector.new({
		catalog = catalog,
		unlocks = MusicUnlocks.new(catalog),
		config = MusicConfig.new({ unlockBoostMultiplier = 1000, unlockBoostSelections = 3 }),
		random = MusicRandom.new(808),
	})
	boosted._unlocks:setContext({ grants = { IndustryFloor = true }, progression = 0 })
	boosted:noteUnlock("P_INDUSTRY", 0)
	local boostedPicks = { boosted:select(0), boosted:select(0), boosted:select(0) }
	local industryPicks = 0
	for _, trackId in ipairs(boostedPicks) do
		if trackId == "I_ONE" or trackId == "I_TWO" then
			industryPicks += 1
		end
	end
	check("newly unlocked floor music is boosted", industryPicks >= 2, concat(boostedPicks))

	-- Recovery: a somber cue hands the next pick to its recovery pool.
	local harness = newEngine()
	harness.hydrate()
	harness.director:requestCue("FX_CORE", { requestId = "core-1" })
	check("the somber cue plays", harness.backend:lastTrack() == "S_CORE")
	harness.director:releaseCue("core-1", MusicTypes.ReleaseReason.SceneEnded)
	check("recovery music follows a somber cue", harness.backend:lastTrack() == "R_CALM", harness.backend:lastTrack())
	harness.backend:finish()
	check("recovery lasts one selection", harness.backend:lastTrack() ~= "R_CALM", harness.backend:lastTrack())
end

--[[ Up Next regeneration ]]

section("up next regeneration")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.director:addToQueue("U_BRIGHT")
	harness.director:addToQueue("U_MID")

	local before = harness.director:getViewState()
	check("Up Next is generated", #before.upNext > 0)

	harness.director:setVibe("Playful")
	local afterVibe = harness.director:getViewState()
	check("a station change keeps Now Playing", afterVibe.nowPlaying.trackId == before.nowPlaying.trackId)
	check("a station change keeps the explicit queue", concat(afterVibe.nextInQueue) == concat(before.nextInQueue))

	harness.director:setShuffleEnabled(false)
	local afterShuffle = harness.director:getViewState()
	check("a shuffle change keeps Now Playing", afterShuffle.nowPlaying.trackId == before.nowPlaying.trackId)
	check("a shuffle change keeps the explicit queue", concat(afterShuffle.nextInQueue) == concat(before.nextInQueue))
	check("shuffle off produces a stable ordered tail", concat(afterShuffle.upNext) == concat(harness.director:getViewState().upNext))

	harness.director:setUnlockContext({ grants = { IndustryFloor = true }, progression = 1 })
	local afterProgression = harness.director:getViewState()
	check("a progression change keeps Now Playing", afterProgression.nowPlaying.trackId == before.nowPlaying.trackId)
	check("a progression change keeps the explicit queue", concat(afterProgression.nextInQueue) == concat(before.nextInQueue))
	local reachesIndustry = false
	for _, trackId in ipairs(harness.selector:preview(12, 0)) do
		if trackId == "I_ONE" or trackId == "I_TWO" then
			reachesIndustry = true
		end
	end
	check("newly eligible pools enter the tail", reachesIndustry)
end

--[[ Unlocks, discovery, and rebirth ]]

section("unlocks and discovery")
do
	local catalog = MusicCatalog.new(fixtureData())
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext({ grants = {}, progression = 0 })

	local locked = unlocks:getCollectionState("FX_INDUSTRY")
	check("a locked collection stays browsable", locked.browsable and not locked.unlocked)
	check("its unlock copy is available", locked.unlockCopyKey == "Music.Collection.FX_INDUSTRY.Unlock")
	check("its tracks are not playable", not unlocks:isTrackPlayable("I_ONE"))

	unlocks:setContext({ grants = { IndustryFloor = true }, progression = 1 })
	check("a granted floor unlocks its collection", unlocks:isCollectionUnlocked("FX_INDUSTRY"))
	check("and its pool becomes eligible", unlocks:isPoolEligible("P_INDUSTRY"))

	-- Rebirth: the run grant is gone, the permanent discovery is not.
	unlocks:setContext({ grants = {}, progression = 0, unlockedCollectionIds = { "FX_INDUSTRY" } })
	check("a discovered collection survives rebirth", unlocks:isCollectionUnlocked("FX_INDUSTRY"))
	check("its tracks stay playable", unlocks:isTrackPlayable("I_ONE"))
	check("current-run pools reset", not unlocks:isPoolEligible("P_INDUSTRY"))

	check("a contextual pool is never automatically eligible", not unlocks:isPoolEligible("P_RECOVERY"))
	check("an undiscovered story track is hidden", not unlocks:isTrackPlayable("S_CORE"))
	unlocks:noteCueEncountered("FX_CORE")
	check("an encountered scene reveals its track", unlocks:isTrackPlayable("S_CORE"))
	check("and opens the story collection", unlocks:isCollectionUnlocked("FX_STORY"))
	check("a track with no asset is never playable", not unlocks:isTrackPlayable("NO_ASSET"))
end

--[[ Persistence ]]

section("persistence")
do
	local catalog = MusicCatalog.new(fixtureData())
	local unlocks = MusicUnlocks.new(catalog)
	unlocks:setContext({ grants = {}, progression = 0 })

	local rejections = {}
	local preferences = MusicPersistence.sanitizePreferences({
		Volume = 4,
		StoryMomentsEnabled = "yes",
		Vibe = "Chaos",
		ShuffleEnabled = false,
		RepeatMode = "One",
	}, rejections)
	check("out of range volume falls back", preferences.Volume == 1)
	check("a non-boolean flag falls back", preferences.StoryMomentsEnabled == true)
	check("an unknown vibe falls back", preferences.Vibe == "StoryMix")
	check("valid values are kept", preferences.ShuffleEnabled == false and preferences.RepeatMode == "One")
	check("every rejection is reported", #rejections == 3, concat(rejections))

	local sanitized, problems = MusicPersistence.sanitize({
		Preferences = { Volume = 0.5 },
		FavoriteTrackIds = { "U_BRIGHT", "U_CALM", "U_CALM", "NOPE", "ST_ONE" },
		EncounteredCueIds = { "FX_CORE", "FX_NOPE" },
		UnlockedCollectionIds = { "FX_INDUSTRY" },
	}, { catalog = catalog, unlocks = unlocks, now = 1000 })
	check("favorites are deduplicated and sorted", concat(sanitized.FavoriteTrackIds) == "{U_BRIGHT,U_CALM}", concat(sanitized.FavoriteTrackIds))
	check("unknown ids are dropped", concat(sanitized.EncounteredCueIds) == "{FX_CORE}")
	check("collection unlocks are kept", concat(sanitized.UnlockedCollectionIds) == "{FX_INDUSTRY}")
	check("problems are reported without content", #problems >= 3, concat(problems))

	local reset = MusicPersistence.resetPreferences(sanitized)
	check("Reset All Settings restores preferences", reset.Preferences.Volume == 1)
	check("and keeps favorites", concat(reset.FavoriteTrackIds) == "{U_BRIGHT,U_CALM}")
	check("and keeps encountered music", concat(reset.EncounteredCueIds) == "{FX_CORE}")

	local fresh = MusicPersistence.sanitizeQueueResume({
		SavedAt = 9000,
		TrackId = "U_CALM",
		PositionSeconds = 42,
		Paused = true,
		Queue = { "U_BRIGHT", "I_ONE", "NOPE", "U_MID" },
		SourceKind = "Station",
		SourceId = "Balanced",
	}, { catalog = catalog, unlocks = unlocks, now = 9000 + 3600 })
	check("a fresh snapshot restores", fresh ~= nil and fresh.TrackId == "U_CALM")
	check("the position survives", fresh.PositionSeconds == 42 and fresh.Paused == true)
	check("locked and unknown entries are discarded in order", concat(fresh.Queue) == "{U_BRIGHT,U_MID}", concat(fresh.Queue))
	check("the selected source survives", fresh.SourceKind == "Station" and fresh.SourceId == "Balanced")

	local expired = MusicPersistence.sanitizeQueueResume({
		SavedAt = 9000,
		TrackId = "U_CALM",
		PositionSeconds = 42,
		Queue = { "U_BRIGHT" },
	}, { catalog = catalog, unlocks = unlocks, now = 9000 + 6 * 3600 + 1 })
	check("an expired snapshot is ignored", expired == nil)

	local skewed = MusicPersistence.sanitizeQueueResume({
		SavedAt = 100000,
		TrackId = "U_CALM",
	}, { catalog = catalog, unlocks = unlocks, now = 9000 })
	check("a future SavedAt is rejected", skewed == nil)

	local clamped = MusicPersistence.sanitizeQueueResume({
		SavedAt = 9000,
		TrackId = "U_MID",
		PositionSeconds = 900,
		Queue = {},
	}, { catalog = catalog, unlocks = unlocks, now = 9000 })
	check("a position is clamped to the usable region", clamped.PositionSeconds == 65, clamped.PositionSeconds)

	check("a position refresh is rate limited", MusicPersistence.shouldSendSnapshot(1000, 1010, false) == false)
	check("a meaningful change sends immediately", MusicPersistence.shouldSendSnapshot(1000, 1001, true) == true)
	check("the interval eventually elapses", MusicPersistence.shouldSendSnapshot(1000, 1031, false) == true)
end

--[[ Resume ]]

section("queue resume")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:playNow("U_CALM")
	harness.director:addToQueue("U_BRIGHT")
	harness.advance(12)
	harness.director:pause()

	local snapshot = harness.director:captureSnapshot()
	check("a snapshot captures the resumable track", snapshot.TrackId == "U_CALM")
	check("with its position and pause state", math.abs(snapshot.PositionSeconds - 12) < 1e-6 and snapshot.Paused == true)
	check("and the explicit queue", concat(snapshot.Queue) == "{U_BRIGHT}")
	check("and the selected source", snapshot.SourceKind == "Station")

	local rejoin = newEngine()
	snapshot.SavedAt = 500
	local sanitized = MusicPersistence.sanitizeQueueResume(snapshot, {
		catalog = rejoin.catalog,
		unlocks = rejoin.unlocks,
		now = 500 + 3600,
	})
	rejoin.director:restoreSnapshot(sanitized)
	check("a restore before hydration is held", rejoin.backend:playCount() == 0)
	rejoin.hydrate()
	check("rejoining within six hours restores the track", rejoin.backend:lastTrack() == "U_CALM")
	local restored = rejoin.backend.requests[#rejoin.backend.requests]
	check("at its approximate position", math.abs(restored.startSeconds - 12) < 1e-6)
	check("paused as it was left", rejoin.director:getViewState().nowPlaying.paused == true)
	check("with its explicit queue", concat(rejoin.queue:list()) == "{U_BRIGHT}")
	check("restoration is counted", rejoin.director:getMetrics().resumesRestored == 1)

	local stale = newEngine()
	local expired = MusicPersistence.sanitizeQueueResume(snapshot, {
		catalog = stale.catalog,
		unlocks = stale.unlocks,
		now = 500 + 6 * 3600 + 60,
	})
	check("an expired snapshot sanitizes to nothing", expired == nil)
	stale.hydrate()
	check("and a fresh selection starts instead", stale.director:getState() == MusicTypes.State.Ambient)

	local invalid = newEngine()
	invalid.director:restoreSnapshot({ TrackId = "I_ONE", PositionSeconds = 3, Queue = { "U_MID" } })
	invalid.hydrate()
	check("an unplayable current track falls through to the queue", invalid.backend:lastTrack() == "U_MID", invalid.backend:lastTrack())
	check("the rejection is counted", invalid.director:getMetrics().resumesRejected == 1)
end

--[[ Stop and idle ]]

section("stop and diagnostics")
do
	local harness = newEngine()
	harness.hydrate()
	harness.director:stop()
	check("stop enters Stopped", harness.director:getState() == MusicTypes.State.Stopped)
	local plays = harness.backend:playCount()
	harness.director:setUnlockContext({ grants = { IndustryFloor = true }, progression = 2 })
	check("an explicit stop is respected", harness.backend:playCount() == plays)
	harness.director:requestCue("FX_INTRO_ORBIT", { requestId = "orbit-1" })
	check("an authored cue still plays over an explicit stop", harness.director:getState() == MusicTypes.State.Story)
	harness.director:releaseCue("orbit-1", MusicTypes.ReleaseReason.SceneEnded)
	check("and silence returns afterwards", harness.director:getState() == MusicTypes.State.Stopped)

	harness.director:resume()
	check("an explicit play command starts again", harness.director:getState() == MusicTypes.State.Ambient)

	local metrics = harness.director:getMetrics()
	check("metrics are aggregate counters only", type(metrics.loadsStarted) == "number" and metrics.loadsStarted >= 1)
	check("metrics are a copy", (function()
		metrics.loadsStarted = -1
		return harness.director:getMetrics().loadsStarted >= 1
	end)())
end

print("")
if failures == 0 then
	print("music engine: all checks passed")
	return 0
end
print(("music engine: %d check(s) failed"):format(failures))
error("music engine tests failed", 0)
