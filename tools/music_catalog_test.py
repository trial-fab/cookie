#!/usr/bin/env python3
"""Fixture-driven tests for the music catalog compiler.

Every case starts from the tiny catalog under `tools/fixtures/music-catalog`,
applies one mutation to a copy of it, and asserts what the compiler does. The
happy-path cases also pin determinism: the same input must produce byte-identical
output, and reordering rows inside the CSVs must not change a single byte.

    python3 tools/music_catalog_test.py
    python3 tools/music_catalog_test.py --update   # refresh the golden modules
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from music_catalog.cli import CompileResult, compile_catalog  # noqa: E402
from music_catalog.validate import DEVELOPMENT, STRICT  # noqa: E402

FIXTURE = ROOT / "tools/fixtures/music-catalog"
EXPECTED = FIXTURE / "expected"

Edit = Callable[[Path], None]

failures: list[str] = []
passed = 0


# --- mutation helpers -----------------------------------------------------


def replace(relative: str, old: str, new: str) -> Edit:
    def edit(root: Path) -> None:
        path = root / relative
        text = path.read_text(encoding="utf-8")
        if old not in text:
            raise AssertionError(f"{relative} does not contain {old!r}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    return edit


def append(relative: str, line: str) -> Edit:
    def edit(root: Path) -> None:
        path = root / relative
        path.write_text(path.read_text(encoding="utf-8") + line + "\n", encoding="utf-8")

    return edit


def drop(relative: str, contains: str) -> Edit:
    def edit(root: Path) -> None:
        path = root / relative
        lines = path.read_text(encoding="utf-8").splitlines()
        kept = [line for line in lines if contains not in line]
        if len(kept) == len(lines):
            raise AssertionError(f"{relative} has no line containing {contains!r}")
        path.write_text("\n".join(kept) + "\n", encoding="utf-8")

    return edit


def remove_file(relative: str) -> Edit:
    def edit(root: Path) -> None:
        (root / relative).unlink()

    return edit


def reverse_rows(root: Path) -> None:
    for path in sorted(root.rglob("*.csv")):
        lines = path.read_text(encoding="utf-8").splitlines()
        path.write_text("\n".join(lines[:1] + list(reversed(lines[1:]))) + "\n", encoding="utf-8")


# --- harness --------------------------------------------------------------


def run(mode: str, edits: list[Edit]) -> CompileResult:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "music"
        shutil.copytree(FIXTURE, root)
        shutil.rmtree(root / "expected", ignore_errors=True)
        for edit in edits:
            edit(root)
        return compile_catalog(root / "catalog", root / "game", mode)


def record(name: str, condition: bool, detail: str = "") -> None:
    global passed
    if condition:
        passed += 1
    else:
        failures.append(f"{name}: {detail}")


def expect_failure(name: str, mode: str, edits: list[Edit], code: str, contains: str = "") -> None:
    result = run(mode, edits)
    codes = [issue.code for issue in result.errors]
    if result.ok:
        record(name, False, f"expected {code} but the {mode} compile succeeded")
        return
    if code not in codes:
        record(name, False, f"expected {code}, got {sorted(set(codes))}")
        return
    if contains:
        matches = [issue for issue in result.errors if issue.code == code and contains in issue.message]
        if not matches:
            record(name, False, f"no {code} message contained {contains!r}")
            return
    record(name, True)


def expect_success(name: str, mode: str, edits: list[Edit], check: Callable[[CompileResult], str] | None = None) -> None:
    result = run(mode, edits)
    if not result.ok:
        record(name, False, f"unexpected errors: {[issue.format() for issue in result.errors][:3]}")
        return
    detail = check(result) if check is not None else ""
    record(name, not detail, detail)


# --- happy path and determinism ------------------------------------------


def check_strict_shape(result: CompileResult) -> str:
    model = result.model
    assert model is not None
    problems = []
    if len(model["tracks"]) != 3:
        problems.append(f"expected 3 tracks, got {len(model['tracks'])}")
    if len(model["collections"]) != 2:
        problems.append(f"expected 2 collections, got {len(model['collections'])}")
    if len(model["pools"]) != 2:
        problems.append(f"expected 2 pools, got {len(model['pools'])}")
    if len(model["cues"]) != 2:
        problems.append(f"expected 2 cues, got {len(model['cues'])}")
    if result.warnings:
        problems.append(f"strict mode produced warnings: {[issue.code for issue in result.warnings]}")

    universal = next(entry for entry in model["collections"] if entry["id"] == "FX_UNIVERSAL")
    if universal["artworkAssetId"] != 200000001:
        problems.append("approved collection artwork was not emitted")
    # Browse order follows the player-facing title: "Bright Vector" then "Quiet Orbit".
    if universal["trackIds"] != ["FX_AMBIENT_TWO", "FX_AMBIENT_ONE"]:
        problems.append(f"unexpected collection track order: {universal['trackIds']}")

    two = next(entry for entry in model["tracks"] if entry["id"] == "FX_AMBIENT_TWO")
    if (two["playbackStartSeconds"], two["playbackEndSeconds"]) != (1.0, 39.0):
        problems.append("authored playback region was not preserved")
    if (two["loopStartSeconds"], two["loopEndSeconds"]) != (2.0, 38.0):
        problems.append("authored loop region was not preserved")
    one = next(entry for entry in model["tracks"] if entry["id"] == "FX_AMBIENT_ONE")
    if (one["playbackStartSeconds"], one["playbackEndSeconds"]) != (0.0, 40.0):
        problems.append("default playback region should span the whole recording")
    if one["loopStartSeconds"] is not None:
        problems.append("a track without an authored loop must not emit one")
    return "; ".join(problems)


def test_determinism() -> None:
    first = run(STRICT, [])
    second = run(STRICT, [])
    record(
        "determinism/repeat-run",
        first.text == second.text and first.text is not None,
        "two runs over identical input produced different output",
    )

    shuffled = run(STRICT, [reverse_rows])
    record(
        "determinism/row-order",
        shuffled.ok and shuffled.text == first.text,
        "reordering CSV rows changed the generated module",
    )

    development = run(DEVELOPMENT, [])
    assert first.text is not None and development.text is not None
    record(
        "determinism/mode-marker",
        development.text.replace('mode = "development"', 'mode = "strict"').replace(
            "--mode development", "--mode strict"
        )
        == first.text,
        "a complete catalog should differ between modes only by the recorded mode",
    )


def test_golden(update: bool) -> None:
    for mode in (DEVELOPMENT, STRICT):
        result = run(mode, [])
        path = EXPECTED / f"MusicCatalog.{mode}.lua"
        if update:
            path.parent.mkdir(parents=True, exist_ok=True)
            assert result.text is not None
            path.write_text(result.text, encoding="utf-8")
            continue
        if not path.exists():
            record(f"golden/{mode}", False, f"{path} is missing; run with --update")
            continue
        record(
            f"golden/{mode}",
            path.read_text(encoding="utf-8") == result.text,
            f"generated module no longer matches {path.name}",
        )


# --- cases ----------------------------------------------------------------


def test_schema_failures() -> None:
    expect_failure(
        "schema/header-mismatch",
        STRICT,
        [replace("game/pools.csv", "display_name", "pool_name")],
        "header-mismatch",
    )
    expect_failure(
        "schema/column-count",
        STRICT,
        [replace("game/pools.csv", "Approved,\nFX_RECOVERY", "Approved,,extra\nFX_RECOVERY")],
        "column-count-mismatch",
    )
    expect_failure(
        "schema/blank-row",
        STRICT,
        [append("game/pool-membership.csv", ",,,,,,")],
        "blank-row",
    )
    expect_failure(
        "schema/missing-required-value",
        STRICT,
        [replace("game/cues.csv", "FX_INTRO,Fixture intro presentation", "FX_INTRO,")],
        "missing-required-value",
    )
    expect_failure(
        "schema/unknown-controlled-value",
        STRICT,
        [replace("game/track-overrides.csv", "Playful,Chill", "Spooky,Chill")],
        "unknown-controlled-value",
    )
    expect_failure(
        "schema/malformed-number",
        STRICT,
        [replace("game/pool-membership.csv", "FX_AMBIENT_ONE,1.0", "FX_AMBIENT_ONE,soft")],
        "malformed-number",
    )
    expect_failure(
        "schema/value-out-of-range",
        STRICT,
        [replace("game/cues.csv", "Cinematic,100", "Cinematic,5000")],
        "value-out-of-range",
    )
    expect_failure(
        "schema/malformed-id",
        STRICT,
        [replace("catalog/tracks.csv", "FX_AMBIENT_ONE,FIXTURE_APPROVED", "fx_ambient_one,FIXTURE_APPROVED")],
        "malformed-id",
    )
    expect_failure(
        "schema/malformed-asset-id",
        STRICT,
        [replace("catalog/tracks.csv", "Yes,100000001", "Yes,rbxassetid://100000001")],
        "malformed-asset-id",
    )
    expect_failure(
        "schema/malformed-sha256",
        STRICT,
        [replace("catalog/tracks.csv", "1" * 64, "1" * 63)],
        "malformed-sha256",
    )
    expect_failure(
        "schema/duplicate-key",
        STRICT,
        [
            append(
                "game/pool-membership.csv",
                "FX_AMBIENT,FX_AMBIENT_ONE,1.0,,4,Approved,duplicate",
            )
        ],
        "duplicate-key",
    )
    expect_failure(
        "schema/singleton-row-count",
        STRICT,
        [append("game/experience.csv", "FX_OTHER,Second Game,,,Active,")],
        "singleton-row-count",
    )
    expect_failure(
        "schema/missing-file",
        STRICT,
        [remove_file("catalog/artwork.csv")],
        "missing-file",
    )


def test_reference_failures() -> None:
    expect_failure(
        "reference/unknown-track",
        STRICT,
        [replace("game/pool-membership.csv", "FX_AMBIENT,FX_AMBIENT_TWO", "FX_AMBIENT,FX_MISSING")],
        "unresolved-reference",
        "tracks.track_id",
    )
    expect_failure(
        "reference/unknown-pool",
        STRICT,
        [replace("game/cues.csv", "2.5,FX_AMBIENT", "2.5,FX_NOWHERE")],
        "unresolved-reference",
        "pools.pool_id",
    )
    expect_failure(
        "reference/unknown-collection",
        STRICT,
        [replace("game/track-overrides.csv", "Quiet Orbit,FX_UNIVERSAL", "Quiet Orbit,FX_UNKNOWN")],
        "unresolved-reference",
        "collections.collection_id",
    )
    expect_failure(
        "reference/unknown-permission-asset",
        STRICT,
        [replace("game/asset-permissions.csv", "Artwork,FX_ART_UNIVERSAL", "Artwork,FX_ART_GONE")],
        "unresolved-reference",
        "artwork record",
    )
    expect_failure(
        "reference/unknown-experience",
        STRICT,
        [replace("game/asset-permissions.csv", "FX_GAME,Track,FX_AMBIENT_ONE", "FX_OTHER,Track,FX_AMBIENT_ONE")],
        "unresolved-reference",
        "experience.experience_id",
    )


def test_integrity_failures() -> None:
    expect_failure(
        "integrity/component-only-in-pool",
        STRICT,
        [append("game/pool-membership.csv", "FX_AMBIENT,FX_COMPONENT,1.0,,4,Approved,")],
        "component-only-track-used",
    )
    expect_failure(
        "integrity/component-only-in-cue",
        DEVELOPMENT,
        [append("game/cue-assignments.csv", "FX_STINGER,FX_COMPONENT,Fallback,1,,Release,Approved,")],
        "component-only-track-used",
    )
    expect_failure(
        "integrity/excluded-track-referenced",
        DEVELOPMENT,
        [append("game/pool-membership.csv", "FX_AMBIENT,FX_PENDING_SOURCE,1.0,,4,Approved,")],
        "excluded-track-referenced",
    )
    expect_failure(
        "integrity/playback-region-inverted",
        STRICT,
        [replace("catalog/tracks.csv", "Approved,0.5,1.0,39.0", "Approved,0.5,39.0,1.0")],
        "invalid-playback-region",
    )
    expect_failure(
        "integrity/playback-region-past-duration",
        STRICT,
        [replace("catalog/tracks.csv", "Approved,0.5,1.0,39.0", "Approved,0.5,1.0,90.0")],
        "invalid-playback-region",
    )
    expect_failure(
        "integrity/loop-region-outside-playback",
        STRICT,
        [replace("catalog/tracks.csv", "1.0,39.0,2.0,38.0", "1.0,39.0,2.0,39.5")],
        "invalid-loop-region",
        "inside the playback region",
    )
    expect_failure(
        "integrity/loop-region-before-playback",
        STRICT,
        [replace("catalog/tracks.csv", "1.0,39.0,2.0,38.0", "1.0,39.0,0.5,38.0")],
        "invalid-loop-region",
        "inside the playback region",
    )
    expect_failure(
        "integrity/loop-region-inverted",
        STRICT,
        [replace("catalog/tracks.csv", "1.0,39.0,2.0,38.0", "1.0,39.0,38.0,2.0")],
        "invalid-loop-region",
        "must be less than end",
    )
    expect_failure(
        "integrity/loop-region-half-set",
        STRICT,
        [replace("catalog/tracks.csv", "1.0,39.0,2.0,38.0", "1.0,39.0,2.0,")],
        "invalid-loop-region",
    )
    expect_failure(
        "integrity/cue-advance-without-successor",
        STRICT,
        [replace("game/cue-assignments.csv", "Continuation,2,,Release,Approved", "Continuation,2,,Release,Disabled")],
        "invalid-cue-sequence",
        "Advance",
    )
    expect_failure(
        "integrity/cue-primary-sequence",
        STRICT,
        [replace("game/cue-assignments.csv", "FX_STORY_ONE,Primary,1", "FX_STORY_ONE,Primary,3")],
        "invalid-cue-sequence",
        "sequence_order 1",
    )
    expect_failure(
        "integrity/cue-without-primary-row",
        STRICT,
        [replace("game/cue-assignments.csv", "FX_STINGER,FX_AMBIENT_ONE,Primary", "FX_STINGER,FX_AMBIENT_ONE,Continuation")],
        "invalid-cue-sequence",
        "no Primary assignment",
    )
    expect_failure(
        "integrity/duplicate-cue-primary",
        STRICT,
        [append("game/cue-assignments.csv", "FX_INTRO,FX_AMBIENT_ONE,Primary,4,,Release,Approved,")],
        "duplicate-cue-primary",
    )
    expect_failure(
        "integrity/start-offset-outside-region",
        STRICT,
        [replace("game/cue-assignments.csv", "Primary,1,5.0", "Primary,1,500.0")],
        "invalid-playback-region",
        "start_offset_seconds",
    )
    expect_failure(
        "integrity/missing-credit",
        STRICT,
        [replace("catalog/sources.csv", "Yes,Music by Fixture Composer", "Yes,")],
        "missing-credit",
    )
    expect_failure(
        "integrity/unresolved-license-term",
        STRICT,
        [replace("catalog/sources.csv", "Yes,Yes,Yes,Music by", "Yes,Yes,Unknown,Music by")],
        "unresolved-license-term",
    )


def test_availability_gates() -> None:
    cases: list[tuple[str, list[Edit], str, str]] = [
        (
            "missing-asset-id",
            [replace("catalog/tracks.csv", "Yes,100000001", "Yes,")],
            "unavailable-track",
            "no roblox_asset_id",
        ),
        (
            "missing-grant",
            [drop("game/asset-permissions.csv", "Track,FX_AMBIENT_TWO")],
            "unavailable-track",
            "no Granted permission",
        ),
        (
            "unapproved-moderation",
            [replace("catalog/tracks.csv", "fixture-owner,Approved,-1.5", "fixture-owner,Pending,-1.5")],
            "unavailable-track",
            "moderation is Pending",
        ),
        (
            "missing-normalization",
            [replace("catalog/tracks.csv", "fixture-owner,Approved,-1.5", "fixture-owner,Approved,")],
            "unavailable-track",
            "normalized_volume_db",
        ),
        (
            "unapproved-review",
            [replace("catalog/tracks.csv", ",,,,Approved,\nFX_AMBIENT_TWO", ",,,,In Review,\nFX_AMBIENT_TWO")],
            "unavailable-track",
            "review is In Review",
        ),
        (
            "unapproved-source",
            [
                replace("catalog/tracks.csv", "Rejected,Held back", "Approved,Held back"),
                replace("game/track-overrides.csv", "No,No,Rejected,Held back", "No,No,Approved,Held back"),
            ],
            "unavailable-track",
            "source license is Pending",
        ),
        (
            "unapproved-override",
            [replace("game/track-overrides.csv", "No,Yes,Approved,\nFX_AMBIENT_TWO", "No,Yes,Needs Listening Review,\nFX_AMBIENT_TWO")],
            "unavailable-track",
            "override status is Needs Listening Review",
        ),
        (
            "unapproved-artwork",
            [replace("catalog/artwork.csv", "fixture-owner,Approved,Approved", "fixture-owner,Pending,Approved")],
            "unapproved-artwork",
            "artwork moderation is Pending",
        ),
        (
            "unapproved-collection",
            [replace("game/collections.csv", "intro,Approved", "intro,Candidate")],
            "unapproved-collection",
            "status is Candidate",
        ),
        (
            "unapproved-pool",
            [replace("game/pools.csv", "Shuffled Bag,Approved", "Shuffled Bag,Candidate")],
            "unapproved-pool",
            "status is Candidate",
        ),
        (
            "empty-pool",
            [replace("game/pool-membership.csv", "FX_RECOVERY,FX_AMBIENT_ONE,1.0,,2,Approved", "FX_RECOVERY,FX_AMBIENT_ONE,1.0,,2,Disabled")],
            "empty-pool",
            "no playable approved member",
        ),
        (
            "unapproved-cue",
            [replace("game/cues.csv", "Yes,Approved", "Yes,Planned")],
            "unapproved-cue",
            "status is Planned",
        ),
        (
            "cue-without-primary",
            [replace("game/cue-assignments.csv", "FX_STINGER,FX_AMBIENT_ONE,Primary,1,5.0,CueDefault,Approved", "FX_STINGER,FX_AMBIENT_ONE,Primary,1,5.0,CueDefault,Candidate")],
            "cue-without-primary",
            "no approved playable Primary",
        ),
        (
            "empty-runtime-catalog",
            [
                replace("game/track-overrides.csv", "No,Yes,Approved,\nFX_AMBIENT_TWO", "No,Yes,Rejected,\nFX_AMBIENT_TWO"),
                replace("game/track-overrides.csv", "No,Yes,Approved,\nFX_STORY_ONE", "No,Yes,Rejected,\nFX_STORY_ONE"),
                replace("game/track-overrides.csv", "Yes,Yes,Approved,\nFX_COMPONENT", "Yes,Yes,Rejected,\nFX_COMPONENT"),
                drop("game/pool-membership.csv", "FX_AMBIENT_ONE"),
                drop("game/pool-membership.csv", "FX_AMBIENT_TWO"),
                drop("game/cue-assignments.csv", "FX_"),
            ],
            "empty-runtime-catalog",
            "at least one production-ready track",
        ),
    ]

    for name, edits, code, contains in cases:
        expect_failure(f"strict/{name}", STRICT, edits, code, contains)

    # The same gaps only omit entries in development mode.
    expect_success(
        "development/missing-asset-id",
        DEVELOPMENT,
        [replace("catalog/tracks.csv", "Yes,100000001", "Yes,")],
        lambda result: ""
        if len(result.model["tracks"]) == 2 and any(issue.code == "unavailable-track" for issue in result.warnings)
        else f"expected 2 tracks and a warning, got {len(result.model['tracks'])} tracks",
    )
    expect_success(
        "development/missing-grant",
        DEVELOPMENT,
        [drop("game/asset-permissions.csv", "Track,FX_AMBIENT_TWO")],
        lambda result: ""
        if len(result.model["tracks"]) == 2
        else f"expected 2 tracks, got {len(result.model['tracks'])}",
    )
    expect_success(
        "development/unapproved-artwork",
        DEVELOPMENT,
        [replace("catalog/artwork.csv", "fixture-owner,Approved,Approved", "fixture-owner,Pending,Approved")],
        lambda result: ""
        if next(entry for entry in result.model["collections"] if entry["id"] == "FX_UNIVERSAL")["artworkAssetId"]
        is None
        else "the collection kept unusable artwork",
    )
    expect_success(
        "development/unapproved-collection-cascades",
        DEVELOPMENT,
        [replace("game/collections.csv", "intro,Approved", "intro,Candidate")],
        lambda result: ""
        if len(result.model["collections"]) == 1 and len(result.model["tracks"]) == 2
        else f"expected 1 collection and 2 tracks, got {len(result.model['collections'])} and {len(result.model['tracks'])}",
    )
    expect_success(
        "development/excluded-rows-are-silent",
        DEVELOPMENT,
        [],
        lambda result: ""
        if not result.warnings
        else f"deliberately excluded rows should not warn: {[issue.code for issue in result.warnings]}",
    )


def test_repository_catalog() -> None:
    """The real ClickGame CSVs must stay free of integrity problems while curation runs."""

    result = compile_catalog(ROOT / "music/catalog", ROOT / "music/clickgame", DEVELOPMENT)
    record(
        "repository/development-compiles",
        result.ok,
        f"development compile failed: {[issue.format() for issue in result.errors][:3]}",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true", help="rewrite the golden generated modules")
    args = parser.parse_args()

    expect_success("strict/fixture-compiles", STRICT, [], check_strict_shape)
    test_determinism()
    test_schema_failures()
    test_reference_failures()
    test_integrity_failures()
    test_availability_gates()
    test_repository_catalog()
    test_golden(args.update)

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        print(f"{passed} passed, {len(failures)} failed")
        return 1
    print(f"{passed} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
