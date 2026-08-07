#!/usr/bin/env python3
"""Compile the CSV music catalog into src/.../Music/MusicCatalog.generated.lua.

Usage:
    python3 tools/compile_music_catalog.py --mode development
    python3 tools/compile_music_catalog.py --mode strict
    python3 tools/compile_music_catalog.py --mode development --check

Development mode omits rows that are not production ready and warns about each
one. Strict mode fails on them. Both modes fail on catalog integrity problems.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from music_catalog.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
