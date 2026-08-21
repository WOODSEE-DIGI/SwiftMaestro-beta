#!/bin/bash
# Rebuild the SwiftMaestro Web Clipper JavaScript bundle.
#
# The clipper is Defuddle (the Obsidian Web Clipper extraction engine) plus a
# custom full-metadata entry point. The entry source lives in the
# obsidian-clipper checkout at:
#   ~/GitHub/Apple-Swift-iOS-macOS/obsidian-clipper/src/swiftmaestro-clipper.ts
# (also mirrored in this repo at clipper-src/swiftmaestro-clipper.ts).
#
# Prerequisites: the obsidian-clipper checkout with node_modules installed
# (defuddle + esbuild). No downloads are performed by this script.
#
# Usage: ./scripts/build-clipper.sh

set -euo pipefail

CLIPPER_REPO="${CLIPPER_REPO:-$HOME/GitHub/Apple-Swift-iOS-macOS/obsidian-clipper}"
ENTRY="src/swiftmaestro-clipper.ts"
OUT="dist/swiftmaestro-clipper.js"
TARGET="$(dirname "$0")/../Sources/Resources/swiftmaestro-clipper.js"

if [ ! -d "$CLIPPER_REPO/node_modules" ]; then
  echo "error: $CLIPPER_REPO has no node_modules — run npm install there first" >&2
  exit 1
fi

# Keep our mirrored entry in sync with the canonical one in the clipper repo.
MIRROR="$(dirname "$0")/../clipper-src/swiftmaestro-clipper.ts"
if [ -f "$MIRROR" ]; then
  cp "$MIRROR" "$CLIPPER_REPO/$ENTRY"
fi

echo "Building clipper bundle from $CLIPPER_REPO/$ENTRY ..."
(cd "$CLIPPER_REPO" && node_modules/.bin/esbuild "$ENTRY" --bundle --format=iife --minify --outfile="$OUT")

if [ ! -f "$CLIPPER_REPO/$OUT" ]; then
  echo "error: build produced no output at $OUT" >&2
  exit 1
fi

cp "$CLIPPER_REPO/$OUT" "$TARGET"
echo "Installed: $TARGET ($(du -h "$TARGET" | cut -f1))"
echo "NOTE: this JS is build output — do not edit it directly."
echo "Edit clipper-src/swiftmaestro-clipper.ts and re-run this script."
