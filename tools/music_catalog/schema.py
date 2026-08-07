"""Declarative schema for the music CSV catalog.

Two scopes exist. `catalog` tables are the reusable recording/source/artwork
inventory shared by every game that reuses this library. `game` tables belong to
one game directory (`music/clickgame`) and hold that game's display overrides,
pools, cues, permissions, and collections.

Column order is part of the schema: a reader rejects a header that does not match
exactly, so a hand-edited CSV cannot silently drop or rename a field.
"""

from __future__ import annotations

from dataclasses import dataclass

CATALOG = "catalog"
GAME = "game"

TEXT = "text"
ID = "id"
INT = "int"
NUMBER = "number"
FLAG = "flag"
DATE = "date"
ASSET_ID = "asset_id"
SHA256 = "sha256"

YES_NO = ("Yes", "No")
YES_NO_UNKNOWN = ("Yes", "No", "Unknown")
LICENSE_STATUS = ("Approved", "Pending", "Rejected")
MODERATION_STATUS = ("Not Uploaded", "Pending", "Approved", "Rejected")
REVIEW_STATUS = ("Unreviewed", "In Review", "Approved", "Rejected")
GRANT_STATE = ("Not Requested", "Pending", "Granted", "Denied")

TRACK_STATUS = ("Candidate", "Component Only", "Retired")
GROUP_TYPE = (
    "Cohesive Collection",
    "Modular Component Set",
    "Alternate Variants",
    "Intro Loop Pair",
)
GROUP_STATUS = ("Approved", "Candidate", "Needs Arrangement", "Retired")

AUDIENCE_LANE = ("Playful", "Synth", "Crossover")
ENERGY = ("Chill", "Energetic", "Cinematic")
LOOP_QUALITY = ("Good", "Acceptable", "Poor", "Unknown")
OVERRIDE_STATUS = (
    "Approved",
    "Needs Listening Review",
    "Needs Arrangement",
    "Rejected",
    "Disabled",
)

COLLECTION_ROLE = ("Player Collection", "Candidate Set", "Production Workbench")
COLLECTION_UNLOCK = (
    "Always",
    "IndustryFloor",
    "CommerceFloor",
    "ScienceFloor",
    "StoryEncounter",
    "NotBrowsable",
)
COLLECTION_STATUS = ("Approved", "Candidate", "Needs Arrangement", "Disabled")

POOL_UNLOCK = (
    "Always",
    "IndustryFloor",
    "CommerceFloor",
    "ScienceFloor",
    "ContextualOnly",
)
SELECTION_POLICY = (
    "Shuffled Bag",
    "Shuffled Bag With Unlock Boost",
    "Weighted Contextual",
)
ROW_STATUS = ("Approved", "Candidate", "Disabled")

CUE_CLASS = ("Cinematic", "Major Milestone", "Stinger")
LOOP_MODE = ("Loop", "No Loop", "Loop if needed")
CUE_STATUS = ("Approved", "Planned", "Disabled")

CANDIDATE_ROLE = ("Primary Candidate", "Continuation Candidate", "Fallback Candidate")
CANDIDATE_STATUS = ("Needs Listening Review", "Shortlisted", "Promoted", "Rejected")

ASSIGNMENT_ROLE = ("Primary", "Continuation", "Fallback")
ASSIGNMENT_ROLE_ORDER = {role: index for index, role in enumerate(ASSIGNMENT_ROLE)}
END_BEHAVIOR = ("CueDefault", "Advance", "Release")
ASSIGNMENT_STATUS = ("Candidate", "Approved", "Disabled")

ASSET_KIND = ("Track", "Artwork")
EXPERIENCE_STATUS = ("Active", "Planned", "Retired")

# Statuses that mean "deliberately kept out of the runtime catalog". They never
# fail strict mode; every other non-approved state is an incomplete row.
EXCLUDED_TRACK_STATUS = frozenset({"Component Only", "Retired"})
EXCLUDED_REVIEW_STATUS = frozenset({"Rejected"})
EXCLUDED_OVERRIDE_STATUS = frozenset({"Rejected", "Disabled"})
EXCLUDED_ROW_STATUS = frozenset({"Disabled"})


