"""Cross-table validation and runtime-model construction.

Findings fall into three groups:

* **Integrity** problems are authoring mistakes: duplicate IDs, unresolved
  references, unknown controlled values, invalid playback or loop regions,
  component-only recordings used as finished tracks, malformed cue sequences.
  They fail in both modes because no mode can produce a correct catalog from them.
* **Availability** gaps mean a row is real but not production-ready yet: an
  unapproved source, a missing Roblox asset ID, a missing ClickGame grant,
  unapproved moderation, or a non-approved review/override row. Development mode
  omits those entries with a warning; strict mode fails.
* **Exclusions** are deliberate: component-only or retired recordings, rejected or
  disabled rows, and collections that are curation staging rather than a player
  collection. They are silently kept out of the runtime catalog in both modes.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Iterable

from . import schema
from .reader import ERROR, WARNING, Catalog, Issue, Row

STRICT = "strict"
DEVELOPMENT = "development"
MODES = (DEVELOPMENT, STRICT)

FORMAT_VERSION = 1
REGION_EPSILON = 0.001

EMITTED = "emitted"
EXCLUDED = "excluded"
INCOMPLETE = "incomplete"


@dataclass
class Entity:
    """Resolution state for one catalog row plus the reasons behind it."""

    state: str = EMITTED
    reasons: list[str] = field(default_factory=list)

    def exclude(self, reason: str) -> None:
        self.state = EXCLUDED
        self.reasons.append(reason)

    def incomplete(self, reason: str) -> None:
        if self.state != EXCLUDED:
            self.state = INCOMPLETE
        self.reasons.append(reason)

    @property
    def emitted(self) -> bool:
        return self.state == EMITTED


class Findings:
    """Issue sink that turns availability gaps into the right severity per mode."""

    def __init__(self, mode: str) -> None:
        self.mode = mode
        self.issues: list[Issue] = []

    def error(self, location: str, code: str, message: str) -> None:
        self.issues.append(Issue(location, code, message, ERROR))

    def unavailable(self, location: str, code: str, message: str) -> None:
        severity = ERROR if self.mode == STRICT else WARNING
        suffix = "" if self.mode == STRICT else "; omitted from the development catalog"
        self.issues.append(Issue(location, code, message + suffix, severity))


def _reference_targets(catalog: Catalog) -> dict[str, set[str]]:
    targets: dict[str, set[str]] = {}
    for table in schema.TABLES:
        for column in table.columns:
            if column.reference is None:
                continue
            target_table_name, target_column = column.reference.split(".")
            target_table = schema.TABLES_BY_NAME[target_table_name]
            targets[column.reference] = {
                row.text(target_column) for row in catalog.of(target_table) if row.text(target_column)
            }
    return targets


def check_references(catalog: Catalog, findings: Findings) -> None:
    """Every declared foreign key must name a row that exists."""

    targets = _reference_targets(catalog)
    for table in schema.TABLES:
        for row in catalog.of(table):
            for column in table.columns:
                if column.reference is None:
                    continue
                value = row.text(column.name)
                if not value:
                    continue
                if value not in targets[column.reference]:
                    findings.error(
                        row.location,
                        "unresolved-reference",
                        f"column '{column.name}' references unknown {column.reference} '{value}'",
                    )

    track_ids = catalog.ids(schema.TRACKS)
    artwork_ids = catalog.ids(schema.ARTWORK)
    for row in catalog.of(schema.ASSET_PERMISSIONS):
        kind = row.text("asset_kind")
        ref = row.text("asset_ref")
        if not kind or not ref:
            continue
        known = track_ids if kind == "Track" else artwork_ids
        if ref not in known:
            findings.error(
                row.location,
                "unresolved-reference",
                f"asset_ref '{ref}' is not a known {kind.lower()} record",
            )


def check_sources(catalog: Catalog, findings: Findings) -> None:
    """An approved source that requires credit must actually carry its credit line."""

    for row in catalog.of(schema.SOURCES):
        if row.text("license_status") != "Approved":
            continue
        if row.text("credit_required") == "Yes" and not row.text("preferred_credit"):
            findings.error(
                row.location,
                "missing-credit",
                f"source '{row.text('source_id')}' requires credit but has no preferred_credit",
            )
        if row.text("credit_required") == "Unknown":
            findings.error(
                row.location,
                "unresolved-license-term",
                f"source '{row.text('source_id')}' is approved but its credit requirement is still Unknown",
            )


def resolve_region(row: Row, findings: Findings) -> tuple[float, float, float | None, float | None]:
    """Validate and resolve a recording's playback and loop regions."""

    duration = row.number("duration_seconds") or 0.0
    start = row.number("playback_start_seconds")
    end = row.number("playback_end_seconds")
    loop_start = row.number("loop_start_seconds")
    loop_end = row.number("loop_end_seconds")

    resolved_start = 0.0 if start is None else start
    resolved_end = duration if end is None else end

    if resolved_end > duration + REGION_EPSILON:
        findings.error(
            row.location,
            "invalid-playback-region",
            f"playback_end_seconds {resolved_end} exceeds duration_seconds {duration}",
        )
        resolved_end = duration
    if resolved_start >= resolved_end:
        findings.error(
            row.location,
            "invalid-playback-region",
            f"playback region start {resolved_start} must be less than end {resolved_end}",
        )
        resolved_start, resolved_end = 0.0, duration

    if (loop_start is None) != (loop_end is None):
        findings.error(
            row.location,
            "invalid-loop-region",
            "loop_start_seconds and loop_end_seconds must be set together",
        )
        return resolved_start, resolved_end, None, None

    if loop_start is None or loop_end is None:
        return resolved_start, resolved_end, None, None

    if loop_start >= loop_end:
        findings.error(
            row.location,
            "invalid-loop-region",
            f"loop region start {loop_start} must be less than end {loop_end}",
        )
        return resolved_start, resolved_end, None, None

    if loop_start < resolved_start - REGION_EPSILON or loop_end > resolved_end + REGION_EPSILON:
        findings.error(
            row.location,
            "invalid-loop-region",
            f"loop region {loop_start}-{loop_end} must sit inside the playback region "
            f"{resolved_start}-{resolved_end}",
        )
        return resolved_start, resolved_end, None, None

    return resolved_start, resolved_end, loop_start, loop_end


