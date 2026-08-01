#!/bin/bash
# bundle-mcp-servers.sh — Package default MCP servers into SwiftMaestro.app
#
# This script copies/built the MCP servers from the user's local development
# repositories into Sources/Resources/mcp-servers/ so they are embedded in the
# app bundle and extracted on first launch by MCPServerBundleService.
#
# Usage:
#   ./scripts/bundle-mcp-servers.sh
#   ./scripts/bundle-mcp-servers.sh --release
#
# The --release flag additionally runs production installs and strips dev
# dependencies to reduce bundle size.
#
# Env overrides:
#   AI_ML_ROOT=$HOME/GitHub/AI-ML-Agents
#   OUTPUT_DIR=Sources/Resources/mcp-servers

set -euo pipefail

PROD_MODE=0
for arg in "$@"; do
    case "$arg" in
        --release) PROD_MODE=1 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

AI_ML_ROOT="${AI_ML_ROOT:-$HOME/GitHub/AI-ML-Agents}"
OUTPUT_DIR="${OUTPUT_DIR:-BundledMCP/mcp-servers}"
MANIFEST="$OUTPUT_DIR/mcp-server-manifest.json"

# Directories where each server's source lives.
SRC_READ_WEBSITE_FAST="$AI_ML_ROOT/mcp-read-website-fast"
SRC_SWIFT_TERMINALS="$AI_ML_ROOT/Swift-terminals"
SRC_XCODEBUILD_MCP="$AI_ML_ROOT/XcodeBuildMCP"
SRC_AI_CONTEXT_BRIDGE="$HOME/.ai-context/mcp-server"
SRC_WEBCLAW="$AI_ML_ROOT/webclaw"
SRC_PLAYWRIGHT="$AI_ML_ROOT/playwright-mcp"
SRC_WHATSAPP="$AI_ML_ROOT/whatsapp-mcp"
SRC_FIRECRAWL_MCP="$AI_ML_ROOT/firecrawl-mcp-server"
SRC_CRAWLKIT_MCP="$HOME/.ai-context/mcp-crawlkit"

NODE_VERSION="${NODE_VERSION:-22.14.0}"
NODE_DIR="$OUTPUT_DIR/.runtime/node"

PYTHON_VERSION="${PYTHON_VERSION:-3.11.11}"
PYTHON_RELEASE="${PYTHON_RELEASE:-20250115}"
PYTHON_DIR="$OUTPUT_DIR/.runtime/python"
PYTHON_TARBALL="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${PYTHON_TARBALL}"
PYTHON_SHA256="${PYTHON_SHA256:-1988b302b26d2e6f6949c0b2e94194b5138c6015fe283c825489e173e4553503}"

