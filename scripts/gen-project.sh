#!/bin/bash
# Generate the Xcode project and fix up vendored package references.
#
# xcodegen generates BOTH SPM package references AND folder references for
# vendored packages. The folder references confuse Xcode into opening the
# vendored packages as projects instead of SPM packages, causing
# "Missing package product" errors.
#
# This script runs xcodegen, then removes the folder references.
# Always use this instead of running `xcodegen generate` directly.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate
python3 scripts/post-xcodegen-fixup.py
