#!/bin/bash
# SwiftMaestro single release pipeline.
#
# One entry point, resumable stages, and polling notarization so a failure
# never throws away hours of successful work.
#
# Stages (each is skipped if its state marker exists and is still valid):
#   1. preflight   — git/version/dist/model checks
#   2. build       — Release app build
#   3. sign        — bundle dylibs, sign nested Mach-O, audit, verify
#   4. notarize-app — submit app zip preflight, wait for Apple (NOTARIZE=1 only)
#   5. package     — full + light .pkg/.zip in parallel
#   6. notarize-pkg — submit both .pkg files, wait, staple (NOTARIZE=1 only)
#   7. appcast     — Sparkle appcasts + deltas
#   8. upload      — push to Onidel/1984 (UPLOAD=1 only)
#
# Usage:
#   ./scripts/release.sh                 # run entire pipeline
#   ./scripts/release.sh notarize-app    # run only the app preflight stage
#   FORCE_BUILD=1 ./scripts/release.sh   # force a stage to rerun
#
# Env overrides:
#   VERSION=<x.y.z>            (default reads from app Info.plist)
#   NOTARIZE=1                 (default 0; required for Apple notarization)
#   UPLOAD=1                   (default 0; required for upload)
#   SKIP_MODEL_VALIDATION=1    (skip model-link validation)
#   RELEASE_TMPDIR=<path>      (large temp dir; defaults to system temp)
#   RELEASE_STATE_DIR=<path>   (defaults to build/release-state)
#   SPARKLE_ARCHIVE_CACHE=<dir> (defaults to ./.sparkle-archive-cache)
#   ARCHIVE_CACHE_MAX=<n>      (default 3)
#   DOWNLOAD_URL_PREFIX=<url>  (Onidel base URL)
#   ONIDEL_UPLOAD / DEPLOY_SCRIPT / SM_SFTP_* (upload infra)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
APP_NAME="SwiftMaestro"
APP_BUNDLE="build/Release/${APP_NAME}.app"
DIST_DIR="$PWD/dist"
STATE_DIR="${RELEASE_STATE_DIR:-$PWD/build/release-state}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SwiftMaestroNotary}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Developer ID Application}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-Developer ID Installer}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/Resources/SwiftMaestro.entitlements}"
SPARKLE_ARCHIVE_CACHE="${SPARKLE_ARCHIVE_CACHE:-$PWD/.sparkle-archive-cache}"
ARCHIVE_CACHE_MAX="${ARCHIVE_CACHE_MAX:-3}"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
state_file() { echo "$STATE_DIR/$1.done"; }
state_mark() {
    local name="$1"
    local value="${2:-}"
    local file
    file="$(state_file "$name")"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$value" > "$file"
}
state_read() {
    local file
    file="$(state_file "$1")"
    [ -f "$file" ] && cat "$file" || true
}
state_exists() { [ -f "$(state_file "$1")" ]; }
state_age() {
    local file
    file="$(state_file "$1")"
    [ -f "$file" ] && stat -f%m "$file" || echo 0
}
state_clear() { rm -f "$(state_file "$1")"; }

current_git_head() { git rev-parse HEAD 2>/dev/null || echo "unknown"; }

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

require_dir() { [ -d "$1" ] || die "missing directory: $1"; }
require_file() { [ -f "$1" ] || die "missing file: $1"; }

resolve_sparkle_bin() {
    local bin
    bin="${SPARKLE_BIN:-$(find "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/Caskroom/sparkle" -maxdepth 2 -type d -name bin 2>/dev/null | sort -V | tail -1)}"
    [ -n "$bin" ] && [ -x "$bin/generate_appcast" ] || die "Sparkle generate_appcast not found. Install: brew install --cask sparkle"
    echo "$bin"
}