def _artwork_gaps(row: Row, granted: set[tuple[str, str]], experience_id: str) -> list[str]:
    gaps: list[str] = []
    if row.text("license_status") != "Approved":
        gaps.append(f"artwork license is {row.text('license_status') or 'unset'}")
    if row.text("review_status") != "Approved":
        gaps.append(f"artwork review is {row.text('review_status') or 'unset'}")
    if row.values.get("roblox_asset_id") is None:
        gaps.append("artwork has no roblox_asset_id")
    if row.text("moderation_status") != "Approved":
        gaps.append(f"artwork moderation is {row.text('moderation_status') or 'unset'}")
    if ("Artwork", row.text("artwork_id")) not in granted:
        gaps.append(f"artwork has no Granted permission for {experience_id or 'the experience'}")
    return gaps


def _track_gaps(track: Row, override: Row | None, source: Row | None, granted: set[tuple[str, str]], experience_id: str) -> list[str]:
    gaps: list[str] = []
    if source is None:
        return ["source row is missing"]
    if source.text("license_status") != "Approved":
        gaps.append(f"source license is {source.text('license_status') or 'unset'}")
    if source.text("commercial_use") != "Yes":
        gaps.append(f"source commercial use is {source.text('commercial_use') or 'unset'}")
    if source.text("modification_allowed") != "Yes":
        gaps.append(f"source modification permission is {source.text('modification_allowed') or 'unset'}")

    if track.text("review_status") != "Approved":
        gaps.append(f"track review is {track.text('review_status')}")
    if not track.flag("roblox_import_eligible"):
        gaps.append("track is not Roblox import eligible")
    if track.values.get("roblox_asset_id") is None:
        gaps.append("track has no roblox_asset_id")
    if track.text("moderation_status") != "Approved":
        gaps.append(f"track moderation is {track.text('moderation_status')}")
    if track.values.get("normalized_volume_db") is None:
        gaps.append("track has no measured normalized_volume_db")
    if ("Track", track.text("track_id")) not in granted:
        gaps.append(f"track has no Granted permission for {experience_id or 'the experience'}")

    if override is None:
        gaps.append("no game override row exists")
        return gaps
    if override.text("status") != "Approved":
        gaps.append(f"game override status is {override.text('status')}")
    if not override.text("display_title"):
        gaps.append("game override has no display_title")
    for column in ("audience_lane", "energy"):
        if not override.text(column):
            gaps.append(f"game override has no {column}")
    if override.text("dialogue_safe") not in ("Yes", "No"):
        gaps.append("game override dialogue_safe is unresolved")
    if override.text("loop_quality") in ("", "Unknown"):
        gaps.append("game override loop_quality is unresolved")
    return gaps