@dataclass(frozen=True)
class Column:
    """One CSV column and everything the reader can check without cross-table data."""

    name: str
    kind: str = TEXT
    required: bool = False
    enum: tuple[str, ...] | None = None
    minimum: float | None = None
    maximum: float | None = None
    reference: str | None = None  # "<table>.<column>"
    description: str = ""


@dataclass(frozen=True)
class Table:
    """One CSV file: its location, primary key, and columns in authored order."""

    name: str
    scope: str
    filename: str
    key: tuple[str, ...]
    columns: tuple[Column, ...]
    singleton: bool = False

    @property
    def column_names(self) -> list[str]:
        return [column.name for column in self.columns]

    def column(self, name: str) -> Column:
        for candidate in self.columns:
            if candidate.name == name:
                return candidate
        raise KeyError(f"{self.name} has no column {name}")


SOURCES = Table(
    name="sources",
    scope=CATALOG,
    filename="sources.csv",
    key=("source_id",),
    columns=(
        Column("source_id", ID, required=True),
        Column("provider", TEXT, required=True),
        Column("pack_title", TEXT, required=True),
        Column("artist"),
        Column("source_url"),
        Column("license_id"),
        Column("license_name"),
        Column("license_status", TEXT, required=True, enum=LICENSE_STATUS),
        Column("commercial_use", TEXT, required=True, enum=YES_NO_UNKNOWN),
        Column("modification_allowed", TEXT, required=True, enum=YES_NO_UNKNOWN),
        Column("credit_required", TEXT, required=True, enum=YES_NO_UNKNOWN),
        Column("preferred_credit"),
        Column("license_evidence"),
        Column("notes"),
    ),
)

TRACK_GROUPS = Table(
    name="track-groups",
    scope=CATALOG,
    filename="track-groups.csv",
    key=("group_id",),
    columns=(
        Column("group_id", ID, required=True),
        Column("source_id", ID, required=True, reference="sources.source_id"),
        Column("group_type", TEXT, required=True, enum=GROUP_TYPE),
        Column("display_name", TEXT, required=True),
        Column("intended_handling"),
        Column("status", TEXT, required=True, enum=GROUP_STATUS),
        Column("notes"),
    ),
)

TRACKS = Table(
    name="tracks",
    scope=CATALOG,
    filename="tracks.csv",
    key=("track_id",),
    columns=(
        Column("track_id", ID, required=True),
        Column("source_id", ID, required=True, reference="sources.source_id"),
        Column("source_pack"),
        Column("archive_member"),
        Column("sha256", SHA256, required=True),
        Column("source_filename"),
        Column("source_title", TEXT, required=True),
        Column("artist"),
        Column("album"),
        Column("genre"),
        Column("release_year"),
        Column("duration_seconds", NUMBER, required=True, minimum=0.001),
        Column("sample_rate_hz", INT, required=True, minimum=1, maximum=48000),
        Column("channels", INT, required=True, minimum=1, maximum=2),
        Column("file_size_bytes", INT, required=True, minimum=1),
        Column("curated_path"),
        Column("source_collection"),
        Column("group_id", ID, reference="track-groups.group_id"),
        Column("component_role"),
        Column("track_status", TEXT, required=True, enum=TRACK_STATUS),
        Column("roblox_import_eligible", FLAG, required=True, enum=YES_NO),
        Column("roblox_asset_id", ASSET_ID),
        Column("upload_owner"),
        Column("moderation_status", TEXT, required=True, enum=MODERATION_STATUS),
        Column("normalized_volume_db", NUMBER, minimum=-30.0, maximum=6.0),
        Column("playback_start_seconds", NUMBER, minimum=0.0),
        Column("playback_end_seconds", NUMBER, minimum=0.0),
        Column("loop_start_seconds", NUMBER, minimum=0.0),
        Column("loop_end_seconds", NUMBER, minimum=0.0),
        Column("review_status", TEXT, required=True, enum=REVIEW_STATUS),
        Column("notes"),
    ),
)

