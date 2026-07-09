#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

if [[ -f default.project.json ]]; then
	PROJECT_FILE="default.project.json"
else
	mapfile -t PROJECT_FILES < <(find . -maxdepth 1 -type f -name '*.project.json' -printf '%f\n' | sort)

	if (( ${#PROJECT_FILES[@]} == 0 )); then
		echo "No Rojo project file found in $REPO_ROOT" >&2
		exit 1
	fi

	if (( ${#PROJECT_FILES[@]} > 1 )); then
		echo "Multiple Rojo project files found in $REPO_ROOT:" >&2
		printf '  %s\n' "${PROJECT_FILES[@]}" >&2
		echo "Set one as default.project.json or update this script." >&2
		exit 1
	fi

	PROJECT_FILE="${PROJECT_FILES[0]}"
fi

PORT="${ROJO_PORT:-34872}"
ADDRESS="127.0.0.1"

echo "Starting Rojo for $PROJECT_FILE on $ADDRESS:$PORT"
exec rojo serve --address "$ADDRESS" --port "$PORT" "$PROJECT_FILE"
