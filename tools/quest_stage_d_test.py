#!/usr/bin/env python3
"""Run pure Stage D declarative-content and Quest 4 acceptance fixtures."""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

MODULES = {
    "DomainEvents": SRC / "ReplicatedStorage/Shared/Quest/DomainEvents.lua",
    "UiObservations": SRC / "ReplicatedStorage/Shared/Quest/UiObservations.lua",
    "QuestCopy": SRC / "ReplicatedStorage/Shared/Quest/QuestCopy.lua",
    "QuestContentReader": SRC / "ReplicatedStorage/Shared/Quest/QuestContentReader.lua",
    "Guides.Registry": SRC / "ReplicatedStorage/Shared/Quest/Guides/Registry.lua",
    "PresentationPolicySchema": SRC / "ReplicatedStorage/Shared/Quest/PresentationPolicySchema.lua",
    "CompletionActionRegistry": SRC / "ReplicatedStorage/Shared/Quest/CompletionActionRegistry.lua",
    "Objectives.Util": SRC / "ReplicatedStorage/Shared/Quest/Objectives/Util.lua",
    "Objectives.StoryTransition": SRC / "ReplicatedStorage/Shared/Quest/Objectives/StoryTransition.lua",
    "Objectives.ManualOwnerClickCount": SRC / "ReplicatedStorage/Shared/Quest/Objectives/ManualOwnerClickCount.lua",
    "Objectives.BuildingPlaced": SRC / "ReplicatedStorage/Shared/Quest/Objectives/BuildingPlaced.lua",
    "Objectives.BuildingCountAtLeast": SRC / "ReplicatedStorage/Shared/Quest/Objectives/BuildingCountAtLeast.lua",
    "Objectives.BuildingSold": SRC / "ReplicatedStorage/Shared/Quest/Objectives/BuildingSold.lua",
    "Objectives.CookieBalanceAtLeast": SRC / "ReplicatedStorage/Shared/Quest/Objectives/CookieBalanceAtLeast.lua",
    "Objectives.UpgradePurchased": SRC / "ReplicatedStorage/Shared/Quest/Objectives/UpgradePurchased.lua",
    "Objectives.ClientUiObservation": SRC / "ReplicatedStorage/Shared/Quest/Objectives/ClientUiObservation.lua",
    "Objectives.BoostPurchased": SRC / "ReplicatedStorage/Shared/Quest/Objectives/BoostPurchased.lua",
    "Objectives.BoostFieldDropped": SRC / "ReplicatedStorage/Shared/Quest/Objectives/BoostFieldDropped.lua",
    "Objectives.Registry": SRC / "ReplicatedStorage/Shared/Quest/Objectives/Registry.lua",
    "Rewards.Gems": SRC / "ReplicatedStorage/Shared/Quest/Rewards/Gems.lua",
    "Rewards.GooSkin": SRC / "ReplicatedStorage/Shared/Quest/Rewards/GooSkin.lua",
    "Rewards.Registry": SRC / "ReplicatedStorage/Shared/Quest/Rewards/Registry.lua",
    "QuestSchema": SRC / "ReplicatedStorage/Shared/Quest/QuestSchema.lua",
    "QuestEngine": SRC / "ReplicatedStorage/Shared/Quest/QuestEngine.lua",
    "QuestFactProvider": SRC / "ServerScriptService/Services/Quest/QuestFactProvider.lua",
    "Content.OpeningTutorial": SRC / "ReplicatedStorage/Shared/Quest/Content/OpeningTutorial.lua",
    "Content.Manifest": SRC / "ReplicatedStorage/Shared/Quest/Content/Manifest.lua",
    "QuestProgressGuideKinds": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressGuideKinds.lua",
    "QuestProgressPresentationPolicies": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationPolicies.lua",
}

TEXT_INPUTS = {
    "STORE_NUDGE_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Store/StoreUpgradeNudge.lua",
    "OBSERVATION_BUS_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressObservationBus.lua",
    "REPLAY_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressReplay.lua",
    "HELP_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressHelp.lua",
    "QUEST_SERVICE_SOURCE": SRC / "ServerScriptService/Services/QuestService.lua",
    "V2_CONTROLLER_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressV2Controller.lua",
}

TEST = ROOT / "tools/quest_stage_d_test.luau"


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
    for name, path in TEXT_INPUTS.items():
        source = path.read_text()
        if "]==]" in source:
            sys.exit(f"{name} contains a long-bracket terminator")
        parts.append(f'local {name} = [==[\n{source}]==]')
    parts.append(TEST.read_text())
    return "\n".join(parts)


def main() -> int:
    for path in (*MODULES.values(), *TEXT_INPUTS.values(), TEST):
        if not path.exists():
            sys.exit(f"missing Stage D test input: {path}")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write(build_chunk())
        generated = pathlib.Path(handle.name)
    try:
        return subprocess.call([find_luau(), str(generated)])
    finally:
        generated.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
