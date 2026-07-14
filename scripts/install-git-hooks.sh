#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HOOKS_PATH="$REPO_ROOT/.githooks"
ACTION="install"
FORCE=0

usage() {
    cat <<'EOF'
Usage: scripts/install-git-hooks.sh [--force | --uninstall]

Configures this checkout to use the version-controlled hooks in .githooks.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

CURRENT_PATH="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ -z "$CURRENT_PATH" ]]; then
        echo "Git hooks are not configured for this checkout."
    elif [[ "$CURRENT_PATH" == "$HOOKS_PATH" || "$CURRENT_PATH" == ".githooks" ]]; then
        git -C "$REPO_ROOT" config --local --unset core.hooksPath
        echo "Removed Reco's Git hook configuration."
    else
        echo "error: core.hooksPath points to '$CURRENT_PATH'; refusing to remove it" >&2
        exit 1
    fi
    exit 0
fi

if [[ -n "$CURRENT_PATH" && "$CURRENT_PATH" != "$HOOKS_PATH" && "$CURRENT_PATH" != ".githooks" && "$FORCE" -ne 1 ]]; then
    echo "error: core.hooksPath already points to '$CURRENT_PATH'" >&2
    echo "Run with --force to replace it." >&2
    exit 1
fi

chmod +x \
    "$HOOKS_PATH/pre-commit" \
    "$REPO_ROOT/scripts/format-swift.sh" \
    "$REPO_ROOT/scripts/install-git-hooks.sh"
git -C "$REPO_ROOT" config --local core.hooksPath "$HOOKS_PATH"

echo "Installed Reco Git hooks for this checkout."
echo "The pre-commit hook formats and re-stages staged Swift files."
