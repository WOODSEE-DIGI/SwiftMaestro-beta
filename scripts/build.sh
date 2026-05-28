#!/bin/bash
# Build script for SwiftMaestro
# Creates release build ready for .dmg packaging

set -e

echo "=========================================="
echo "SwiftMaestro Build Script"
echo "=========================================="
echo ""

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo "❌ xcodegen not found. Installing..."
    brew install xcodegen
fi

# Generate Xcode project
echo "📝 Generating Xcode project..."
xcodegen generate

# Check build configuration
BUILD_TYPE="${1:-Release}"
echo "🔨 Building in $BUILD_TYPE mode..."

# Build the app
xcodebuild -scheme SwiftMaestro \
           -configuration $BUILD_TYPE \
           -destination 'platform=macOS,arch=arm64' \
           clean build \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO

# Find the built app
APP_PATH="build/$BUILD_TYPE/SwiftMaestro.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed. App not found at $APP_PATH"
    exit 1
fi

echo ""
echo "✅ Build successful!"
echo "📦 App location: $APP_PATH"
echo ""
echo "Next step: Run ./scripts/package.sh to create .dmg"
