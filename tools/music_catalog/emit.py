"""Deterministic Luau emission.

The generated module is pure data: no local paths, hashes, license evidence,
archive names, or production notes. Identical input must produce an identical
file, so every table is written in a fixed key order, every list is sorted by a
stable ID before it reaches this module, and numbers use one canonical format.
"""

from __future__ import annotations

INDENT = "\t"

HEADER = """--!strict
-- MusicCatalog.generated.lua
--
-- GENERATED FILE - DO NOT EDIT BY HAND.
-- Source of truth: the CSV catalog under music/ (see docs/music.md).
-- Regenerate with:
--   python3 tools/compile_music_catalog.py --mode {mode}
--
-- Runtime fields only. Local paths, hashes, license evidence, archive names, and
-- production notes stay in the CSVs.
"""

_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


def lua_string(value: str) -> str:
    out = []
    for character in value:
        escape = _ESCAPES.get(character)
        if escape is not None:
            out.append(escape)
        elif ord(character) < 0x20 or ord(character) == 0x7F:
            out.append(f"\\{ord(character)}")
        else:
            out.append(character)
    return '"' + "".join(out) + '"'


def lua_number(value: float | int) -> str:
    if isinstance(value, int):
        return str(value)
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError(f"non-finite number cannot be emitted: {value}")
    if float(value).is_integer() and abs(value) < 1e15:
        return str(int(value))
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


def _is_identifier(key: str) -> bool:
    return key.isidentifier() and key.isascii()


def lua_value(value: object, depth: int) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return lua_number(value)
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        pad = INDENT * (depth + 1)
        lines = [f"{pad}{lua_value(item, depth + 1)}," for item in value]
        return "{\n" + "\n".join(lines) + "\n" + INDENT * depth + "}"
    if isinstance(value, dict):
        pairs = [(key, item) for key, item in value.items() if item is not None]
        if not pairs:
            return "{}"
        pad = INDENT * (depth + 1)
        lines = []
        for key, item in pairs:
            name = key if _is_identifier(key) else f"[{lua_string(key)}]"
            lines.append(f"{pad}{name} = {lua_value(item, depth + 1)},")
        return "{\n" + "\n".join(lines) + "\n" + INDENT * depth + "}"
    raise TypeError(f"cannot emit {type(value).__name__} into Luau")


def render(model: dict[str, object]) -> str:
    """Serialize a runtime model into the generated Luau module text."""

    tracks = model["tracks"]
    assert isinstance(tracks, list)
    index = {str(entry["id"]): position + 1 for position, entry in enumerate(tracks)}

    document: dict[str, object] = {
        "formatVersion": model["formatVersion"],
        "mode": model["mode"],
        "experienceId": model["experienceId"],
        "inputDigest": model["inputDigest"],
        "credits": model["credits"],
        "collections": model["collections"],
        "tracks": tracks,
        "trackIndex": index,
        "pools": model["pools"],
        "cues": model["cues"],
    }

    body = lua_value(document, 0)
    header = HEADER.format(mode=model["mode"])
    return f"{header}\nreturn {body}\n"