# ---------------------------------------------------------------------------
# Notarization helpers (polling, non-blocking submit)
# ---------------------------------------------------------------------------
notary_submit() {
    local file="$1"
    local state_name="$2"
    local submit_out id
    echo "Submitting $(basename "$file") for notarization…" >&2
    submit_out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --no-wait 2>&1)"
    echo "$submit_out" >&2
    id="$(echo "$submit_out" | awk '/id:/{print $2; exit}')"
    [ -n "$id" ] || die "failed to submit $(basename "$file") for notarization"
    state_mark "$state_name" "{\"id\":\"$id\",\"file\":\"$file\",\"status\":\"In Progress\"}"
    echo "$id"
}

notary_wait_id() {
    local id="$1"
    local file="$2"
    echo "Waiting for notarization $id ($(basename "$file"))…"
    if xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" -v 2>&1; then
        echo "Notarization accepted: $(basename "$file")"
        return 0
    else
        echo "Notarization failed: $(basename "$file") — fetching log:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true
        return 1
    fi
}

notary_staple() {
    local file="$1"
    echo "Stapling notarization ticket to $(basename "$file")…"
    xcrun stapler staple "$file"
    xcrun stapler validate "$file" >/dev/null || die "stapler validation failed for $file"
}

# ---------------------------------------------------------------------------
# Stage 1: preflight
# ---------------------------------------------------------------------------
stage_preflight() {
    echo "=== Stage 1/8: preflight ==="

    # Git tree must be clean so the version being shipped is exactly what is tagged.
    if ! git diff --quiet; then
        echo "ERROR: working tree has uncommitted changes"
        git status --short
        exit 1
    fi
    if ! git diff --cached --quiet; then
        echo "ERROR: staged but uncommitted changes exist"
        exit 1
    fi

    require_file "$ENTITLEMENTS"
    require_file "Sources/Resources/Info.plist"

    VERSION="${VERSION:-$(defaults read "$PWD/Sources/Resources/Info.plist" CFBundleShortVersionString)}"
    export VERSION
    echo "Releasing $APP_NAME $VERSION"

    # Version must be newer than the latest tag.
    local latest_tag latest_version lower
    latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || git tag -l --sort=-v:refname | head -1 || true)"
    if [ -n "$latest_tag" ]; then
        latest_version="${latest_tag#v}"
        if [ "$VERSION" = "$latest_version" ]; then
            die "Info.plist version $VERSION equals latest tag $latest_tag. Bump first."
        fi
        lower="$(printf '%s\n%s\n' "$latest_version" "$VERSION" | sort -V | head -1)"
        [ "$lower" = "$latest_version" ] || die "Info.plist version $VERSION is not greater than latest tag $latest_tag"
        echo "OK: version $VERSION is newer than tag $latest_tag"
    fi

    # CHANGELOG mention (warning only).
    if [ -f "CHANGELOG.md" ] && ! grep -qE "^(#|##) .*\b${VERSION}\b" CHANGELOG.md; then
        echo "WARNING: CHANGELOG.md has no '## $VERSION' entry"
    fi

    # Dist conflict check only when not resuming a previous run.
    local artifact
    if ! state_exists package-full || ! state_exists package-light; then
        for artifact in \
            "$DIST_DIR/${APP_NAME}-${VERSION}-full.pkg" \
            "$DIST_DIR/${APP_NAME}-${VERSION}-light.pkg" \
            "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" \
            "$DIST_DIR/${APP_NAME}-${VERSION}-light.zip" \
            "$DIST_DIR/appcast.xml" \
            "$DIST_DIR/appcast-light.xml"; do
            if [ -e "$artifact" ]; then
                die "existing artifact would be overwritten: $artifact. Run 'rm -rf dist/*' or remove state with 'rm -rf $STATE_DIR'."
            fi
        done
    fi

    # Model links.
    if [ "${SKIP_MODEL_VALIDATION:-0}" = "1" ]; then
        echo "Skipping model validation (SKIP_MODEL_VALIDATION=1)"
    else
        ./scripts/validate-model-links.sh || die "model link validation failed"
    fi

    # Sparkle tooling.
    SPARKLE_BIN="$(resolve_sparkle_bin)"
    export SPARKLE_BIN

    mkdir -p "$DIST_DIR"
    [ -n "${RELEASE_TMPDIR:-}" ] && mkdir -p "$RELEASE_TMPDIR"

    state_mark preflight "version=$VERSION;head=$(current_git_head)"
    echo "Preflight OK."
}

