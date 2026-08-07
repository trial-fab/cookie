#!/usr/bin/env python3
"""Run ClickGame's Persistent.Music adapter contract in a plain Luau process.

MusicService is a Roblox shell; every decision it makes lives in the pure
Shared/OrbitRadio modules, so the whole reconciliation and validation contract runs
without Studio. This script inlines each module's source into one chunk and runs
tools/orbit_radio_profile_test.luau against it.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT / "src/ReplicatedStorage/Shared"

# Keys are the dotted instance paths the modules require each other by.
MODULES = {
    "FloorConfig": SHARED / "FloorConfig.lua",
    "StoryConfig": SHARED / "StoryConfig.lua",
    "Music.MusicTypes": SHARED / "Music/MusicTypes.lua",
    "Music.MusicConfig": SHARED / "Music/MusicConfig.lua",
    "Music.MusicCatalog": SHARED / "Music/MusicCatalog.lua",
    "Music.MusicUnlocks": SHARED / "Music/MusicUnlocks.lua",
    "Music.MusicPersistence": SHARED / "Music/MusicPersistence.lua",
    "OrbitRadio.OrbitRadioConfig": SHARED / "OrbitRadio/OrbitRadioConfig.lua",
    "OrbitRadio.OrbitRadioProfile": SHARED / "OrbitRadio/OrbitRadioProfile.lua",
}
TEST = ROOT / "tools/orbit_radio_profile_test.luau"


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
            sys.exit(f"missing orbit radio test input: {path}")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write(build_chunk())
        generated = pathlib.Path(handle.name)
    try:
        return subprocess.call([find_luau(), str(generated)])
    finally:
        generated.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
