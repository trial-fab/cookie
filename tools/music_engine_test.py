#!/usr/bin/env python3
"""Run the pure Orbit Radio engine-core contract in a plain Luau process.

The engine core has no Roblox dependencies, so the whole state machine, queue,
shuffled bag, unlock resolver, and persistence projection are testable without
Studio. This script inlines each module's source into one chunk and runs
tools/music_engine_test.luau against it.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MUSIC = ROOT / "src/ReplicatedStorage/Shared/Music"

MODULES = {
    "MusicTypes": MUSIC / "MusicTypes.lua",
    "MusicConfig": MUSIC / "MusicConfig.lua",
    "MusicRandom": MUSIC / "MusicRandom.lua",
    "MusicCatalog": MUSIC / "MusicCatalog.lua",
    "MusicCatalog.generated": MUSIC / "MusicCatalog.generated.lua",
    "MusicUnlocks": MUSIC / "MusicUnlocks.lua",
    "MusicSelector": MUSIC / "MusicSelector.lua",
    "MusicQueue": MUSIC / "MusicQueue.lua",
    "MusicPersistence": MUSIC / "MusicPersistence.lua",
    "NullPlaybackBackend": MUSIC / "NullPlaybackBackend.lua",
    "MusicDirector": MUSIC / "MusicDirector.lua",
}
TEST = ROOT / "tools/music_engine_test.luau"


def find_luau() -> str:
    found = shutil.which("luau") or shutil.which(str(pathlib.Path.home() / ".local/bin/luau"))
    if not found:
        sys.exit("luau interpreter not found on PATH (expected ~/.local/bin/luau)")
    return found


def build_chunk() -> str:
    parts = ["--!nocheck", "local SOURCES = {}"]
    for name, path in MODULES.items():
        source = path.read_text()
        if "]==]" in source:
            sys.exit(f"{name} contains a long-bracket terminator")
        parts.append(f'SOURCES["{name}"] = [==[\n{source}]==]')
    parts.append(TEST.read_text())
    return "\n".join(parts)


def main() -> int:
    for path in [*MODULES.values(), TEST]:
        if not path.exists():
            sys.exit(f"missing music engine test input: {path}")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write(build_chunk())
        generated = pathlib.Path(handle.name)
    try:
        return subprocess.call([find_luau(), str(generated)])
    finally:
        generated.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