ARTWORK = Table(
    name="artwork",
    scope=CATALOG,
    filename="artwork.csv",
    key=("artwork_id",),
    columns=(
        Column("artwork_id", ID, required=True),
        Column("source_id", ID, required=True, reference="sources.source_id"),
        Column("source_pack"),
        Column("archive_member"),
        Column("sha256", SHA256),
        Column("image_path"),
        Column("display_name", TEXT, required=True),
        Column("license_status", TEXT, required=True, enum=LICENSE_STATUS),
        Column("license_evidence"),
        Column("roblox_asset_id", ASSET_ID),
        Column("upload_owner"),
        Column("moderation_status", TEXT, required=True, enum=MODERATION_STATUS),
        Column("review_status", TEXT, required=True, enum=REVIEW_STATUS),
        Column("notes"),
    ),
)

EXPERIENCE = Table(
    name="experience",
    scope=GAME,
    filename="experience.csv",
    key=("experience_id",),
    singleton=True,
    columns=(
        Column("experience_id", ID, required=True),
        Column("display_name", TEXT, required=True),
        Column("universe_id", ASSET_ID),
        Column("place_id", ASSET_ID),
        Column("status", TEXT, required=True, enum=EXPERIENCE_STATUS),
        Column("notes"),
    ),
)

ASSET_PERMISSIONS = Table(
    name="asset-permissions",
    scope=GAME,
    filename="asset-permissions.csv",
    key=("experience_id", "asset_kind", "asset_ref"),
    columns=(
        Column("experience_id", ID, required=True, reference="experience.experience_id"),
        Column("asset_kind", TEXT, required=True, enum=ASSET_KIND),
        Column("asset_ref", ID, required=True),
        Column("grant_state", TEXT, required=True, enum=GRANT_STATE),
        Column("granted_on", DATE),
        Column("notes"),
    ),
)

COLLECTIONS = Table(
    name="collections",
    scope=GAME,
    filename="collections.csv",
    key=("collection_id",),
    columns=(
        Column("collection_id", ID, required=True),
        Column("display_name", TEXT, required=True),
        Column("purpose"),
        Column("runtime_role", TEXT, required=True, enum=COLLECTION_ROLE),
        Column("unlock_rule", TEXT, required=True, enum=COLLECTION_UNLOCK),
        Column("artwork_id", ID, reference="artwork.artwork_id"),
        Column("source_folders"),
        Column("status", TEXT, required=True, enum=COLLECTION_STATUS),
        Column("notes"),
    ),
)

TRACK_OVERRIDES = Table(
    name="track-overrides",
    scope=GAME,
    filename="track-overrides.csv",
    key=("track_id",),
    columns=(
        Column("track_id", ID, required=True, reference="tracks.track_id"),
        Column("display_title"),
        Column("collection_id", ID, required=True, reference="collections.collection_id"),
        Column("audience_lane", TEXT, enum=AUDIENCE_LANE),
        Column("energy", TEXT, enum=ENERGY),
        Column("dialogue_safe", TEXT, enum=YES_NO_UNKNOWN),
        Column("loop_quality", TEXT, enum=LOOP_QUALITY),
        Column("story_locked", FLAG, required=True, enum=YES_NO),
        Column("favorite_enabled", FLAG, required=True, enum=YES_NO),
        Column("status", TEXT, required=True, enum=OVERRIDE_STATUS),
        Column("notes"),
    ),
)

POOLS = Table(
    name="pools",
    scope=GAME,
    filename="pools.csv",
    key=("pool_id",),
    columns=(
        Column("pool_id", ID, required=True),
        Column("display_name", TEXT, required=True),
        Column("description"),
        Column("unlock_rule", TEXT, required=True, enum=POOL_UNLOCK),
        Column("audience_filter", TEXT, enum=AUDIENCE_LANE),
        Column("target_count", INT, minimum=0, maximum=999),
        Column("selection_policy", TEXT, required=True, enum=SELECTION_POLICY),
        Column("status", TEXT, required=True, enum=ROW_STATUS),
        Column("notes"),
    ),
)