# ---------------------------------------------------------------------------
# Stage 2: build
# ---------------------------------------------------------------------------
stage_build() {
    echo "=== Stage 2/8: build ==="
    local head
    head="$(current_git_head)"

    if [ "${FORCE_BUILD:-0}" != "1" ] && state_exists build; then
        local marker
        marker="$(state_read build)"
        if [ "$marker" = "$head" ] && [ -d "$APP_BUNDLE" ]; then
            echo "Build already completed for $head; skipping. Use FORCE_BUILD=1 to rebuild."
            return 0
        fi
    fi

    echo "Building Release app…"
    ./scripts/build.sh || die "build failed"
    [ -d "$APP_BUNDLE" ] || die "app bundle not found after build"

    state_mark build "$head"
    echo "Build OK."
}

# ---------------------------------------------------------------------------
# Stage 3: sign
# ---------------------------------------------------------------------------
stage_sign() {
    echo "=== Stage 3/8: sign ==="
    require_dir "$APP_BUNDLE"

    local app_mtime marker_age
    app_mtime="$(stat -f%m "$APP_BUNDLE")"
    marker_age="$(state_age sign)"

    if [ "${FORCE_SIGN:-0}" != "1" ] && state_exists sign && [ "$marker_age" -ge "$app_mtime" ]; then
        echo "Sign stage already completed for current app bundle; skipping. Use FORCE_SIGN=1 to re-sign."
        return 0
    fi

    echo "Bundling/re-signing Homebrew dylibs…"
    APP_PATH="$APP_BUNDLE" SIGN_IDENTITY="$APP_SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
        ./scripts/bundle-dylibs.sh || die "bundle-dylibs failed"

    echo "Signing nested Mach-O binaries…"
    APP_PATH="$APP_BUNDLE" SIGN_IDENTITY="$APP_SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
        ./scripts/sign-nested-binaries.sh || die "sign-nested-binaries failed"

    echo "Auditing dependency closure…"
    ./scripts/audit-dependencies.sh "$APP_BUNDLE" || die "audit-dependencies failed"

    echo "Verifying app bundle signature…"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || die "app signature verification failed"

    state_mark sign "$(current_git_head)"
    echo "Sign OK."
}

# ---------------------------------------------------------------------------
# Stage 4: notarize app preflight
# ---------------------------------------------------------------------------
stage_notarize_app() {
    if [ "${NOTARIZE:-0}" != "1" ]; then
        echo "NOTARIZE=0 — skipping app notarization preflight"
        return 0
    fi

    echo "=== Stage 4/8: app notarization preflight ==="
    require_dir "$APP_BUNDLE"

    local preflight_zip id status_json id_status
    preflight_zip="$STATE_DIR/${APP_NAME}-${VERSION}-app-preflight.zip"

    if state_exists notarize-app; then
        status_json="$(state_read notarize-app)"
        id_status="$(echo "$status_json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
        id="$(echo "$status_json" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
        case "$id_status" in
            Accepted)
                echo "App notarization preflight already accepted ($id)"
                return 0
                ;;
            In\ Progress)
                echo "Resuming notarization wait for app preflight ($id)…"
                notary_wait_id "$id" "$preflight_zip" || die "app notarization preflight failed"
                state_mark notarize-app "{\"id\":\"$id\",\"file\":\"$preflight_zip\",\"status\":\"Accepted\"}"
                echo "App notarization preflight accepted."
                return 0
                ;;
            *)
                die "app notarization preflight previously failed ($id). Remove $STATE_DIR to retry."
                ;;
        esac
    fi

    echo "Creating app preflight zip…"
    rm -f "$preflight_zip"
    ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$preflight_zip"

    id="$(notary_submit "$preflight_zip" notarize-app)"
    notary_wait_id "$id" "$preflight_zip" || die "app notarization preflight failed"
    state_mark notarize-app "{\"id\":\"$id\",\"file\":\"$preflight_zip\",\"status\":\"Accepted\"}"
    echo "App notarization preflight accepted."
}

