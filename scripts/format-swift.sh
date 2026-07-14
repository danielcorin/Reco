#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
CONFIGURATION="$REPO_ROOT/.swift-format"

if ! xcrun --find swift-format >/dev/null 2>&1; then
    echo "error: swift-format was not found; install Xcode and select it with xcode-select" >&2
    exit 1
fi

if [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    FILES=()
    while IFS= read -r -d '' file; do
        FILES+=("$file")
    done < <(git -C "$REPO_ROOT" ls-files -z -- '*.swift')
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    exit 0
fi

cd "$REPO_ROOT"
xcrun swift-format format \
    --configuration "$CONFIGURATION" \
    --in-place \
    --parallel \
    "${FILES[@]}"
