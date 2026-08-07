"""Deterministic compiler and validator for the ClickGame music CSV catalog.

The CSVs under `music/` are the source of truth. This package reads them, applies
schema/reference/region/license/approval validation, and compiles a deterministic
Luau module for runtime consumption. Nothing here touches Roblox or Studio.
"""