# ---------------------------------------------------------------------------
# Stage 5: package full + light in parallel
# ---------------------------------------------------------------------------
stage_package() {
    echo "=== Stage 5/8: package full + light ==="

    local run_full=1 run_light=1
    state_exists package-full && [ "${FORCE_PACKAGE:-0}" != "1" ] && run_full=0
    state_exists package-light && [ "${FORCE_PACKAGE:-0}" != "1" ] && run_light=0

    if [ "$run_full" -eq 0 ] && [ "$run_light" -eq 0 ]; then
        echo "Packages already built; skipping. Use FORCE_PACKAGE=1 to rebuild."
        return 0
    fi

    mkdir -p "$DIST_DIR"

    local full_log light_log
    full_log="$STATE_DIR/package-full.log"
    light_log="$STATE_DIR/package-light.log"
    rm -f "$full_log" "$light_log"

    local pid_full pid_light

    if [ "$run_full" -eq 1 ]; then
        echo "Starting full package build…"
        OUTPUT_DIR="$DIST_DIR" ./scripts/package-full-pkg.sh > "$full_log" 2>&1 &
        pid_full=$!
    fi

    if [ "$run_light" -eq 1 ]; then
        echo "Starting light package build…"
        OUTPUT_DIR="$DIST_DIR" ./scripts/package-light-pkg.sh > "$light_log" 2>&1 &
        pid_light=$!
    fi

    local rc=0
    if [ -n "${pid_full:-}" ]; then
        if wait "$pid_full"; then
            state_mark package-full "ok"
            echo "Full package build OK."
        else
            echo "Full package build FAILED:" >&2
            cat "$full_log" >&2
            rc=1
        fi
    fi

    if [ -n "${pid_light:-}" ]; then
        if wait "$pid_light"; then
            state_mark package-light "ok"
            echo "Light package build OK."
        else
            echo "Light package build FAILED:" >&2
            cat "$light_log" >&2
            rc=1
        fi
    fi

    [ "$rc" -eq 0 ] || die "packaging failed"

    for artifact in \
        "$DIST_DIR/${APP_NAME}-${VERSION}-full.pkg" \
        "$DIST_DIR/${APP_NAME}-${VERSION}-light.pkg" \
        "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" \
        "$DIST_DIR/${APP_NAME}-${VERSION}-light.zip"; do
        [ -f "$artifact" ] || die "missing expected artifact: $artifact"
    done

    echo "Packaging OK."
}

