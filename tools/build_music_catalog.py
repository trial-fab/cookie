#!/usr/bin/env python3
"""Build the Tallbeard recording catalog from local curated OGGs and source ZIPs.

The generated technical columns are refreshed on each run. Human-maintained
columns are preserved by stable track_id, so later catalog additions do not
erase Roblox upload state or listening notes.

Column names and controlled values must stay in step with
tools/music_catalog/schema.py, which the catalog compiler validates against.
Per-experience grants live in music/<game>/asset-permissions.csv, not here.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import re
import struct
import zipfile
from pathlib import Path


FIELDS = [
    "track_id",
    "source_id",
    "source_pack",
    "archive_member",
    "sha256",
    "source_filename",
    "source_title",
    "artist",
    "album",
    "genre",
    "release_year",
    "duration_seconds",
    "sample_rate_hz",
    "channels",
    "file_size_bytes",
    "curated_path",
    "source_collection",
    "group_id",
    "component_role",
    "track_status",
    "roblox_import_eligible",
    "roblox_asset_id",
    "upload_owner",
    "moderation_status",
    "normalized_volume_db",
    "playback_start_seconds",
    "playback_end_seconds",
    "loop_start_seconds",
    "loop_end_seconds",
    "review_status",
    "notes",
]

EDITABLE_FIELDS = {
    "group_id",
    "component_role",
    "track_status",
    "roblox_asset_id",
    "upload_owner",
    "moderation_status",
    "normalized_volume_db",
    "playback_start_seconds",
    "playback_end_seconds",
    "loop_start_seconds",
    "loop_end_seconds",
    "review_status",
    "notes",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_track_id(stem: str) -> str:
    normalized = re.sub(r"[^A-Z0-9]+", "_", stem.upper()).strip("_")
    return f"TB_{normalized}"


def read_packets(data: bytes) -> tuple[list[bytes], int]:
    packets: list[bytes] = []
    current = bytearray()
    position = 0
    final_granule = 0

    while position < len(data):
        if data[position : position + 4] != b"OggS":
            raise ValueError(f"invalid Ogg page at byte {position}")
        if position + 27 > len(data):
            raise ValueError("truncated Ogg page header")

        granule = struct.unpack_from("<Q", data, position + 6)[0]
        segment_count = data[position + 26]
        table_start = position + 27
        table_end = table_start + segment_count
        segments = data[table_start:table_end]
        body_position = table_end

        for segment_length in segments:
            segment_end = body_position + segment_length
            current.extend(data[body_position:segment_end])
            body_position = segment_end
            if segment_length < 255:
                packets.append(bytes(current))
                current.clear()

        if granule != 0xFFFFFFFFFFFFFFFF:
            final_granule = max(final_granule, granule)
        position = body_position

    return packets, final_granule


def parse_comments(packet: bytes) -> dict[str, str]:
    if not packet.startswith(b"\x03vorbis"):
        return {}
    position = 7
    vendor_length = struct.unpack_from("<I", packet, position)[0]
    position += 4 + vendor_length
    comment_count = struct.unpack_from("<I", packet, position)[0]
    position += 4
    comments: dict[str, str] = {}
    for _ in range(comment_count):
        length = struct.unpack_from("<I", packet, position)[0]
        position += 4
        raw = packet[position : position + length].decode("utf-8", errors="replace")
        position += length
        if "=" in raw:
            key, value = raw.split("=", 1)
            comments.setdefault(key.upper(), value)
    return comments


def ogg_metadata(data: bytes) -> dict[str, object]:
    packets, final_granule = read_packets(data)
    identification = next((p for p in packets if p.startswith(b"\x01vorbis")), None)
    if identification is None or len(identification) < 16:
        raise ValueError("missing Vorbis identification packet")
    channels = identification[11]
    sample_rate = struct.unpack_from("<I", identification, 12)[0]
    comments_packet = next((p for p in packets if p.startswith(b"\x03vorbis")), b"")
    comments = parse_comments(comments_packet)
    return {
        "channels": channels,
        "sample_rate_hz": sample_rate,
        "duration_seconds": final_granule / sample_rate,
        "comments": comments,
    }


def source_defaults(path: Path) -> tuple[str, str, str]:
    stem = path.stem
    if stem.startswith("Interior Birdecorator"):
        role = "Standalone"
        if stem == "Interior Birdecorator Explore":
            role = "Base"
        elif stem.startswith("Interior Birdecorator Explore_"):
            role = f"Variant: {stem.rsplit('_', 1)[1].title()}"
        elif stem.endswith("Menu_IN"):
            role = "Intro"
        elif stem.endswith("Menu_LOOP"):
            role = "Loop"
        return "TB_INTERIOR_BIRDECORATOR", role, "Candidate"
    if stem.startswith("Sketchbook 2025-12-11_"):
        return "TB_SKETCHBOOK_2025_12_11", stem.rsplit("_", 1)[1].title(), "Component Only"
    if stem.startswith("Sketchbook 2024-07-19_L"):
        return "TB_SKETCHBOOK_2024_07_19", stem.rsplit("_", 1)[1], "Component Only"
    if stem.startswith("Week 5 - Seven Reasons Why "):
        return "TB_SEVEN_REASONS_WHY", stem.rsplit(" ", 1)[1].title(), "Component Only"
    if stem.startswith("Sketchbook 2025-12-17_"):
        return "TB_SKETCHBOOK_2025_12_17", f"Variant: {stem.rsplit('_', 1)[1].title()}", "Candidate"
    return "", "Standalone", "Candidate"


def read_existing(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as handle:
        return {row["track_id"]: row for row in csv.DictReader(handle)}


def read_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def write_rows(path: Path, fields: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def sync_clickgame_rows(repo_root: Path, tracks: list[dict[str, str]]) -> None:
    game_dir = repo_root / "music" / "clickgame"

    override_fields = [
        "track_id",
        "display_title",
        "collection_id",
        "audience_lane",
        "energy",
        "dialogue_safe",
        "loop_quality",
        "story_locked",
        "favorite_enabled",
        "status",
        "notes",
    ]
    override_path = game_dir / "track-overrides.csv"
    existing_overrides = {row["track_id"]: row for row in read_rows(override_path)}
    # Durable collection IDs from music/clickgame/collections.csv, keyed by the
    # temporary curation folder the file arrived in.
    collection_by_source = {
        "cohesive": "INTERIOR_BIRDECORATOR",
        "end": "STORY",
        "finance": "COMMERCE",
        "industry": "INDUSTRY",
        "intro": "STORY",
        "old slime": "STORY",
        "post-intro": "GROUND",
        "put together": "WORKBENCH",
        "science": "SCIENCE",
        "universal": "UNIVERSAL",
    }
    overrides: list[dict[str, str]] = []
    for track in tracks:
        previous = existing_overrides.get(track["track_id"], {})
        defaults = {
            "track_id": track["track_id"],
            "display_title": "",
            "collection_id": collection_by_source[track["source_collection"]],
            "audience_lane": "",
            "energy": "",
            "dialogue_safe": "",
            "loop_quality": "",
            "story_locked": "Yes" if track["source_collection"] in {"intro", "old slime", "end"} else "No",
            "favorite_enabled": "No" if track["track_status"] == "Component Only" else "Yes",
            "status": "Needs Arrangement" if track["track_status"] == "Component Only" else "Needs Listening Review",
            "notes": "",
        }
        defaults.update({field: value for field, value in previous.items() if field in override_fields})
        overrides.append(defaults)
    write_rows(override_path, override_fields, overrides)

    membership_fields = [
        "pool_id",
        "track_id",
        "weight",
        "minimum_progression",
        "recency_exclusion",
        "status",
        "notes",
    ]
    membership_path = game_dir / "pool-membership.csv"
    valid_track_ids = {track["track_id"] for track in tracks}
    memberships = [
        row for row in read_rows(membership_path) if row.get("track_id") in valid_track_ids
    ]
    membership_keys = {(row["pool_id"], row["track_id"]) for row in memberships}
    pool_by_source = {
        "universal": "UNIVERSAL",
        "post-intro": "EARLY_GAME",
        "industry": "INDUSTRY",
        "finance": "COMMERCE",
        "science": "SCIENCE",
    }
    for track in tracks:
        pool_id = pool_by_source.get(track["source_collection"])
        key = (pool_id, track["track_id"])
        if pool_id and key not in membership_keys:
            memberships.append(
                {
                    "pool_id": pool_id,
                    "track_id": track["track_id"],
                    "weight": "1.0",
                    "minimum_progression": "",
                    "recency_exclusion": "8",
                    "status": "Candidate",
                    "notes": "Seeded from the original curation folder; confirm by listening.",
                }
            )
            membership_keys.add(key)
    memberships.sort(key=lambda row: (row["pool_id"], row["track_id"]))
    write_rows(membership_path, membership_fields, memberships)

    candidate_fields = ["cue_id", "track_id", "candidate_role", "rank", "status", "notes"]
    candidate_path = game_dir / "cue-candidates.csv"
    candidates = [
        row for row in read_rows(candidate_path) if row.get("track_id") in valid_track_ids
    ]
    candidate_keys = {(row["cue_id"], row["track_id"]) for row in candidates}
    cues_by_source = {
        "intro": ("INTRO_ORBIT", "INTRO_DESCENT"),
        "old slime": ("CORE_EMERGENCE", "OLD_GOO_BACKSTORY"),
        "end": ("REBIRTH_FINALE",),
    }
    for track in tracks:
        for cue_id in cues_by_source.get(track["source_collection"], ()):
            key = (cue_id, track["track_id"])
            if key not in candidate_keys:
                candidates.append(
                    {
                        "cue_id": cue_id,
                        "track_id": track["track_id"],
                        "candidate_role": "Primary Candidate",
                        "rank": "",
                        "status": "Needs Listening Review",
                        "notes": "Seeded from the original curation folder; not yet assigned.",
                    }
                )
                candidate_keys.add(key)
    candidates.sort(key=lambda row: (row["cue_id"], row["track_id"]))
    write_rows(candidate_path, candidate_fields, candidates)


def archive_index(archives_dir: Path) -> dict[str, list[tuple[str, str]]]:
    index: dict[str, list[tuple[str, str]]] = {}
    for archive_path in sorted(archives_dir.glob("*.zip")):
        with zipfile.ZipFile(archive_path) as archive:
            for member in archive.infolist():
                if member.is_dir() or not member.filename.lower().endswith(".ogg"):
                    continue
                digest = sha256_bytes(archive.read(member))
                index.setdefault(digest, []).append((archive_path.stem, member.filename))
    return index


def build(repo_root: Path) -> tuple[int, int]:
    curated_dir = repo_root / "music" / "curated"
    archives_dir = repo_root / "music" / "archives"
    output_path = repo_root / "music" / "catalog" / "tracks.csv"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    existing = read_existing(output_path)
    existing_by_sha = {row.get("sha256", ""): row for row in existing.values() if row.get("sha256")}
    sources = archive_index(archives_dir)
    rows: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    archive_members_used = 0

    for path in sorted(curated_dir.rglob("*.ogg")):
        data = path.read_bytes()
        digest = sha256_bytes(data)
        matches = sources.get(digest, [])
        if len(matches) != 1:
            raise RuntimeError(f"{path}: expected one archive match, found {len(matches)}")
        source_pack, archive_member = matches[0]
        archive_members_used += 1

        track_id = existing_by_sha.get(digest, {}).get("track_id") or stable_track_id(path.stem)
        if track_id in seen_ids:
            raise RuntimeError(f"duplicate generated track ID: {track_id}")
        seen_ids.add(track_id)

        metadata = ogg_metadata(data)
        comments = metadata["comments"]
        relative = path.relative_to(repo_root).as_posix()
        collection = path.relative_to(curated_dir).parts[0]
        group_id, component_role, track_status = source_defaults(path)
        duration = float(metadata["duration_seconds"])
        sample_rate = int(metadata["sample_rate_hz"])
        eligible = duration < 420 and len(data) < 20 * 1024 * 1024 and sample_rate <= 48000

        row = {
            "track_id": track_id,
            "source_id": "TALLBEARD_MUSIC_LOOP_BUNDLE",
            "source_pack": source_pack,
            "archive_member": archive_member,
            "sha256": digest,
            "source_filename": path.name,
            "source_title": comments.get("TITLE", path.stem),
            "artist": comments.get("ARTIST", "Abstraction"),
            "album": comments.get("ALBUM", ""),
            "genre": comments.get("GENRE", ""),
            "release_year": comments.get("DATE", comments.get("YEAR", "")),
            "duration_seconds": f"{duration:.3f}",
            "sample_rate_hz": str(sample_rate),
            "channels": str(metadata["channels"]),
            "file_size_bytes": str(len(data)),
            "curated_path": relative,
            "source_collection": collection,
            "group_id": group_id,
            "component_role": component_role,
            "track_status": track_status,
            "roblox_import_eligible": "Yes" if eligible else "No",
            "roblox_asset_id": "",
            "upload_owner": "",
            "moderation_status": "Not Uploaded",
            "normalized_volume_db": "",
            "playback_start_seconds": "",
            "playback_end_seconds": "",
            "loop_start_seconds": "",
            "loop_end_seconds": "",
            "review_status": "Unreviewed",
            "notes": "",
        }
        previous = existing.get(track_id, {})
        for field in EDITABLE_FIELDS:
            if previous.get(field, ""):
                row[field] = previous[field]
        rows.append(row)

    write_rows(output_path, FIELDS, rows)
    sync_clickgame_rows(repo_root, rows)
    return len(rows), archive_members_used


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="ClickGame repository root",
    )
    args = parser.parse_args()
    track_count, matched_count = build(args.repo_root.resolve())
    print(f"Wrote {track_count} tracks; matched {matched_count} curated files to source archives.")


if __name__ == "__main__":
    main()
