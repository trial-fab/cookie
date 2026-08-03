#!/usr/bin/env python3
"""Run the Stage E cutover and Quest 5 acceptance tests.

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
    "DomainEvents": SRC / "ReplicatedStorage/Shared/Quest/DomainEvents.lua",
    "UiObservations": SRC / "ReplicatedStorage/Shared/Quest/UiObservations.lua",
    "QuestCopy": SRC / "ReplicatedStorage/Shared/Quest/QuestCopy.lua",
    "SkinRarityConfig": SRC / "ReplicatedStorage/Shared/SkinRarityConfig.lua",
    "GooSkinConfig": SRC / "ReplicatedStorage/Shared/GooSkinConfig.lua",
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
    "Content.Manifest": SRC / "ReplicatedStorage/Shared/Quest/Content/Manifest.lua",
    "Content.OpeningTutorial": SRC / "ReplicatedStorage/Shared/Quest/Content/OpeningTutorial.lua",
    "Content.GrowingBakeryFixture": SRC / "ReplicatedStorage/Shared/Quest/Content/GrowingBakeryFixture.lua",
    "QuestEngine": SRC / "ReplicatedStorage/Shared/Quest/QuestEngine.lua",
    "Quest.QuestEventRouter": SRC / "ServerScriptService/Services/Quest/QuestEventRouter.lua",
    "Quest.QuestFactProvider": SRC / "ServerScriptService/Services/Quest/QuestFactProvider.lua",
    "Quest.QuestPersistence": SRC / "ServerScriptService/Services/Quest/QuestPersistence.lua",
    "Quest.QuestEffectRunner": SRC / "ServerScriptService/Services/Quest/QuestEffectRunner.lua",
}
TEXT_INPUTS = {
    "QUEST_SERVICE_SOURCE": SRC / "ServerScriptService/Services/QuestService.lua",
    "CLIENT_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressController.client.lua",
    "RENDERER_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressQuestList.lua",
    "PRESENTATION_QUEUE_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressPresentationQueue.lua",
    "GUIDE_TARGET_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/Hud/QuestProgressGuideTargets.lua",
    "BOOST_SHOP_SOURCE": SRC / "ServerScriptService/Services/BoostShopService.lua",
    "BOOST_FIELD_SOURCE": SRC / "ServerScriptService/Services/BoostFieldService.lua",
    "BOOST_PROMPTS_SOURCE": SRC / "StarterGui/ScreenGui/Controllers/BoostShop/BoostShopPrompts.lua",
    "GEM_SERVICE_SOURCE": SRC / "ServerScriptService/Services/GemService.lua",
    "PLAYER_DATA_SOURCE": SRC / "ServerScriptService/Services/PlayerDataService.lua",
    "REMOTE_NAMES_SOURCE": SRC / "ReplicatedStorage/Shared/RemoteNames.lua",
    "ECONOMY_SIM_SOURCE": ROOT / "tools/economy_sim.py",
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
    for name, path in TEXT_INPUTS.items():
        source = path.read_text()
        if "]==]" in source:
            sys.exit(f"{name} contains a long-bracket terminator")
        parts.append(f'local {name} = [==[\n{source}]==]')
    parts.append(TEST.read_text())
    return "\n".join(parts)


def main() -> int:
    for name, path in {**MODULES, **TEXT_INPUTS}.items():
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
