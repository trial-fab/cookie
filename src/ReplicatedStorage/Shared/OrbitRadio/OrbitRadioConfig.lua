-- OrbitRadioConfig -- the ClickGame binding between game progression and the
-- reusable music engine under Shared/Music.
--
-- Shared/Music/* knows nothing about floors, quests, or story steps: it consumes
-- opaque unlock-rule tokens, collection ids, and cue ids. This module is the whole
-- translation layer, and it is deliberately data only:
--
--   * which committed floor unlock grants which engine rule, permanent collection,
--     and one-time cue,
--   * what authoritative state makes a story encounter eligible,
--   * the ingress bounds the server applies to every client music message.
--
-- A sibling game supplies its own version of this file and reuses the engine, the
-- backend, and the UI kit unchanged.

local FloorConfig = require(script.Parent.Parent.FloorConfig)
local MusicTypes = require(script.Parent.Parent.Music.MusicTypes)
local StoryConfig = require(script.Parent.Parent.StoryConfig)

local OrbitRadioConfig = {}

-- Ids are compiler-emitted stable keys (upper snake case). The bound is a storage
-- guard, not a style rule: it stops a crafted message from writing long strings
-- into a saved set.
OrbitRadioConfig.MaxIdLength = 64
OrbitRadioConfig.IdPattern = "^[%w_]+$"

-- A presentation id is the scene owner's own request id, not a compiler-emitted
-- catalog key, so it allows the punctuation an adapter naturally builds one from
-- ("intro-descent:2"). It is bounded for the same reason every other client-supplied
-- id is: it arrives over a remote.
OrbitRadioConfig.MaxPresentationIdLength = 64
OrbitRadioConfig.PresentationIdPattern = "^[%w_%-%.:]+$"

-- Collections that every player owns from the first session. They are never stored
-- in UnlockedCollectionIds because they are not discoveries.
OrbitRadioConfig.AlwaysCollectionIds = table.freeze({ "UNIVERSAL", "GROUND" })

-- The story collection opens per track through cue encounters, never as a whole.
OrbitRadioConfig.StoryCollectionId = "STORY"

OrbitRadioConfig.OpeningArcId = "opening_tutorial"

-- One row per unlockable floor, keyed by the FloorConfig order the Base Expansion
-- upgrade commits. `UnlockRule` is the engine token the pool/collection rows carry;
-- `CollectionId` is the permanent discovery; `CueId` is the one-time milestone the
-- committed purchase response asks the client to play.
local floors = {
	{
		Order = 1,
		UnlockRule = MusicTypes.UnlockRule.IndustryFloor,
		CollectionId = "INDUSTRY",
		CueId = "FLOOR_INDUSTRY_UNLOCK",
	},
	{
		Order = 2,
		UnlockRule = MusicTypes.UnlockRule.CommerceFloor,
		CollectionId = "COMMERCE",
		CueId = "FLOOR_COMMERCE_UNLOCK",
	},
	{
		Order = 3,
		UnlockRule = MusicTypes.UnlockRule.ScienceFloor,
		CollectionId = "SCIENCE",
		CueId = "FLOOR_SCIENCE_UNLOCK",
	},
}

local floorByOrder = {}
local floorById = {}
local floorByCollectionId = {}

for _, entry in ipairs(floors) do
	local definition = FloorConfig.GetByOrder(entry.Order)
	assert(definition, "OrbitRadioConfig references a floor order FloorConfig does not define")
	entry.FloorId = definition.Id
	table.freeze(entry)
	floorByOrder[entry.Order] = entry
	floorById[entry.FloorId] = entry
	floorByCollectionId[entry.CollectionId] = entry
end

assert(
	#floors == FloorConfig.UnlockableFloorCount,
	"OrbitRadioConfig must bind exactly one music identity per unlockable floor"
)

OrbitRadioConfig.Floors = table.freeze(floors)

function OrbitRadioConfig.GetFloorByOrder(order)
	return floorByOrder[tonumber(order)]
end

function OrbitRadioConfig.GetFloorById(floorId)
	return type(floorId) == "string" and floorById[floorId] or nil
end

function OrbitRadioConfig.GetFloorByCollectionId(collectionId)
	return type(collectionId) == "string" and floorByCollectionId[collectionId] or nil
end

-- Requirement tokens evaluated by OrbitRadioProfile.isEncounterEligible against
-- authoritative server facts. A cue that is not listed here can never be recorded
-- as encountered, which is what keeps the reveal gate honest for a crafted message.
--
-- QUEST_COMPLETE_STINGER is deliberately absent: a stinger reveals no story track,
-- so it has nothing to gate and nothing to remember.
OrbitRadioConfig.Requirement = table.freeze({
	IntroSeen = "IntroSeen",
	StoryStepAtLeast = "StoryStepAtLeast",
	MixerUnlocked = "MixerUnlocked",
	ArcCompleted = "ArcCompleted",
	CollectionUnlocked = "CollectionUnlocked",
	HubCoreActivated = "HubCoreActivated",
	Never = "Never",
})

OrbitRadioConfig.StoryCues = table.freeze({
	-- The intro cues finish with the descent, which is the same commit that stamps
	-- IntroSeen through the RubbleCleared story action.
	INTRO_ORBIT = table.freeze({ Requirement = OrbitRadioConfig.Requirement.IntroSeen }),
	INTRO_DESCENT = table.freeze({ Requirement = OrbitRadioConfig.Requirement.IntroSeen }),
	-- Lore, not Healing: StoryService advances the step at the end of finishHealing,
	-- which is exactly "the healing presentation completed". Gating on Healing would
	-- make the reveal claimable for the whole clicking phase, before the moment the
	-- cue is scoring has happened. The scene owner therefore reports this completion
	-- after the authoritative step advances.
	GOO_REVEAL = table.freeze({
		Requirement = OrbitRadioConfig.Requirement.StoryStepAtLeast,
		StoryStep = StoryConfig.STEPS.Lore,
	}),
	-- MixerUnlocked is written by the CompleteLore action, so it is exactly "the
	-- lore scene finished" rather than "the dialogue opened".
	GOOB_LORE = table.freeze({ Requirement = OrbitRadioConfig.Requirement.MixerUnlocked }),
	OPENING_ARC_COMPLETE = table.freeze({
		Requirement = OrbitRadioConfig.Requirement.ArcCompleted,
		ArcId = OrbitRadioConfig.OpeningArcId,
	}),
	-- Floor milestones check the permanent collection, not the current run's floor
	-- count: the encounter must stay claimable in the run after a rebirth.
	FLOOR_INDUSTRY_UNLOCK = table.freeze({
		Requirement = OrbitRadioConfig.Requirement.CollectionUnlocked,
		CollectionId = "INDUSTRY",
	}),
	FLOOR_COMMERCE_UNLOCK = table.freeze({
		Requirement = OrbitRadioConfig.Requirement.CollectionUnlocked,
		CollectionId = "COMMERCE",
	}),
	FLOOR_SCIENCE_UNLOCK = table.freeze({
		Requirement = OrbitRadioConfig.Requirement.CollectionUnlocked,
		CollectionId = "SCIENCE",
	}),
	CORE_EMERGENCE = table.freeze({ Requirement = OrbitRadioConfig.Requirement.HubCoreActivated }),
	OLD_GOO_BACKSTORY = table.freeze({ Requirement = OrbitRadioConfig.Requirement.HubCoreActivated }),
	-- Rebirth has no authoritative implementation yet, so its cue cannot be earned.
	-- Give it a real requirement when the rebirth transaction lands.
	REBIRTH_FINALE = table.freeze({ Requirement = OrbitRadioConfig.Requirement.Never }),
})

local storyStepRank = {}
for index, step in ipairs({
	StoryConfig.STEPS.Meteor,
	StoryConfig.STEPS.Healing,
	StoryConfig.STEPS.Lore,
	StoryConfig.STEPS.BuildTask,
	StoryConfig.STEPS.Complete,
}) do
	storyStepRank[step] = index
end

OrbitRadioConfig.StoryStepRank = table.freeze(storyStepRank)

-- Ingress bounds. None of these messages touches a DataStore -- they mutate the
-- live profile and ride the ordinary autosave -- so the limits exist to bound cost
-- and log noise, not to protect a write budget. Dropping a message is always safe:
-- the worst case is a slightly stale resume position.
OrbitRadioConfig.Limits = table.freeze({
	-- Sliders and toggles are expected to send on commit, not per frame.
	Preference = table.freeze({ Limit = 12, WindowSeconds = 10 }),
	-- Favoriting down a visible list is a legitimate burst.
	Favorite = table.freeze({ Limit = 20, WindowSeconds = 10 }),
	-- Meaningful playback/queue changes send immediately; position refreshes are
	-- client-throttled to MusicConfig.snapshotPositionSeconds.
	Snapshot = table.freeze({ Limit = 8, WindowSeconds = 20 }),
	Encounter = table.freeze({ Limit = 8, WindowSeconds = 20 }),
	RequestState = table.freeze({ Limit = 4, WindowSeconds = 10 }),
})

-- Projection kinds pushed to the owning client.
OrbitRadioConfig.ProjectionKind = table.freeze({
	Hydrate = "Hydrate",
	Library = "Library",
	Progression = "Progression",
	Preferences = "Preferences",
	Reset = "Reset",
})

return OrbitRadioConfig