# ---------------------------------------------------------------------------
# Stage 6: notarize packages
# ---------------------------------------------------------------------------
stage_notarize_pkgs() {
    if [ "${NOTARIZE:-0}" != "1" ]; then
        echo "NOTARIZE=0 — skipping package notarization"
        return 0
    fi

    echo "=== Stage 6/8: package notarization ==="

    local full_pkg light_pkg full_id light_pkg_id
    full_pkg="$DIST_DIR/${APP_NAME}-${VERSION}-full.pkg"
    light_pkg="$DIST_DIR/${APP_NAME}-${VERSION}-light.pkg"
    require_file "$full_pkg"
    require_file "$light_pkg"

    # Resume or submit full.
    if state_exists notarize-full; then
        local json sid status
        json="$(state_read notarize-full)"
        sid="$(echo "$json" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
        status="$(echo "$json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
        if [ "$status" = "Accepted" ]; then
            echo "Full PKG notarization already accepted ($sid)"
        else
            echo "Resuming full PKG notarization ($sid)…"
            notary_wait_id "$sid" "$full_pkg" || die "full PKG notarization failed"
            state_mark notarize-full "{\"id\":\"$sid\",\"file\":\"$full_pkg\",\"status\":\"Accepted\"}"
            notary_staple "$full_pkg"
        fi
    else
        full_id="$(notary_submit "$full_pkg" notarize-full)"
        notary_wait_id "$full_id" "$full_pkg" || die "full PKG notarization failed"
        state_mark notarize-full "{\"id\":\"$full_id\",\"file\":\"$full_pkg\",\"status\":\"Accepted\"}"
        notary_staple "$full_pkg"
    fi

    # Resume or submit light.
    if state_exists notarize-light; then
        local json sid status
        json="$(state_read notarize-light)"
        sid="$(echo "$json" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
        status="$(echo "$json" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
        if [ "$status" = "Accepted" ]; then
            echo "Light PKG notarization already accepted ($sid)"
        else
            echo "Resuming light PKG notarization ($sid)…"
            notary_wait_id "$sid" "$light_pkg" || die "light PKG notarization failed"
            state_mark notarize-light "{\"id\":\"$sid\",\"file\":\"$light_pkg\",\"status\":\"Accepted\"}"
            notary_staple "$light_pkg"
        fi
    else
        light_pkg_id="$(notary_submit "$light_pkg" notarize-light)"
        notary_wait_id "$light_pkg_id" "$light_pkg" || die "light PKG notarization failed"
        state_mark notarize-light "{\"id\":\"$light_pkg_id\",\"file\":\"$light_pkg\",\"status\":\"Accepted\"}"
        notary_staple "$light_pkg"
    fi

    echo "Package notarization OK."
}

