#!/usr/bin/env bash
# ==============================================================================
# LumiBase - Automated macOS DMG Packaging Script
# ==============================================================================
# Usage:
#   ./package_dmg.sh
#
# This script will:
# 1. Clean previous build artifacts.
# 2. Build the optimized Release version of LumiBase.app using Xcode.
# 3. Create a clean staging directory with LumiBase.app and /Applications symlink.
# 4. Generate a compressed, read-only DMG installer (LumiBase-Installer.dmg).
# 5. Clean up temporary files and reveal the DMG in Finder.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="LumiBase"
SCHEME="LumiBase"
CONFIGURATION="Release"
BUILD_DIR="${SCRIPT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
APP_BUNDLE_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
OUTPUT_DMG="${SCRIPT_DIR}/${APP_NAME}-Installer.dmg"
STAGING_DIR="${BUILD_DIR}/dmg_staging"

echo "=================================================="
echo "📦 Building and Packaging ${APP_NAME} for macOS"
echo "=================================================="

# 1. Clean previous build & staging directories
echo "🧹 Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR"
rm -f "$OUTPUT_DMG"

# 2. Build the Application using xcodebuild
echo "⚙️ Compiling ${APP_NAME} (${CONFIGURATION})..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build -quiet

if [ ! -d "$APP_BUNDLE_PATH" ]; then
    echo "❌ Error: Application bundle not found at ${APP_BUNDLE_PATH}"
    exit 1
fi

echo "✅ Successfully built ${APP_NAME}.app"

# 3. Setup DMG Staging Directory
echo "📂 Preparing DMG staging directory..."
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE_PATH" "$STAGING_DIR/"
ln -s /Applications "${STAGING_DIR}/Applications"

# 4. Create DMG using hdiutil
echo "🗜️ Creating compressed DMG disk image..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG"

# 5. Cleanup
echo "🧹 Cleaning up temporary files..."
rm -rf "$STAGING_DIR"

echo "=================================================="
echo "🎉 DMG Packaging Complete!"
echo "📁 Output DMG: ${OUTPUT_DMG}"
echo "=================================================="

# Optional: Reveal in Finder
if [ "${1:-}" != "--no-reveal" ]; then
    open -R "$OUTPUT_DMG" || true
fi
