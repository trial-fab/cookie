#!/usr/bin/env python3
"""Run the quest progression tests in tools/quest_logic_test.luau.

The luau CLI sandboxes `io`, so the modules under test are inlined into one generated
chunk and handed to the interpreter. The test itself stubs the Roblox services
QuestService requires, which is what lets progression, reward idempotency, and
reconciliation be checked without launching Studio.

    python3 tools/quest_logic_test.py

Exits non-zero when a check fails.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

MODULES = {
    "QuestDefinitions": SRC / "ReplicatedStorage/Shared/QuestDefinitions.lua",
    "QuestSnapshot": SRC / "ReplicatedStorage/Shared/QuestSnapshot.lua",
    "QuestService": SRC / "ServerScriptService/Services/QuestService.lua",
}
TEST = ROOT / "tools/quest_logic_test.luau"


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
            sys.exit(f"{name} contains a long-bracket terminator; bump the delimiter here")
        parts.append(f'SOURCES["{name}"] = [==[\n{source}]==]')
    parts.append(TEST.read_text())
    return "\n".join(parts)


def main() -> int:
    for name, path in MODULES.items():
        if not path.exists():
            sys.exit(f"missing module for {name}: {path}")
    if not TEST.exists():
        sys.exit(f"missing test file: {TEST}")

    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write(build_chunk())
        generated = handle.name
    try:
        return subprocess.call([find_luau(), generated])
    finally:
        pathlib.Path(generated).unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