POOL_MEMBERSHIP = Table(
    name="pool-membership",
    scope=GAME,
    filename="pool-membership.csv",
    key=("pool_id", "track_id"),
    columns=(
        Column("pool_id", ID, required=True, reference="pools.pool_id"),
        Column("track_id", ID, required=True, reference="tracks.track_id"),
        Column("weight", NUMBER, required=True, minimum=0.001, maximum=100.0),
        Column("minimum_progression", INT, minimum=0),
        Column("recency_exclusion", INT, required=True, minimum=0, maximum=64),
        Column("status", TEXT, required=True, enum=ROW_STATUS),
        Column("notes"),
    ),
)

CUES = Table(
    name="cues",
    scope=GAME,
    filename="cues.csv",
    key=("cue_id",),
    columns=(
        Column("cue_id", ID, required=True),
        Column("moment", TEXT, required=True),
        Column("cue_class", TEXT, required=True, enum=CUE_CLASS),
        Column("priority", INT, required=True, minimum=0, maximum=1000),
        Column("trigger_contract"),
        Column("playback_behavior"),
        Column("loop_mode", TEXT, required=True, enum=LOOP_MODE),
        Column("default_crossfade_seconds", NUMBER, required=True, minimum=0.0, maximum=30.0),
        Column("fallback_pool", ID, reference="pools.pool_id"),
        Column("story_moments_controls", FLAG, required=True, enum=YES_NO),
        Column("status", TEXT, required=True, enum=CUE_STATUS),
        Column("notes"),
    ),
)

CUE_CANDIDATES = Table(
    name="cue-candidates",
    scope=GAME,
    filename="cue-candidates.csv",
    key=("cue_id", "track_id", "candidate_role"),
    columns=(
        Column("cue_id", ID, required=True, reference="cues.cue_id"),
        Column("track_id", ID, required=True, reference="tracks.track_id"),
        Column("candidate_role", TEXT, required=True, enum=CANDIDATE_ROLE),
        Column("rank", INT, minimum=1, maximum=999),
        Column("status", TEXT, required=True, enum=CANDIDATE_STATUS),
        Column("notes"),
    ),
)

CUE_ASSIGNMENTS = Table(
    name="cue-assignments",
    scope=GAME,
    filename="cue-assignments.csv",
    key=("cue_id", "role", "sequence_order"),
    columns=(
        Column("cue_id", ID, required=True, reference="cues.cue_id"),
        Column("track_id", ID, required=True, reference="tracks.track_id"),
        Column("role", TEXT, required=True, enum=ASSIGNMENT_ROLE),
        Column("sequence_order", INT, required=True, minimum=1, maximum=99),
        Column("start_offset_seconds", NUMBER, minimum=0.0),
        Column("end_behavior", TEXT, required=True, enum=END_BEHAVIOR),
        Column("status", TEXT, required=True, enum=ASSIGNMENT_STATUS),
        Column("notes"),
    ),
)

TABLES: tuple[Table, ...] = (
    SOURCES,
    TRACK_GROUPS,
    TRACKS,
    ARTWORK,
    EXPERIENCE,
    ASSET_PERMISSIONS,
    COLLECTIONS,
    TRACK_OVERRIDES,
    POOLS,
    POOL_MEMBERSHIP,
    CUES,
    CUE_CANDIDATES,
    CUE_ASSIGNMENTS,
)

TABLES_BY_NAME = {table.name: table for table in TABLES}


def token(value: str) -> str:
    """Turn a human-readable controlled value into a stable runtime identifier.

    "Loop if needed" becomes "LoopIfNeeded" and "Not Uploaded" becomes
    "NotUploaded", so CSVs stay readable while runtime comparisons use one word.
    """

    parts = [part for part in "".join(character if character.isalnum() else " " for character in value).split(" ") if part]
    return "".join(part[:1].upper() + part[1:] for part in parts)
