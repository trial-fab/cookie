"""Typed CSV reading with schema validation.

Everything this module reports is an authoring mistake in the CSV itself: a wrong
header, a malformed number, an unknown controlled value, a blank required field,
or a duplicate primary key. Cross-table meaning is checked later in `validate`.
"""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from . import schema
from .schema import Column, Table

ID_PATTERN = re.compile(r"^[A-Z0-9][A-Z0-9_]*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ASSET_ID_PATTERN = re.compile(r"^[1-9][0-9]{0,18}$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
INT_PATTERN = re.compile(r"^-?[0-9]+$")
NUMBER_PATTERN = re.compile(r"^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$")

ERROR = "error"
WARNING = "warning"


@dataclass(frozen=True)
class Issue:
    """One validation finding. `sort_key` keeps reports stable run to run."""

    location: str
    code: str
    message: str
    severity: str = ERROR

    def format(self) -> str:
        return f"{self.severity}: {self.location}: [{self.code}] {self.message}"

    def sort_key(self) -> tuple[str, int, str, str]:
        name, _, line = self.location.partition(":")
        return (name, int(line) if line.isdigit() else 0, self.code, self.message)


def sort_issues(issues: Iterable[Issue]) -> list[Issue]:
    return sorted(issues, key=Issue.sort_key)


@dataclass
class Row:
    """One parsed CSV row: typed values plus enough context to report on it."""

    table: str
    line: int
    location: str
    values: dict[str, object]
    raw: dict[str, str]

    def text(self, name: str) -> str:
        value = self.values.get(name)
        return "" if value is None else str(value)

    def number(self, name: str) -> float | None:
        value = self.values.get(name)
        return None if value is None else float(value)

    def integer(self, name: str) -> int | None:
        value = self.values.get(name)
        return None if value is None else int(value)

    def flag(self, name: str) -> bool:
        return self.values.get(name) is True

    def key(self, table: Table) -> tuple[str, ...]:
        return tuple(self.text(name) for name in table.key)


@dataclass
class Catalog:
    """Every table parsed from one catalog root and one game directory."""

    catalog_root: Path
    game_root: Path
    rows: dict[str, list[Row]] = field(default_factory=dict)

    def of(self, table: Table | str) -> list[Row]:
        name = table if isinstance(table, str) else table.name
        return self.rows.get(name, [])

    def index(self, table: Table) -> dict[tuple[str, ...], Row]:
        return {row.key(table): row for row in self.of(table)}

    def ids(self, table: Table) -> set[str]:
        column = table.key[0]
        return {row.text(column) for row in self.of(table)}


def _parse_value(column: Column, raw: str, location: str) -> tuple[object | None, list[Issue]]:
    issues: list[Issue] = []
    value = raw.strip()

    if not value:
        if column.required:
            issues.append(
                Issue(location, "missing-required-value", f"column '{column.name}' must not be empty")
            )
        return None, issues

    if column.enum is not None and value not in column.enum:
        issues.append(
            Issue(
                location,
                "unknown-controlled-value",
                f"column '{column.name}' value '{value}' is not one of: {', '.join(column.enum)}",
            )
        )
        return None, issues

    if column.kind == schema.FLAG:
        return value == "Yes", issues

    if column.kind == schema.ID:
        if not ID_PATTERN.match(value):
            issues.append(
                Issue(
                    location,
                    "malformed-id",
                    f"column '{column.name}' value '{value}' must be uppercase A-Z, 0-9 and underscore",
                )
            )
            return None, issues
        return value, issues

    if column.kind == schema.SHA256:
        if not SHA256_PATTERN.match(value):
            issues.append(
                Issue(location, "malformed-sha256", f"column '{column.name}' value '{value}' is not a sha256 digest")
            )
            return None, issues
        return value, issues

    if column.kind == schema.ASSET_ID:
        if not ASSET_ID_PATTERN.match(value):
            issues.append(
                Issue(
                    location,
                    "malformed-asset-id",
                    f"column '{column.name}' value '{value}' must be a positive Roblox asset ID with no prefix",
                )
            )
            return None, issues
        return int(value), issues

    if column.kind == schema.DATE:
        if not DATE_PATTERN.match(value):
            issues.append(
                Issue(location, "malformed-date", f"column '{column.name}' value '{value}' must be YYYY-MM-DD")
            )
            return None, issues
        return value, issues

    if column.kind in (schema.INT, schema.NUMBER):
        pattern = INT_PATTERN if column.kind == schema.INT else NUMBER_PATTERN
        if not pattern.match(value):
            issues.append(
                Issue(
                    location,
                    "malformed-number",
                    f"column '{column.name}' value '{value}' is not a plain {column.kind}",
                )
            )
            return None, issues
        number: object = int(value) if column.kind == schema.INT else float(value)
        numeric = float(number)  # type: ignore[arg-type]
        if column.minimum is not None and numeric < column.minimum:
            issues.append(
                Issue(
                    location,
                    "value-out-of-range",
                    f"column '{column.name}' value {value} is below the minimum {column.minimum}",
                )
            )
            return None, issues
        if column.maximum is not None and numeric > column.maximum:
            issues.append(
                Issue(
                    location,
                    "value-out-of-range",
                    f"column '{column.name}' value {value} is above the maximum {column.maximum}",
                )
            )
            return None, issues
        return number, issues

    return value, issues


def read_table(table: Table, path: Path) -> tuple[list[Row], list[Issue]]:
    """Parse one CSV against its schema. Missing files are reported, not raised."""

    issues: list[Issue] = []
    display = path.name
    if not path.exists():
        return [], [Issue(display, "missing-file", f"required catalog file '{path}' does not exist")]

    with path.open(newline="", encoding="utf-8-sig") as handle:
        records = list(csv.reader(handle))

    if not records:
        return [], [Issue(display, "missing-header", "file is empty; the schema header is required")]

    header = [cell.strip() for cell in records[0]]
    expected = table.column_names
    if header != expected:
        missing = [name for name in expected if name not in header]
        unknown = [name for name in header if name not in expected]
        detail = []
        if missing:
            detail.append(f"missing columns: {', '.join(missing)}")
        if unknown:
            detail.append(f"unknown columns: {', '.join(unknown)}")
        if not detail:
            detail.append("columns are out of order")
        issues.append(
            Issue(f"{display}:1", "header-mismatch", "; ".join(detail) + f"; expected exactly: {', '.join(expected)}")
        )
        return [], issues

    rows: list[Row] = []
    for offset, record in enumerate(records[1:]):
        line = offset + 2
        location = f"{display}:{line}"
        if not any(cell.strip() for cell in record):
            issues.append(Issue(location, "blank-row", "blank rows are not allowed"))
            continue
        if len(record) != len(expected):
            issues.append(
                Issue(
                    location,
                    "column-count-mismatch",
                    f"expected {len(expected)} columns, found {len(record)}",
                )
            )
            continue

        values: dict[str, object] = {}
        raw: dict[str, str] = {}
        for column, cell in zip(table.columns, record):
            raw[column.name] = cell.strip()
            parsed, cell_issues = _parse_value(column, cell, location)
            issues.extend(cell_issues)
            if parsed is not None:
                values[column.name] = parsed
        rows.append(Row(table=table.name, line=line, location=location, values=values, raw=raw))

    seen: dict[tuple[str, ...], int] = {}
    for row in rows:
        key = row.key(table)
        if "" in key:
            continue
        previous = seen.get(key)
        if previous is not None:
            issues.append(
                Issue(
                    row.location,
                    "duplicate-key",
                    f"{'/'.join(table.key)} '{', '.join(key)}' already appears on line {previous}",
                )
            )
            continue
        seen[key] = row.line

    if table.singleton and len(rows) != 1:
        issues.append(
            Issue(display, "singleton-row-count", f"expected exactly one row, found {len(rows)}")
        )

    return rows, issues


def read_catalog(catalog_root: Path, game_root: Path) -> tuple[Catalog, list[Issue]]:
    """Read every table for one catalog root plus one game directory."""

    catalog = Catalog(catalog_root=catalog_root, game_root=game_root)
    issues: list[Issue] = []
    for table in schema.TABLES:
        base = catalog_root if table.scope == schema.CATALOG else game_root
        rows, table_issues = read_table(table, base / table.filename)
        catalog.rows[table.name] = rows
        issues.extend(table_issues)
    return catalog, issues
