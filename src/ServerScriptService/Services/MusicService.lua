-- MusicService -- ClickGame's server side of Orbit Radio.
--
-- Playback is entirely client-local. The server participates in exactly four
-- things, and nothing else:
--
--   1. Persistence. Persistent.Music is reconciled at load and is canonical from
--      then on; every mutation happens here, on the live profile, and rides the
--      ordinary autosave. No music message writes a DataStore entry of its own.
--   2. Entitlement. Permanent collection discovery follows committed floor unlocks,
--      and a story track is revealed only after authoritative state says its scene
--      really completed. A client can ask for neither.
--   3. Validation. Every incoming field is typed, ranged, bounded, and revalidated
--      against the approved catalog before it reaches the profile. Live messages are
--      strict where a saved profile is normalized, and every accepted or refused
--      mutation answers with the authoritative projection so an optimistic client
--      can never keep showing a change the profile did not take.
--   4. Timestamps. QueueResume.SavedAt is stamped from the server clock, so the
--      six-hour window cannot be extended or backdated from a client.
--
-- The decisions live in Shared/OrbitRadio/OrbitRadioProfile (pure, tested by
-- tools/orbit_radio_profile_test.py). This module is the Roblox shell around them:
-- lifecycle, remotes, per-player rate windows, and projection delivery.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Attrs = require(Shared.Attrs)
local MusicCatalog = require(Shared.Music.MusicCatalog)
local MusicConfig = require(Shared.Music.MusicConfig)
local MusicTypes = require(Shared.Music.MusicTypes)
local MusicUnlocks = require(Shared.Music.MusicUnlocks)
local Net = require(Shared.Net)
local OrbitRadioConfig = require(Shared.OrbitRadio.OrbitRadioConfig)
local OrbitRadioProfile = require(Shared.OrbitRadio.OrbitRadioProfile)
local FloorService = require(script.Parent.FloorService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local QuestService = require(script.Parent.QuestService)

local MusicService = {}

local config = MusicConfig.new()
local catalog
local readyByPlayer = setmetatable({}, { __mode = "k" })
local resumeDeliveredByPlayer = setmetatable({}, { __mode = "k" })
local unlocksByPlayer = setmetatable({}, { __mode = "k" })
local rateWindowsByPlayer = setmetatable({}, { __mode = "k" })
local reconcilePendingByPlayer = setmetatable({}, { __mode = "k" })

-- Settling time past the end of a rate window before the corrective projection is
-- sent, so the repair cannot race the boundary it is waiting for.
local RECONCILE_SETTLE_SECONDS = 0.25

local function getCatalog()
	if not catalog then
		-- Lazy: a zero-track development build must still load, and nothing here
		-- needs the catalog until a player actually arrives.
		local ok, result = pcall(MusicCatalog.default)
		if not ok then
			warn("MusicService: the generated music catalog failed to load: " .. tostring(result))
			return nil
		end
		catalog = result
	end
	return catalog
end

-- Canonical Data, gated on this session's reconciliation. Everything public fails
-- closed through here, so a message that arrives before setup finishes -- or after
-- the profile session ended -- can never construct a music domain of its own.
local function getStored(player)
	if readyByPlayer[player] ~= true then
		return nil
	end
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent or nil
	local stored = type(persistent) == "table" and persistent.Music or nil
	return type(stored) == "table" and stored or nil
end

local function allow(player, name)
	local windows = rateWindowsByPlayer[player]
	if not windows then
		windows = {}
		rateWindowsByPlayer[player] = windows
	end
	local allowed, state = OrbitRadioProfile.allowRate(windows[name], os.clock(), OrbitRadioConfig.Limits[name])
	windows[name] = state
	return allowed, state
end

local function getUnlockedFloorCount(player)
	return FloorService.GetUnlockedCount(player)
end

-- One resolver per player, rebuilt from canonical state whenever the library or the
-- run changes. It is what makes "playable" mean the same thing on both sides of the
-- wire: the server refuses to store a favorite or resume a track the client would
-- not have been allowed to reach.
local function refreshUnlocks(player, stored)
	local activeCatalog = getCatalog()
	if not activeCatalog or not stored then
		unlocksByPlayer[player] = nil
		return nil
	end

	local unlocks = unlocksByPlayer[player]
	if not unlocks then
		unlocks = MusicUnlocks.new(activeCatalog)
		unlocksByPlayer[player] = unlocks
	end
	unlocks:setContext({
		grants = OrbitRadioProfile.grantsForFloorCount(getUnlockedFloorCount(player)),
		progression = getUnlockedFloorCount(player),
		encounteredCueIds = stored.EncounteredCueIds,
		unlockedCollectionIds = stored.UnlockedCollectionIds,
	})
	return unlocks
end

local function project(player, stored, kind, includeResume)
	return OrbitRadioProfile.project(stored, {
		kind = kind,
		now = os.time(),
		config = config,
		catalog = getCatalog(),
		unlocks = refreshUnlocks(player, stored),
		unlockedFloorCount = getUnlockedFloorCount(player),
		includeResume = includeResume == true,
	})
end

-- Later pushes never carry QueueResume: the client restores its listening state
-- once, at hydrate. Re-delivering it would yank playback out from under the player
-- every time a floor unlocked.
local function push(player, kind)
	local stored = getStored(player)
	if not stored then
		return false
	end
	Net.fireClient(Net.Names.MusicStateChanged, player, project(player, stored, kind, false))
	return true
end

-- A dropped mutation leaves the client showing a change the profile never took, so
-- the authoritative projection has to follow it. It is deliberately sent when the
-- rate window closes rather than at the first denial: by then the burst that caused
-- the denials is over, so one projection reconciles every dropped change instead of
-- only the first one, and the client cannot diverge again behind a correction that
-- was already in flight. The cap is unchanged at one push per window per channel, so
-- a spamming client still cannot amplify its own denials, and because the projection
-- carries whole sets rather than deltas, a single late one is a complete repair.
local function scheduleReconcile(player, name, window, kind)
	local startedAt = type(window) == "table" and window.StartedAt or nil
	if startedAt == nil then
		return false
	end
	local pending = reconcilePendingByPlayer[player]
	if not pending then
		pending = {}
		reconcilePendingByPlayer[player] = pending
	end
	if pending[name] then
		-- Already reconciling this window; later denials ride the same push.
		return false
	end
	pending[name] = true

	local limit = OrbitRadioConfig.Limits[name]
	local remaining = (limit and limit.WindowSeconds or 0) - (os.clock() - startedAt)
	task.delay(math.max(remaining, 0) + RECONCILE_SETTLE_SECONDS, function()
		local scheduled = reconcilePendingByPlayer[player]
		if not scheduled or not scheduled[name] then
			-- The player left, or the profile was reloaded under this session.
			return
		end
		scheduled[name] = nil
		-- push fails closed for a player whose profile is gone.
		push(player, kind)
	end)
	return true
end

--[[ Lifecycle ]]

-- The load boundary, and the one place a music domain is created. It is deliberately
-- total: a fresh profile, a profile saved before Orbit Radio existed, a profile with
-- a garbage Music field, and a profile whose resume window closed while the player
-- was away all leave here with the same well-formed domain.
function MusicService.SetupPlayer(player, persistent)
	readyByPlayer[player] = nil
	resumeDeliveredByPlayer[player] = nil
	unlocksByPlayer[player] = nil
	rateWindowsByPlayer[player] = nil
	reconcilePendingByPlayer[player] = nil
	player:SetAttribute(Attrs.MusicLoaded, nil)

	if type(persistent) ~= "table" then
		return false
	end

	local stored, repairs = OrbitRadioProfile.normalizeStored(persistent.Music, os.time(), config)
	persistent.Music = stored
	if #repairs > 0 then
		warn(("MusicService: %s repaired saved music fields: %s"):format(player.Name, table.concat(repairs, ", ")))
	end

	-- Backfill discovery for floors this profile already owns. Collection unlocks
	-- are permanent and this only ever adds, so it is safe for a profile that
	-- unlocked Industry before this system shipped and safe after a rebirth.
	OrbitRadioProfile.unlockCollectionsForFloorCount(stored, getUnlockedFloorCount(player))

	readyByPlayer[player] = true
	refreshUnlocks(player, stored)
	player:SetAttribute(Attrs.MusicLoaded, true)
	return true
end

function MusicService.ForgetPlayer(player)
	readyByPlayer[player] = nil
	resumeDeliveredByPlayer[player] = nil
	unlocksByPlayer[player] = nil
	rateWindowsByPlayer[player] = nil
	reconcilePendingByPlayer[player] = nil
end

--[[ Committed progression ]]

-- Called after a floor purchase has committed, never from hydration or a preview.
-- Discovery is permanent; the cue itself is the client's business, requested from
-- the same committed purchase response (see UpgradeService.Purchase).
function MusicService.OnFloorUnlocked(player, floorId)
	local stored = getStored(player)
	local floor = OrbitRadioConfig.GetFloorById(floorId)
	if not stored or not floor then
		return false
	end

	local changed = OrbitRadioProfile.unlockCollection(stored, floor.CollectionId)
	-- Push regardless: even a re-unlock after a rebirth changes the current-run
	-- grants the client's ambient selection depends on.
	push(player, OrbitRadioConfig.ProjectionKind.Progression)
	return changed
end

-- Rebirth. Decision 16's approved exception in one line: the library is untouched,
-- and only the current-run grants narrow back to Ground.
function MusicService.OnRunReset(player)
	local stored = getStored(player)
	if not stored then
		return false
	end
	refreshUnlocks(player, stored)
	return push(player, OrbitRadioConfig.ProjectionKind.Progression)
end

-- Reset All Settings. SettingsService owns the command; this is the music half of
-- its boundary, and it deliberately does not touch favorites, encountered cues,
-- permanent collections, or the resume snapshot.
function MusicService.ResetPreferences(player)
	local stored = getStored(player)
	if not stored then
		return false
	end
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent or nil
	if type(persistent) ~= "table" or persistent.Music ~= stored then
		return false
	end

	persistent.Music = OrbitRadioProfile.resetPreferences(stored)
	push(player, OrbitRadioConfig.ProjectionKind.Reset)
	return true
end

-- Development-only. A dev reset rewinds story, quests, and the run, so the intro
-- and milestone cues have to become earnable again -- otherwise the encounters that
-- reveal them would still be recorded from the previous timeline.
function MusicService.ResetForDevelopment(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent or nil
	if type(persistent) ~= "table" then
		return false
	end

	persistent.Music = OrbitRadioProfile.defaults()
	readyByPlayer[player] = true
	resumeDeliveredByPlayer[player] = true
	refreshUnlocks(player, persistent.Music)
	push(player, OrbitRadioConfig.ProjectionKind.Reset)
	return true
end

--[[ Story encounters ]]

-- Authoritative facts for encounter eligibility. Every one of these is canonical
-- server state written by the owning service; nothing here can be influenced by the
-- message being validated.
local function encounterFacts(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent or nil
	local run = type(data) == "table" and data.Run or nil
	if type(persistent) ~= "table" then
		return nil
	end
	return {
		IntroSeen = persistent.IntroSeen == true,
		StoryStep = persistent.StoryStep,
		MixerUnlocked = persistent.MixerUnlocked == true,
		HubCoreActivated = type(run) == "table" and run.HubCoreActivated == true,
		IsArcCompleted = function(arcId)
			return QuestService.IsArcCompleted(player, arcId)
		end,
	}
end

-- The scene owner reports its completed presentation. Starting a scene, starting or
-- skipping its song, or naming a track directly cannot get here: this takes a cue
-- id, and it records nothing unless authoritative progression already says the
-- moment happened. That gate, not the client's report, is what makes a reveal safe.
function MusicService.RecordEncounter(player, cueId)
	local stored = getStored(player)
	if not stored then
		return false
	end
	local facts = encounterFacts(player)
	if not facts then
		return false
	end

	local recorded = OrbitRadioProfile.recordEncounter(stored, cueId, facts)
	if not recorded then
		return false
	end
	push(player, OrbitRadioConfig.ProjectionKind.Library)
	return true
end

--[[ Remotes ]]

local function onRequestState(player)
	local stored = getStored(player)
	if not stored then
		return { ready = false }
	end
	if not allow(player, "RequestState") then
		return { ready = false }
	end

	-- The snapshot is delivered once per session. A second hydrate is a UI reopen,
	-- not a rejoin, and must not re-restore a position the player has moved past.
	local includeResume = resumeDeliveredByPlayer[player] ~= true
	resumeDeliveredByPlayer[player] = true

	local projection = project(player, stored, OrbitRadioConfig.ProjectionKind.Hydrate, includeResume)
	projection.ready = true
	return projection
end

-- Every accepted or meaningfully rejected mutation answers with the authoritative
-- projection. That is what lets the UI be optimistic without ever leaving a setting
-- or a favorite on screen that the profile refused: the push either confirms the
-- change or puts the saved value back. "Unchanged" says nothing new, so it is quiet.
local function onPreference(player, field, value)
	local allowed, window = allow(player, "Preference")
	if not allowed then
		scheduleReconcile(player, "Preference", window, OrbitRadioConfig.ProjectionKind.Preferences)
		return
	end
	local stored = getStored(player)
	if not stored then
		return
	end

	local accepted, problem = OrbitRadioProfile.setPreference(stored, field, value)
	if OrbitRadioProfile.shouldReconcile(accepted, problem) then
		push(player, OrbitRadioConfig.ProjectionKind.Preferences)
	end
end

-- `favorited` is passed through as it arrived, not coerced: the profile write path
-- requires a real boolean, so a malformed value is refused and reconciled rather
-- than silently read as "remove this favorite".
local function onFavorite(player, trackId, favorited)
	local allowed, window = allow(player, "Favorite")
	if not allowed then
		scheduleReconcile(player, "Favorite", window, OrbitRadioConfig.ProjectionKind.Library)
		return
	end
	local stored = getStored(player)
	if not stored then
		return
	end

	local accepted, problem = OrbitRadioProfile.setFavorite(stored, trackId, favorited, {
		config = config,
		catalog = getCatalog(),
		unlocks = refreshUnlocks(player, stored),
	})
	if OrbitRadioProfile.shouldReconcile(accepted, problem) then
		push(player, OrbitRadioConfig.ProjectionKind.Library)
	end
end

local function onQueueSnapshot(player, snapshot)
	if not allow(player, "Snapshot") then
		return
	end
	local stored = getStored(player)
	if not stored then
		return
	end
	OrbitRadioProfile.acceptSnapshot(stored, snapshot, {
		now = os.time(),
		config = config,
		catalog = getCatalog(),
		unlocks = refreshUnlocks(player, stored),
	})
end

-- A completion report is three well-formed values: which cue, which presentation ran
-- it, and how that presentation ended. The presentation id is identity, not a
-- capability -- the server never issued it, so it proves nothing on its own and is
-- validated and bounded rather than trusted. What actually decides the reveal is
-- MusicService.RecordEncounter's authoritative facts; this is the message shape that
-- keeps a partial or crafted report from ever reaching them.
local function onCueEncountered(player, cueId, presentationId, reason)
	if not allow(player, "Encounter") then
		return
	end
	if not OrbitRadioProfile.isWellFormedId(cueId) then
		return
	end
	if not OrbitRadioProfile.isWellFormedPresentationId(presentationId) then
		return
	end
	if not MusicTypes.isCompletionReason(reason) then
		-- Cancelled, replaced, failed, and skipped scenes are not encounters.
		return
	end
	MusicService.RecordEncounter(player, cueId)
end

function MusicService.Init()
	local Names = Net.Names

	-- Pre-create both channels so a client that boots first finds them immediately
	-- instead of hanging at WaitForChild.
	Net.fn(Names.MusicRequestState)
	Net.event(Names.MusicStateChanged)

	Net.onInvoke(Names.MusicRequestState, onRequestState)
	Net.on(Names.MusicPreference, onPreference)
	Net.on(Names.MusicFavorite, onFavorite)
	Net.on(Names.MusicQueueSnapshot, onQueueSnapshot)
	Net.on(Names.MusicCueEncountered, onCueEncountered)

	Players.PlayerRemoving:Connect(MusicService.ForgetPlayer)

	print("MusicService initialized")
end

return MusicService