def _assignment_chains(rows: Iterable[Row]) -> dict[tuple[str, str], list[Row]]:
    chains: dict[tuple[str, str], list[Row]] = {}
    for row in rows:
        role = row.text("role")
        chain_role = "Fallback" if role == "Fallback" else "Main"
        chains.setdefault((row.text("cue_id"), chain_role), []).append(row)
    for chain in chains.values():
        chain.sort(
            key=lambda row: (
                schema.ASSIGNMENT_ROLE_ORDER.get(row.text("role"), 99),
                row.integer("sequence_order") or 0,
                row.text("track_id"),
            )
        )
    return chains


def check_cue_assignments(catalog: Catalog, findings: Findings, regions: dict[str, tuple[float, float]]) -> None:
    """Cue sequences must be well formed before any of them can be emitted."""

    active = [row for row in catalog.of(schema.CUE_ASSIGNMENTS) if row.text("status") != "Disabled"]

    primaries: dict[str, list[Row]] = {}
    for row in active:
        if row.text("role") == "Primary":
            primaries.setdefault(row.text("cue_id"), []).append(row)
            if (row.integer("sequence_order") or 0) != 1:
                findings.error(
                    row.location,
                    "invalid-cue-sequence",
                    "a Primary assignment must use sequence_order 1",
                )

    for cue_id, rows in sorted(primaries.items()):
        if len(rows) > 1:
            for row in rows[1:]:
                findings.error(
                    row.location,
                    "duplicate-cue-primary",
                    f"cue '{cue_id}' already has a Primary assignment on line {rows[0].line}",
                )

    for row in active:
        cue_id = row.text("cue_id")
        if row.text("role") != "Primary" and cue_id not in primaries:
            findings.error(
                row.location,
                "invalid-cue-sequence",
                f"cue '{cue_id}' has a {row.text('role')} assignment but no Primary assignment",
            )

    chains = _assignment_chains(active)
    for chain in chains.values():
        for position, row in enumerate(chain):
            if row.text("end_behavior") != "Advance":
                continue
            if position == len(chain) - 1:
                findings.error(
                    row.location,
                    "invalid-cue-sequence",
                    "end_behavior 'Advance' requires a following sequence row in the same cue",
                )

    # start_offset_seconds is measured from the start of the track's playback
    # region, so an authored region trim and a cue-point start compose instead of
    # fighting each other.
    for row in active:
        offset = row.number("start_offset_seconds") or 0.0
        region = regions.get(row.text("track_id"))
        if region is None:
            continue
        start, end = region
        if start + offset >= end - REGION_EPSILON:
            findings.error(
                row.location,
                "invalid-playback-region",
                f"start_offset_seconds {offset} lands outside the track playback region {start}-{end}",
            )


def compute_input_digest(catalog: Catalog) -> str:
    """Hash the parsed input so the generated module records what produced it.

    The digest is taken over key-sorted raw values, so reordering rows in a CSV
    cannot change it and neither can the absolute path of the repository.
    """

    hasher = hashlib.sha256()
    for table in schema.TABLES:
        hasher.update(f"\n#{table.name}\n".encode("utf-8"))
        rows = sorted(catalog.of(table), key=lambda row, table=table: row.key(table))
        for row in rows:
            line = "|".join(f"{column.name}={row.raw.get(column.name, '')}" for column in table.columns)
            hasher.update((line + "\n").encode("utf-8"))
    return hasher.hexdigest()


