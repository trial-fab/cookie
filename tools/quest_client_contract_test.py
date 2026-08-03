#!/usr/bin/env python3
"""Run the pure Stage A quest client/measurement contract fixtures.

The generated Luau chunk contains only the pure harness and its fixtures. It does
not load Roblox UI or service stubs.

    python3 tools/quest_client_contract_test.py
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HARNESS = ROOT / "tools/quest_client_contract_harness.luau"
TEST = ROOT / "tools/quest_client_contract_test.luau"
MODULES = {
    "QuestProtocol": ROOT / "src/ReplicatedStorage/Shared/Quest/QuestProtocol.lua",
    "QuestProgressReducer": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressReducer.lua",
    "QuestProgressPresentationSignals": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationSignals.lua",
    "QuestProgressPresentationPolicies": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationPolicies.lua",
    "QuestProgressPresentationQueue": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationQueue.lua",
    "QuestProgressPresentationVisualAdapters": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationVisualAdapters.lua",
    "QuestProgressPresentationCoordinator": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationCoordinator.lua",
    "QuestProgressV2Controller": ROOT / "src/StarterGui/ScreenGui/Controllers/Hud/QuestProgressV2Controller.lua",
}


def find_luau() -> str:
    found = shutil.which("luau") or shutil.which(str(pathlib.Path.home() / ".local/bin/luau"))
    if not found:
        sys.exit("luau interpreter not found on PATH (expected ~/.local/bin/luau)")
    return found


def build_chunk() -> str:
    harness = HARNESS.read_text()
    if "]==]" in harness:
        sys.exit("harness contains a long-bracket terminator; bump the delimiter here")
    parts = [
        "--!nocheck",
        f'local HARNESS_SOURCE = [==[\n{harness}]==]',
        "local STAGE_C_SOURCES = {}",
    ]
    for name, path in MODULES.items():
        source = path.read_text()
        if "]==]" in source:
            sys.exit(f"{name} contains a long-bracket terminator")
        parts.append(f'STAGE_C_SOURCES["{name}"] = [==[\n{source}]==]')
    parts.append(TEST.read_text())
    return "\n".join(parts)


def main() -> int:
    for path in (HARNESS, TEST, *MODULES.values()):
        if not path.exists():
            sys.exit(f"missing Stage A contract file: {path}")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write(build_chunk())
        generated = handle.name
    try:
        return subprocess.call([find_luau(), generated])
    finally:
        pathlib.Path(generated).unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