# ---------------------------------------------------------------------------
# Stage 7: appcasts
# ---------------------------------------------------------------------------
stage_appcast() {
    echo "=== Stage 7/8: appcast generation ==="
    if state_exists appcast && [ "${FORCE_APPCAST:-0}" != "1" ]; then
        echo "Appcasts already generated; skipping. Use FORCE_APPCAST=1 to regenerate."
        return 0
    fi

    local key_dir key_file
    key_dir="$(mktemp -d)"
    trap 'rm -rf "$key_dir"' EXIT
    key_file="$key_dir/sparkle-key.pem"
    "$SPARKLE_BIN/generate_keys" -x "$key_file" >/dev/null || die "failed to export Sparkle private key"
    [ -s "$key_file" ] || die "Sparkle key export produced empty file"

    mkdir -p "$SPARKLE_ARCHIVE_CACHE"
    cp "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" "$SPARKLE_ARCHIVE_CACHE/"
    ls -t "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-full.zip 2>/dev/null | tail -n +$((ARCHIVE_CACHE_MAX + 1)) | while IFS= read -r old; do
        [ -n "$old" ] && rm -f "$old"
    done
    cp "$DIST_DIR/${APP_NAME}-${VERSION}-light.zip" "$SPARKLE_ARCHIVE_CACHE/"
    ls -t "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-light.zip 2>/dev/null | tail -n +$((ARCHIVE_CACHE_MAX + 1)) | while IFS= read -r old; do
        [ -n "$old" ] && rm -f "$old"
    done

    # Full appcast.
    local work
    work="$DIST_DIR/.appcast-work"
    rm -rf "$work"
    mkdir -p "$work"
    ln "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" "$work/${APP_NAME}-${VERSION}-full.zip"
    for archive in "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-full.zip; do
        [ -f "$archive" ] || continue
        local name
        name="$(basename "$archive")"
        [ -e "$work/$name" ] && continue
        ln "$archive" "$work/$name"
    done
    if [ -f "CHANGELOG.md" ]; then
        cp "CHANGELOG.md" "$work/${APP_NAME}-${VERSION}-full.md"
    fi
    "$SPARKLE_BIN/generate_appcast" \
        --ed-key-file "$key_file" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        -o "$DIST_DIR/appcast.xml" \
        "$work" || die "generate_appcast (full) failed"
    for delta in "$work"/*.delta; do
        [ -f "$delta" ] || continue
        mv "$delta" "$DIST_DIR/"
    done
    for notes in "$work"/*.md; do
        [ -f "$notes" ] || continue
        mv "$notes" "$DIST_DIR/"
    done
    rm -rf "$work"

    # Light appcast.
    work="$DIST_DIR/.appcast-light-work"
    rm -rf "$work"
    mkdir -p "$work"
    ln "$DIST_DIR/${APP_NAME}-${VERSION}-light.zip" "$work/${APP_NAME}-${VERSION}-light.zip"
    for archive in "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-light.zip; do
        [ -f "$archive" ] || continue
        local name
        name="$(basename "$archive")"
        [ -e "$work/$name" ] && continue
        ln "$archive" "$work/$name"
    done
    if [ -f "CHANGELOG.md" ]; then
        cp "CHANGELOG.md" "$work/${APP_NAME}-${VERSION}-light.md"
    fi
    "$SPARKLE_BIN/generate_appcast" \
        --ed-key-file "$key_file" \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
        -o "$DIST_DIR/appcast-light.xml" \
        "$work" || die "generate_appcast (light) failed"
    for delta in "$work"/*.delta; do
        [ -f "$delta" ] || continue
        mv "$delta" "$DIST_DIR/"
    done
    for notes in "$work"/*.md; do
        [ -f "$notes" ] || continue
        mv "$notes" "$DIST_DIR/"
    done
    rm -rf "$work"

    require_file "$DIST_DIR/appcast.xml"
    require_file "$DIST_DIR/appcast-light.xml"

    state_mark appcast "ok"
    echo "Appcasts OK."
}

# ---------------------------------------------------------------------------
# Stage 8: upload
# ---------------------------------------------------------------------------
stage_upload() {
    if [ "${UPLOAD:-0}" != "1" ]; then
        echo "UPLOAD=0 — skipping upload. Artifacts are in $DIST_DIR"
        return 0
    fi

    echo "=== Stage 8/8: upload ==="
    if state_exists upload && [ "${FORCE_UPLOAD:-0}" != "1" ]; then
        echo "Upload already completed; skipping. Use FORCE_UPLOAD=1 to re-upload."
        return 0
    fi

    local onidel_upload deploy_script
    onidel_upload="${ONIDEL_UPLOAD:-$HOME/GitHub/FUSV/Websites/swiftmaestro-site/upload-to-onidel.sh}"
    deploy_script="${DEPLOY_SCRIPT:-$HOME/GitHub/FUSV/Websites/swiftmaestro-site/deploy.sh}"

    [ -x "$onidel_upload" ] || die "upload script not found at $onidel_upload"

    echo "Uploading installers and archives to Onidel…"
    "$onidel_upload" "$DIST_DIR/${APP_NAME}-${VERSION}-full.pkg"
    "$onidel_upload" "$DIST_DIR/${APP_NAME}-${VERSION}-light.pkg"
    "$onidel_upload" "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip"
    "$onidel_upload" "$DIST_DIR/${APP_NAME}-${VERSION}-light.zip"

    for delta in "$DIST_DIR"/*.delta; do
        [ -f "$delta" ] || continue
        "$onidel_upload" "$delta"
    done

    for notes in "$DIST_DIR"/*.md; do
        [ -f "$notes" ] || continue
        "$onidel_upload" "$notes"
    done

    echo "Uploading appcasts to Onidel…"
    "$onidel_upload" --appcast "$DIST_DIR/appcast.xml"
    "$onidel_upload" --appcast "$DIST_DIR/appcast-light.xml"

    # 1984 same-origin appcast upload.
    local sftp_user sftp_host sftp_port sftp_pass
    sftp_user="${SM_SFTP_USER:-}"
    sftp_host="${SM_SFTP_HOST:-}"
    sftp_port="${SM_SFTP_PORT:-2222}"
    if [ -n "$sftp_user" ] && [ -n "$sftp_host" ]; then
        sftp_pass="${SM_SFTP_PASS:-$(security find-generic-password -s 'swiftmaestro-1984-sftp' -a "$sftp_user" -w 2>/dev/null || true)}"
        if [ -z "$sftp_pass" ]; then
            echo "WARNING: SFTP password not found — skipping 1984 appcast upload"
        else
            LFTP_PASSWORD="$sftp_pass" lftp --env-password -u "$sftp_user" -p "$sftp_port" "sftp://${sftp_host}" <<LPFTP
set cmd:fail-exit yes
set sftp:auto-confirm yes
set ssl:verify-certificate no
set net:timeout 30
rm -f htdocs/download/appcast.xml
put '$DIST_DIR/appcast.xml' -o htdocs/download/appcast.xml
rm -f htdocs/download/appcast-light.xml
put '$DIST_DIR/appcast-light.xml' -o htdocs/download/appcast-light.xml
bye
LPFTP
            local remote_size local_size
            remote_size="$(LFTP_PASSWORD="$sftp_pass" lftp --env-password -u "$sftp_user" -p "$sftp_port" "sftp://${sftp_host}" -e "set sftp:auto-confirm yes; set ssl:verify-certificate no; cat htdocs/download/appcast.xml; bye" 2>/dev/null | wc -c | tr -d ' ')"
            local_size="$(stat -f%z "$DIST_DIR/appcast.xml")"
            [ "$remote_size" = "$local_size" ] || die "1984 appcast upload size mismatch"

            remote_size="$(LFTP_PASSWORD="$sftp_pass" lftp --env-password -u "$sftp_user" -p "$sftp_port" "sftp://${sftp_host}" -e "set sftp:auto-confirm yes; set ssl:verify-certificate no; cat htdocs/download/appcast-light.xml; bye" 2>/dev/null | wc -c | tr -d ' ')"
            local_size="$(stat -f%z "$DIST_DIR/appcast-light.xml")"
            [ "$remote_size" = "$local_size" ] || die "1984 appcast-light upload size mismatch"
        fi
    else
        echo "SM_SFTP_USER/SM_SFTP_HOST not set — skipping 1984 appcast upload"
    fi

    # Website deploy.
    if [ -x "$deploy_script" ]; then
        local site_appcast site_appcast_light
        site_appcast="$(dirname "$deploy_script")/download/appcast.xml"
        site_appcast_light="$(dirname "$deploy_script")/download/appcast-light.xml"
        if [ -d "$(dirname "$site_appcast")" ]; then
            cp "$DIST_DIR/appcast.xml" "$site_appcast"
            cp "$DIST_DIR/appcast-light.xml" "$site_appcast_light"
            echo "Synced appcasts into site repo before deploy"
        fi
        "$deploy_script" || die "website deploy failed"
    else
        echo "Deploy script not found at $deploy_script — skipping website deploy"
    fi

    state_mark upload "ok"
    echo "Upload OK."
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
CMD="${1:-all}"

case "$CMD" in
    all)
        stage_preflight
        stage_build
        stage_sign
        stage_notarize_app
        stage_package
        stage_notarize_pkgs
        stage_appcast
        stage_upload
        echo ""
        echo "=== Release $VERSION complete ==="
        ls -lh "$DIST_DIR"
        ;;
    preflight)  stage_preflight ;;
    build)      stage_preflight; stage_build ;;
    sign)       stage_preflight; stage_build; stage_sign ;;
    notarize-app)
        stage_preflight; stage_build; stage_sign; stage_notarize_app ;;
    package)
        stage_preflight; stage_build; stage_sign; stage_notarize_app; stage_package ;;
    notarize-pkgs|notarize-packages)
        stage_preflight; stage_build; stage_sign; stage_notarize_app; stage_package; stage_notarize_pkgs ;;
    appcast)
        stage_preflight; stage_build; stage_sign; stage_notarize_app; stage_package; stage_notarize_pkgs; stage_appcast ;;
    upload)
        stage_preflight; stage_build; stage_sign; stage_notarize_app; stage_package; stage_notarize_pkgs; stage_appcast; stage_upload ;;
    *)
        echo "Unknown command: $CMD"
        echo "Usage: $0 [all|preflight|build|sign|notarize-app|package|notarize-pkgs|appcast|upload]"
        exit 1
        ;;
esac