def build_model(catalog: Catalog, mode: str) -> tuple[dict[str, object] | None, list[Issue]]:
    """Validate the catalog and build the runtime model for the requested mode."""

    if mode not in MODES:
        raise ValueError(f"unknown compiler mode '{mode}'")

    findings = Findings(mode)
    check_references(catalog, findings)
    check_sources(catalog, findings)

    experience_rows = catalog.of(schema.EXPERIENCE)
    experience_id = experience_rows[0].text("experience_id") if experience_rows else ""

    granted: set[tuple[str, str]] = set()
    for row in catalog.of(schema.ASSET_PERMISSIONS):
        if row.text("experience_id") == experience_id and row.text("grant_state") == "Granted":
            granted.add((row.text("asset_kind"), row.text("asset_ref")))

    sources = {row.text("source_id"): row for row in catalog.of(schema.SOURCES)}
    artwork = {row.text("artwork_id"): row for row in catalog.of(schema.ARTWORK)}
    overrides = {row.text("track_id"): row for row in catalog.of(schema.TRACK_OVERRIDES)}
    collections = {row.text("collection_id"): row for row in catalog.of(schema.COLLECTIONS)}

    regions: dict[str, tuple[float, float]] = {}
    loops: dict[str, tuple[float, float] | None] = {}
    for row in catalog.of(schema.TRACKS):
        start, end, loop_start, loop_end = resolve_region(row, findings)
        regions[row.text("track_id")] = (start, end)
        loops[row.text("track_id")] = None if loop_start is None or loop_end is None else (loop_start, loop_end)

    check_cue_assignments(catalog, findings, regions)

    # --- collections -----------------------------------------------------
    collection_states: dict[str, Entity] = {}
    emitted_collections: list[dict[str, object]] = []
    for row in sorted(catalog.of(schema.COLLECTIONS), key=lambda row: row.text("collection_id")):
        collection_id = row.text("collection_id")
        entity = Entity()
        collection_states[collection_id] = entity
        if row.text("runtime_role") != "Player Collection":
            entity.exclude(f"runtime role is {row.text('runtime_role')}")
            continue
        if row.text("status") == "Disabled":
            entity.exclude("collection is Disabled")
            continue
        if row.text("status") != "Approved":
            entity.incomplete(f"collection status is {row.text('status')}")

        artwork_asset: int | None = None
        artwork_id = row.text("artwork_id")
        if artwork_id:
            artwork_row = artwork.get(artwork_id)
            if artwork_row is not None:
                gaps = _artwork_gaps(artwork_row, granted, experience_id)
                if gaps:
                    findings.unavailable(
                        row.location,
                        "unapproved-artwork",
                        f"collection '{collection_id}' artwork '{artwork_id}' is not usable: {'; '.join(gaps)}",
                    )
                else:
                    artwork_asset = int(artwork_row.values["roblox_asset_id"])  # type: ignore[arg-type]

        if entity.state == INCOMPLETE:
            findings.unavailable(
                row.location,
                "unapproved-collection",
                f"collection '{collection_id}' is not production ready: {'; '.join(entity.reasons)}",
            )
            continue

        emitted_collections.append(
            {
                "id": collection_id,
                "displayName": row.text("display_name"),
                "nameKey": f"Music.Collection.{collection_id}.Name",
                "unlockRule": row.text("unlock_rule"),
                "unlockCopyKey": f"Music.Collection.{collection_id}.Unlock",
                "artworkAssetId": artwork_asset,
                "trackIds": [],
            }
        )
    collection_by_id = {entry["id"]: entry for entry in emitted_collections}

    # --- tracks ----------------------------------------------------------
    track_states: dict[str, Entity] = {}
    emitted_tracks: list[dict[str, object]] = []
    for row in sorted(catalog.of(schema.TRACKS), key=lambda row: row.text("track_id")):
        track_id = row.text("track_id")
        entity = Entity()
        track_states[track_id] = entity
        override = overrides.get(track_id)

        if row.text("track_status") in schema.EXCLUDED_TRACK_STATUS:
            entity.exclude(f"track status is {row.text('track_status')}")
            continue
        if row.text("review_status") in schema.EXCLUDED_REVIEW_STATUS:
            entity.exclude(f"track review is {row.text('review_status')}")
            continue
        if override is not None and override.text("status") in schema.EXCLUDED_OVERRIDE_STATUS:
            entity.exclude(f"game override status is {override.text('status')}")
            continue
        collection_id = override.text("collection_id") if override is not None else ""
        collection_state = collection_states.get(collection_id)
        if collection_state is not None and collection_state.state == EXCLUDED:
            entity.exclude(f"collection '{collection_id}' is not a player collection")
            continue

        gaps = _track_gaps(row, override, sources.get(row.text("source_id")), granted, experience_id)
        if collection_state is not None and collection_state.state == INCOMPLETE:
            gaps.append(f"collection '{collection_id}' is not production ready")
        if gaps:
            for gap in gaps:
                entity.incomplete(gap)
            findings.unavailable(
                row.location,
                "unavailable-track",
                f"track '{track_id}' is not production ready: {'; '.join(gaps)}",
            )
            continue

        assert override is not None
        start, end = regions[track_id]
        loop = loops[track_id]
        emitted_tracks.append(
            {
                "id": track_id,
                "title": override.text("display_title"),
                "titleKey": f"Music.Track.{track_id}.Title",
                "artist": row.text("artist"),
                "sourceId": row.text("source_id"),
                "collectionId": override.text("collection_id"),
                "audienceLane": override.text("audience_lane"),
                "energy": override.text("energy"),
                "dialogueSafe": override.text("dialogue_safe") == "Yes",
                "loopQuality": override.text("loop_quality"),
                "storyLocked": override.flag("story_locked"),
                "favoriteEnabled": override.flag("favorite_enabled"),
                "assetId": int(row.values["roblox_asset_id"]),  # type: ignore[arg-type]
                "durationSeconds": row.number("duration_seconds"),
                "normalizedVolumeDb": row.number("normalized_volume_db"),
                "playbackStartSeconds": start,
                "playbackEndSeconds": end,
                "loopStartSeconds": None if loop is None else loop[0],
                "loopEndSeconds": None if loop is None else loop[1],
            }
        )

    for entry in emitted_tracks:
        collection = collection_by_id.get(entry["collectionId"])
        if collection is not None:
            collection["trackIds"].append(entry["id"])  # type: ignore[union-attr]
    title_by_id = {entry["id"]: entry["title"] for entry in emitted_tracks}
    for collection in emitted_collections:
        collection["trackIds"].sort(key=lambda track_id: (title_by_id[track_id], track_id))  # type: ignore[union-attr]

    emitted_track_ids = {entry["id"] for entry in emitted_tracks}

    # --- pools -----------------------------------------------------------
    emitted_pools: list[dict[str, object]] = []
    memberships: dict[str, list[Row]] = {}
    for row in catalog.of(schema.POOL_MEMBERSHIP):
        memberships.setdefault(row.text("pool_id"), []).append(row)

    for row in sorted(catalog.of(schema.POOLS), key=lambda row: row.text("pool_id")):
        pool_id = row.text("pool_id")
        if row.text("status") == "Disabled":
            continue

        entries: list[dict[str, object]] = []
        for member in sorted(memberships.get(pool_id, []), key=lambda member: member.text("track_id")):
            track_id = member.text("track_id")
            if member.text("status") == "Disabled":
                continue
            member_state = track_states.get(track_id)
            if member_state is not None and member_state.state == EXCLUDED:
                findings.error(
                    member.location,
                    "excluded-track-referenced",
                    f"pool '{pool_id}' references track '{track_id}' which is excluded from playback: "
                    f"{'; '.join(member_state.reasons)}",
                )
                continue
            if member.text("status") != "Approved":
                findings.unavailable(
                    member.location,
                    "unapproved-pool-membership",
                    f"pool '{pool_id}' membership for '{track_id}' is {member.text('status')}",
                )
                continue
            if track_id not in emitted_track_ids:
                continue
            entries.append(
                {
                    "trackId": track_id,
                    "weight": member.number("weight"),
                    "recencyExclusion": member.integer("recency_exclusion"),
                    "minimumProgression": member.integer("minimum_progression"),
                }
            )

        if row.text("status") != "Approved":
            findings.unavailable(
                row.location,
                "unapproved-pool",
                f"pool '{pool_id}' status is {row.text('status')}",
            )
        elif not entries:
            findings.unavailable(
                row.location,
                "empty-pool",
                f"pool '{pool_id}' has no playable approved member",
            )

        emitted_pools.append(
            {
                "id": pool_id,
                "displayName": row.text("display_name"),
                "unlockRule": row.text("unlock_rule"),
                "audienceFilter": row.text("audience_filter") or None,
                "targetCount": row.integer("target_count"),
                "selectionPolicy": schema.token(row.text("selection_policy")),
                "entries": entries,
            }
        )

    # --- cues ------------------------------------------------------------
    assignments: dict[str, list[Row]] = {}
    for row in catalog.of(schema.CUE_ASSIGNMENTS):
        assignments.setdefault(row.text("cue_id"), []).append(row)

    emitted_cues: list[dict[str, object]] = []
    for row in sorted(catalog.of(schema.CUES), key=lambda row: row.text("cue_id")):
        cue_id = row.text("cue_id")
        if row.text("status") == "Disabled":
            continue

        entries = []
        has_primary = False
        for assignment in sorted(
            assignments.get(cue_id, []),
            key=lambda assignment: (
                schema.ASSIGNMENT_ROLE_ORDER.get(assignment.text("role"), 99),
                assignment.integer("sequence_order") or 0,
                assignment.text("track_id"),
            ),
        ):
            track_id = assignment.text("track_id")
            if assignment.text("status") == "Disabled":
                continue
            assignment_state = track_states.get(track_id)
            if assignment_state is not None and assignment_state.state == EXCLUDED:
                findings.error(
                    assignment.location,
                    "excluded-track-referenced",
                    f"cue '{cue_id}' references track '{track_id}' which is excluded from playback: "
                    f"{'; '.join(assignment_state.reasons)}",
                )
                continue
            if assignment.text("status") != "Approved":
                findings.unavailable(
                    assignment.location,
                    "unapproved-cue-assignment",
                    f"cue '{cue_id}' assignment for '{track_id}' is {assignment.text('status')}",
                )
                continue
            if track_id not in emitted_track_ids:
                continue
            if assignment.text("role") == "Primary":
                has_primary = True
            entries.append(
                {
                    "trackId": track_id,
                    "role": assignment.text("role"),
                    "sequenceOrder": assignment.integer("sequence_order"),
                    "startOffsetSeconds": assignment.number("start_offset_seconds") or 0.0,
                    "endBehavior": assignment.text("end_behavior"),
                }
            )

        if row.text("status") != "Approved":
            findings.unavailable(
                row.location,
                "unapproved-cue",
                f"cue '{cue_id}' status is {row.text('status')}",
            )
        elif not has_primary:
            findings.unavailable(
                row.location,
                "cue-without-primary",
                f"cue '{cue_id}' has no approved playable Primary assignment",
            )

        emitted_cues.append(
            {
                "id": cue_id,
                "cueClass": schema.token(row.text("cue_class")),
                "priority": row.integer("priority"),
                "loopMode": schema.token(row.text("loop_mode")),
                "crossfadeSeconds": row.number("default_crossfade_seconds"),
                "fallbackPoolId": row.text("fallback_pool") or None,
                "storyMomentsControlled": row.flag("story_moments_controls"),
                "assignments": entries,
            }
        )

    # --- component-only misuse ------------------------------------------
    component_only = {
        row.text("track_id")
        for row in catalog.of(schema.TRACKS)
        if row.text("track_status") == "Component Only"
    }
    for table in (schema.POOL_MEMBERSHIP, schema.CUE_ASSIGNMENTS):
        for row in catalog.of(table):
            if row.text("status") == "Disabled":
                continue
            if row.text("track_id") in component_only:
                findings.error(
                    row.location,
                    "component-only-track-used",
                    f"track '{row.text('track_id')}' is a Component Only recording and cannot be used "
                    f"as a finished track in {table.name}",
                )

    credits = [
        {
            "sourceId": row.text("source_id"),
            "provider": row.text("provider"),
            "packTitle": row.text("pack_title"),
            "artist": row.text("artist"),
            "licenseId": row.text("license_id"),
            "credit": row.text("preferred_credit"),
        }
        for row in sorted(catalog.of(schema.SOURCES), key=lambda row: row.text("source_id"))
        if row.text("source_id") in {entry["sourceId"] for entry in emitted_tracks}
    ]

    if mode == STRICT and not emitted_tracks:
        findings.error(
            "tracks.csv",
            "empty-runtime-catalog",
            "strict mode requires at least one production-ready track",
        )

    model = {
        "formatVersion": FORMAT_VERSION,
        "mode": mode,
        "experienceId": experience_id,
        "inputDigest": compute_input_digest(catalog),
        "credits": credits,
        "collections": emitted_collections,
        "tracks": emitted_tracks,
        "pools": emitted_pools,
        "cues": emitted_cues,
    }
    return model, findings.issues