log() { echo "[bundle-mcp] $*"; }
fail() { echo "[bundle-mcp] ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Download and bundle a Node.js runtime so the .dmg works without Homebrew.
# ---------------------------------------------------------------------------
bundle_node_runtime() {
    if [ -x "$NODE_DIR/bin/node" ] && [ "$($NODE_DIR/bin/node --version 2>/dev/null)" = "v$NODE_VERSION" ]; then
        log "Node.js v$NODE_VERSION already bundled"
        return
    fi

    log "Downloading Node.js v$NODE_VERSION runtime for macOS arm64"
    rm -rf "$NODE_DIR"
    mkdir -p "$NODE_DIR"
    local tarball="node-v$NODE_VERSION-darwin-arm64.tar.gz"
    local tmp="$(mktemp -d)"
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$tarball" -o "$tmp/$tarball"
    tar -xzf "$tmp/$tarball" -C "$tmp"
    mv "$tmp/node-v$NODE_VERSION-darwin-arm64"/* "$NODE_DIR/"
    rm -rf "$tmp"
    log "Bundled Node.js v$NODE_VERSION"
}

# ---------------------------------------------------------------------------
# Download and bundle a Python runtime for the WhatsApp MCP server.
# Uses python-build-standalone, which is relocatable and self-contained.
# ---------------------------------------------------------------------------
bundle_python_runtime() {
    if [ -x "$PYTHON_DIR/bin/python3" ] && [ "$($PYTHON_DIR/bin/python3 --version 2>/dev/null)" = "Python $PYTHON_VERSION" ]; then
        log "Python $PYTHON_VERSION already bundled"
        return
    fi

    log "Downloading Python $PYTHON_VERSION runtime (python-build-standalone $PYTHON_RELEASE)"
    rm -rf "$PYTHON_DIR"
    mkdir -p "$PYTHON_DIR"
    local tmp="$(mktemp -d)"
    local tmp_tarball="$tmp/$PYTHON_TARBALL"
    curl -fsSL "$PYTHON_URL" -o "$tmp_tarball"

    # Verify SHA256 checksum.
    local actual_sha256
    actual_sha256="$(shasum -a 256 "$tmp_tarball" | awk '{ print $1 }')"
    if [ "$actual_sha256" != "$PYTHON_SHA256" ]; then
        fail "Python runtime SHA256 mismatch: expected $PYTHON_SHA256, got $actual_sha256"
    fi
    log "Python runtime SHA256 verified"

    tar -xzf "$tmp_tarball" -C "$tmp"
    mv "$tmp/python"/* "$PYTHON_DIR/"
    rm -rf "$tmp"
    log "Bundled Python $PYTHON_VERSION"
}

log "Output directory: $OUTPUT_DIR"
log "AI-ML root: $AI_ML_ROOT"

# Sanity check: we are in the SwiftMaestro repo.
if [ ! -f "project.yml" ]; then
    fail "Run this script from the SwiftMaestro repo root."
fi

# Ensure output directory exists and is empty (we'll re-populate).
mkdir -p "$OUTPUT_DIR"

# If a server is not available locally, we keep the directory in the manifest
# but the script will warn. The bundle service will skip missing bundle paths
# gracefully (they won't be installed).

# ---------------------------------------------------------------------------
# Helper: copy a Node server source and run npm install
# ---------------------------------------------------------------------------
bundle_node_server() {
    local name=$1
    local src=$2
    local dest="$OUTPUT_DIR/$name"

    if [ ! -d "$src" ]; then
        log "WARN: $name source not found at $src — skipping"
        return
    fi

    log "Bundling $name from $src"
    rm -rf "$dest"
    mkdir -p "$dest"

    # Copy package files and source, avoiding git and node_modules.
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='.DS_Store' \
        "$src/" "$dest/"

    if [ "$PROD_MODE" = 1 ]; then
        (cd "$dest" && npm ci --production) || fail "npm install failed for $name"
    else
        (cd "$dest" && npm install) || fail "npm install failed for $name"
    fi

    log "Built $name"
}

# ---------------------------------------------------------------------------
# Helper: build the webclaw Rust binary and copy it
# ---------------------------------------------------------------------------
bundle_webclaw() {
    local name="webclaw"
    local src="$SRC_WEBCLAW"
    local dest="$OUTPUT_DIR/$name"

    if [ ! -d "$src" ]; then
        log "WARN: $name source not found at $src — skipping"
        return
    fi

    log "Building $name from $src"
    (cd "$src" && cargo build -p webclaw-mcp --release) || fail "cargo build failed for $name"

    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$src/target/release/webclaw-mcp" "$dest/"
    [ -f "$src/target/release/webclaw" ] && cp "$src/target/release/webclaw" "$dest/"
    log "Built $name"
}

# ---------------------------------------------------------------------------
# Helper: build the WhatsApp Go bridge and copy the Python MCP server.
# Creates a relocatable venv using the bundled Python runtime so the .dmg
# works without Homebrew or uv installed.
# ---------------------------------------------------------------------------
bundle_whatsapp() {
    local name="whatsapp"
    local src="$SRC_WHATSAPP"
    local dest="$OUTPUT_DIR/$name"

    if [ ! -d "$src" ]; then
        log "WARN: $name source not found at $src — skipping"
        return
    fi

    log "Building $name bridge from $src"
    # The bridge is a single-file Go program; build or reuse existing binary.
    if [ ! -f "$src/whatsapp-bridge/whatsapp-client" ]; then
        (cd "$src/whatsapp-bridge" && go build -o whatsapp-client main.go) || fail "go build failed for $name"
    fi

    rm -rf "$dest"
    mkdir -p "$dest/whatsapp-mcp-server" "$dest/whatsapp-bridge"

    cp "$src/whatsapp-bridge/whatsapp-client" "$dest/whatsapp-client"
    cp "$src/whatsapp-mcp-server/main.py" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/whatsapp.py" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/audio.py" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/pyproject.toml" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/uv.lock" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/requirements.txt" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp "$src/whatsapp-mcp-server/.python-version" "$dest/whatsapp-mcp-server/" 2>/dev/null || true
    cp -R "$src/whatsapp-bridge/" "$dest/whatsapp-bridge/" 2>/dev/null || true

    # Create a fully self-contained venv for the WhatsApp Python MCP server.
    # The source .venv may reference a system interpreter, so we recreate it with
    # the bundled Python runtime and point the venv python symlinks to the shared
    # runtime using a relative path. This makes the .dmg work on a clean Mac
    # without Homebrew or uv.
    if [ -d "$src/whatsapp-mcp-server/.venv" ]; then
        log "Creating self-contained Python venv for $name"
        local venv_dir="$dest/whatsapp-mcp-server/.venv"
        "$PYTHON_DIR/bin/python3" -m venv "$venv_dir"

        # Repoint the venv python symlinks to the bundled Python runtime.
        # The venv is at .../whatsapp/whatsapp-mcp-server/.venv; the shared
        # runtime is at .../mcp-servers/.runtime/python, so the relative path is
        # four levels up and into .runtime/python/bin.
        rm -f "$venv_dir/bin/python" "$venv_dir/bin/python3" "$venv_dir/bin/python3.11"
        (cd "$venv_dir/bin" && ln -s ../../../../.runtime/python/bin/python3.11 python3.11 && ln -s python3.11 python3 && ln -s python3 python)

        # Copy the installed site-packages from the source venv.
        cp -R "$src/whatsapp-mcp-server/.venv/lib/python3.11/site-packages/"* "$venv_dir/lib/python3.11/site-packages/"

        # Remove any broken symlinks left over from the source environment.
        find "$venv_dir" -type l -print0 | while IFS= read -r -d '' link; do
            if [ ! -e "$link" ]; then
                rm -f "$link"
            fi
        done
        log "Created self-contained venv for $name"
    fi

    log "Built $name"
}

# ---------------------------------------------------------------------------
# Main bundle sequence
# ---------------------------------------------------------------------------
log "Starting MCP server bundle..."

bundle_node_runtime
bundle_python_runtime

bundle_node_server "read-website-fast" "$SRC_READ_WEBSITE_FAST"
bundle_node_server "swift-terminals" "$SRC_SWIFT_TERMINALS"
bundle_node_server "xcodebuildmcp" "$SRC_XCODEBUILD_MCP"
bundle_node_server "ai-context-bridge" "$SRC_AI_CONTEXT_BRIDGE"
bundle_node_server "firecrawl-mcp" "$SRC_FIRECRAWL_MCP"
bundle_node_server "crawlkit-mcp" "$SRC_CRAWLKIT_MCP"

bundle_webclaw
bundle_whatsapp

# Playwright is special: huge browser binaries. For now, bundle only the MCP
# server code and instruct the bundle service to install browsers on first
# launch via the installCommand. In production we may want to make this an
# optional download instead.
if [ -d "$SRC_PLAYWRIGHT" ]; then
    bundle_node_server "playwright" "$SRC_PLAYWRIGHT"
    # Note: `npx playwright install chromium` will run on first launch via the
    # manifest installCommand. This keeps the initial .dmg smaller.
fi

# Verify the manifest is still present.
if [ ! -f "$MANIFEST" ]; then
    fail "Manifest file missing at $MANIFEST"
fi

log "Bundle complete. Next: run 'xcodegen generate' and build the app."
