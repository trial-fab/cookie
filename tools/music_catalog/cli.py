"""Command line entry point for the music catalog compiler."""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

from . import emit, reader, validate
from .reader import ERROR, Issue
from .validate import DEVELOPMENT, MODES

EXIT_OK = 0
EXIT_VALIDATION_FAILED = 1
EXIT_OUT_OF_DATE = 3


@dataclass
class CompileResult:
    """Everything one compiler run produced."""

    mode: str
    text: str | None
    issues: list[Issue]
    model: dict[str, object] | None

    @property
    def errors(self) -> list[Issue]:
        return [issue for issue in self.issues if issue.severity == ERROR]

    @property
    def warnings(self) -> list[Issue]:
        return [issue for issue in self.issues if issue.severity != ERROR]

    @property
    def ok(self) -> bool:
        return not self.errors


def compile_catalog(catalog_root: Path, game_root: Path, mode: str) -> CompileResult:
    """Read, validate, and (when valid) render the catalog for one mode."""

    catalog, issues = reader.read_catalog(catalog_root, game_root)
    issues = reader.sort_issues(issues)
    if any(issue.severity == ERROR for issue in issues):
        return CompileResult(mode=mode, text=None, issues=issues, model=None)

    model, model_issues = validate.build_model(catalog, mode)
    issues = reader.sort_issues(issues + model_issues)
    if any(issue.severity == ERROR for issue in issues) or model is None:
        return CompileResult(mode=mode, text=None, issues=issues, model=model)

    return CompileResult(mode=mode, text=emit.render(model), issues=issues, model=model)


def _summarize(result: CompileResult, stream) -> None:
    for issue in result.issues:
        print(issue.format(), file=stream)
    if result.model is not None and result.ok:
        model = result.model
        print(
            f"{result.mode}: {len(model['tracks'])} tracks, {len(model['collections'])} collections, "  # type: ignore[arg-type]
            f"{len(model['pools'])} pools, {len(model['cues'])} cues, "  # type: ignore[arg-type]
            f"{len(result.warnings)} warnings",
            file=stream,
        )
    else:
        print(
            f"{result.mode}: {len(result.errors)} errors, {len(result.warnings)} warnings",
            file=stream,
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="compile_music_catalog",
        description="Compile the CSV music catalog into a deterministic Luau module.",
    )
    repo_root = Path(__file__).resolve().parents[2]
    parser.add_argument("--repo-root", type=Path, default=repo_root, help="ClickGame repository root")
    parser.add_argument(
        "--mode",
        choices=MODES,
        default=DEVELOPMENT,
        help="development omits unavailable rows with a warning; strict fails on them",
    )
    parser.add_argument("--catalog-root", type=Path, help="override the music/catalog directory")
    parser.add_argument("--game-root", type=Path, help="override the music/<game> directory")
    parser.add_argument("--game", default="clickgame", help="game directory name under music/")
    parser.add_argument("--output", type=Path, help="override the generated Luau module path")
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; fail when the generated module is missing or out of date",
    )
    parser.add_argument("--quiet", action="store_true", help="only report errors")
    args = parser.parse_args(argv)

    root = args.repo_root.resolve()
    catalog_root = args.catalog_root or root / "music" / "catalog"
    game_root = args.game_root or root / "music" / args.game
    output = args.output or root / "src/ReplicatedStorage/Shared/Music/MusicCatalog.generated.lua"

    result = compile_catalog(catalog_root, game_root, args.mode)

    if not result.ok:
        for issue in result.errors:
            print(issue.format(), file=sys.stderr)
        print(
            f"{args.mode} compile failed: {len(result.errors)} errors, {len(result.warnings)} warnings",
            file=sys.stderr,
        )
        return EXIT_VALIDATION_FAILED

    if not args.quiet:
        _summarize(result, sys.stderr)

    assert result.text is not None
    if args.check:
        if not output.exists():
            print(f"{output} does not exist; run the compiler to generate it", file=sys.stderr)
            return EXIT_OUT_OF_DATE
        if output.read_text(encoding="utf-8") != result.text:
            print(f"{output} is out of date; regenerate it from the CSV catalog", file=sys.stderr)
            return EXIT_OUT_OF_DATE
        return EXIT_OK

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(result.text, encoding="utf-8")
    if not args.quiet:
        print(f"wrote {output.relative_to(root) if output.is_relative_to(root) else output}", file=sys.stderr)
    return EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
