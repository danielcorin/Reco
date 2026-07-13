#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/publish-release.sh /path/to/Reco.app [options]

Options:
  --version VERSION          Override CFBundleShortVersionString.
  --identity IDENTITY        Developer ID Application signing identity.
  --notary-profile PROFILE   Notarize and staple the generated DMG.
  --publish                  Create or update the corresponding GitHub Release.
  --repo OWNER/REPO          GitHub repository passed to gh.
  -h, --help                 Show this help.

Environment equivalents:
  DEVELOPER_IDENTITY, NOTARY_PROFILE, GH_REPO

The exported app must already be Developer ID-signed and notarized. Output is
written to dist/ as a versioned ZIP, DMG, and SHA256SUMS file.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -gt 0 ]] || {
    usage >&2
    exit 2
}

APP_PATH=""
VERSION=""
IDENTITY="${DEVELOPER_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
GH_REPOSITORY="${GH_REPO:-}"
PUBLISH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -gt 1 ]] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --identity)
            [[ $# -gt 1 ]] || fail "--identity requires a value"
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [[ $# -gt 1 ]] || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --publish)
            PUBLISH=1
            shift
            ;;
        --repo)
            [[ $# -gt 1 ]] || fail "--repo requires a value"
            GH_REPOSITORY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            fail "unknown option: $1"
            ;;
        *)
            [[ -z "$APP_PATH" ]] || fail "only one app path may be provided"
            APP_PATH="$1"
            shift
            ;;
    esac
done

[[ -n "$APP_PATH" ]] || fail "an exported Reco.app path is required"
[[ -d "$APP_PATH" ]] || fail "app not found: $APP_PATH"
[[ -f "$APP_PATH/Contents/Info.plist" ]] || fail "not a macOS app bundle: $APP_PATH"

for command in codesign ditto hdiutil shasum spctl xcrun; do
    command -v "$command" >/dev/null || fail "required command not found: $command"
done

PLIST_BUDDY=/usr/libexec/PlistBuddy
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found"

if [[ -z "$VERSION" ]]; then
    VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
fi
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "invalid version: $VERSION"

BUNDLE_ID="$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "llc.wvlen.Reco" ]] || fail "unexpected bundle identifier: $BUNDLE_ID"

echo "Verifying exported app..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
fi
[[ -n "$IDENTITY" ]] || fail "no Developer ID Application identity found"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "run this script from the Reco repository"
OUT_DIR="$REPO_ROOT/dist"
ZIP_NAME="Reco-$VERSION-macOS.zip"
DMG_NAME="Reco-$VERSION-macOS.dmg"
CHECKSUM_NAME="SHA256SUMS.txt"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
DMG_PATH="$OUT_DIR/$DMG_NAME"

mkdir -p "$OUT_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME"

echo "Creating $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reco-release.XXXXXX")"
cleanup_staging() {
    rm -rf "$STAGING_DIR"
}
trap cleanup_staging EXIT

ditto "$APP_PATH" "$STAGING_DIR/Reco.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating $DMG_NAME..."
hdiutil create \
    -volname "Reco" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "Signing DMG with $IDENTITY..."
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "note: DMG contains a notarized, stapled app but the DMG itself was not submitted."
    echo "      Pass --notary-profile PROFILE to notarize the outer container too."
fi

(
    cd "$OUT_DIR"
    shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > "$CHECKSUM_NAME"
)

echo "Created:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
echo "  $OUT_DIR/$CHECKSUM_NAME"

if [[ "$PUBLISH" -eq 1 ]]; then
    command -v gh >/dev/null || fail "GitHub CLI (gh) is required for --publish"
    gh auth status >/dev/null || fail "authenticate first with: gh auth login -h github.com"
    git -C "$REPO_ROOT" diff --quiet || fail "tracked working tree changes must be committed before publishing"
    git -C "$REPO_ROOT" diff --cached --quiet || fail "staged changes must be committed before publishing"

    TAG="v$VERSION"
    GH_ARGS=()
    if [[ -n "$GH_REPOSITORY" ]]; then
        GH_ARGS=(--repo "$GH_REPOSITORY")
    fi

    if gh release view "$TAG" "${GH_ARGS[@]}" >/dev/null 2>&1; then
        gh release upload "$TAG" \
            "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME" \
            --clobber "${GH_ARGS[@]}"
    else
        gh release create "$TAG" \
            "$ZIP_PATH" "$DMG_PATH" "$OUT_DIR/$CHECKSUM_NAME" \
            --target "$(git -C "$REPO_ROOT" rev-parse HEAD)" \
            --title "Reco $VERSION" \
            --generate-notes \
            "${GH_ARGS[@]}"
    fi

    echo "Published GitHub Release $TAG."
fi
