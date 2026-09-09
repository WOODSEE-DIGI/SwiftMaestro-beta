#!/bin/bash
# Pre-release safety checks for SwiftMaestro.
#
# This script fails fast BEFORE the multi-hour build/packaging/upload begins.
# Run it directly or let release.sh invoke it automatically.
#
# Checks:
#   1. Git working tree is clean (no uncommitted changes).
#   2. Info.plist version is strictly greater than the latest git tag.
#   3. No conflicting release artifacts already exist in dist/.
#   4. CHANGELOG.md mentions the version (warning only).
set -euo pipefail

APP_NAME="SwiftName? wait App name is SwiftMaestro"
APP_NAME="SwiftMaestro"
INFO_PLIST="Sources/Resources/Info.plist"
DIST_DIR="dist"

if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: $INFO_PLIST not found"
    exit 1
fi

CURRENT_VERSION="$(defaults read "$PWD/$INFO_PLIST" CFBundleShortVersionString)"

# ---------------------------------------------------------------------------
# 1. Clean working tree.
# ---------------------------------------------------------------------------
if ! git diff --quiet; then
    echo "ERROR: working tree has uncommitted changes. Commit or stash before releasing."
    git status --short
    exit 1
fi
if ! git diff --cached --quiet; then
    echo "ERROR: staged but uncommitted changes exist. Commit before releasing."
    git diff --cached --stat
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Version must be strictly greater than the latest tag.
# ---------------------------------------------------------------------------
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || git tag -l --sort=-v:refname | head -1 || true)"
if [ -z "${LATEST_TAG:-}" ]; then
    echo "WARNING: no previous git tags found; cannot compare versions"
else
    # Strip a leading 'v' if present.
    LATEST_VERSION="${LATEST_TAG#v}"
    if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        echo "ERROR: Info.plist version $CURRENT_VERSION equals latest tag $LATEST_TAG."
        echo "       Bump the version in $INFO_PLIST before running release.sh."
        exit 1
    fi
    LOWER="$(printf '%s\n%s\n' "$LATEST_VERSION" "$CURRENT_VERSION" | sort -V | head -1)"
    if [ "$LOWER" != "$LATEST_VERSION" ]; then
        echo "ERROR: Info.plist version $CURRENT_VERSION is not greater than latest tag $LATEST_TAG."
        echo "       Bump the version in $INFO_PLIST before running release.sh."
        exit 1
    fi
    echo "OK: version $CURRENT_VERSION is newer than latest tag $LATEST_TAG"
fi

# ---------------------------------------------------------------------------
# 3. No conflicting dist artifacts.
# ---------------------------------------------------------------------------
CONFLICT=0
for artifact in \
    "$DIST_DIR/${APP_NAME}-${CURRENT_VERSION}-full.pkg" \
    "$DIST_DIR/${APP_NAME}-${CURRENT_VERSION}-light.pkg" \
    "$DIST_DIR/${APP_NAME}-${CURRENT_VERSION}-full.zip" \
    "$DIST_DIR/${APP_NAME}-${CURRENT_VERSION}-light.zip" \
    "$DIST_DIR/appcast.xml" \
    "$DIST_DIR/appcast-light.xml"
do
    if [ -e "$artifact" ]; then
        echo "ERROR: existing artifact would be overwritten: $artifact"
        echo "       Run 'rm -rf $DIST_DIR/*' or move old artifacts before releasing."
        CONFLICT=1
    fi
done
if [ "$CONFLICT" -ne 0 ]; then
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. CHANGELOG mention (warning only).
# ---------------------------------------------------------------------------
if [ -f "CHANGELOG.md" ]; then
    if ! grep -qE "^## \[?${CURRENT_VERSION}\]?" CHANGELOG.md; then
        echo "WARNING: CHANGELOG.md has no '## $CURRENT_VERSION' entry."
    fi
fi

echo "OK: pre-release checks passed for $CURRENT_VERSION"
