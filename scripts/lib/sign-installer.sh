#!/bin/bash
# Shared helper: sign an installer .pkg with productsign, retrying on the
# transient failures Apple's timestamp authority returns for very large
# packages.

# Usage:
#   source "$(dirname "$0")/lib/sign-installer.sh"
#   sign_installer_pkg "$identity" "$unsigned_pkg" "$output_pkg" [max_attempts]
#
# Environment:
#   SIGN_PKG_MAX_ATTEMPTS - default number of attempts if not overridden.

sign_installer_pkg() {
    local identity="$1"
    local unsigned_pkg="$2"
    local output_pkg="$3"
    local max_attempts="${4:-${SIGN_PKG_MAX_ATTEMPTS:-10}}"

    if [ -z "$identity" ] || [ -z "$unsigned_pkg" ] || [ -z "$output_pkg" ]; then
        echo "ERROR: sign_installer_pkg requires identity, unsigned_pkg, and output_pkg" >&2
        return 1
    fi

    if [ ! -f "$unsigned_pkg" ]; then
        echo "ERROR: unsigned package not found: $unsigned_pkg" >&2
        return 1
    fi

    local attempt=1
    rm -f "$output_pkg"

    while [ "$attempt" -le "$max_attempts" ]; do
        echo "Signing installer package (attempt $attempt/$max_attempts)…"

        if productsign --sign "$identity" --timestamp "$unsigned_pkg" "$output_pkg"; then
            if pkgutil --check-signature "$output_pkg" >/dev/null 2>&1; then
                echo "Installer package signed and signature verified."
                return 0
            fi
            echo "productsign exited cleanly but signature verification failed; retrying…"
        else
            echo "productsign failed on attempt $attempt/$max_attempts."
        fi

        rm -f "$output_pkg"

        if [ "$attempt" -lt "$max_attempts" ]; then
            # Exponential backoff: 15s, 30s, 60s, 120s, 240s, then 5m cap.
            local delay=$(( 15 * (2 ** (attempt - 1)) ))
            [ "$delay" -gt 300 ] && delay=300
            echo "Waiting ${delay}s before retry…"
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    echo "ERROR: failed to sign installer package after $max_attempts attempts." >&2
    return 1
}
