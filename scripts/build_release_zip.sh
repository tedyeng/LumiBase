#!/bin/bash
# Build a local, ad-hoc signed isolated LumiBase app and zip archive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${LUMIBASE_FAST_OUTPUT:-$ROOT/../LumiBase-builds}"
DERIVED="${LUMIBASE_FAST_DERIVED:-$OUTPUT/fast-library-1.14.15-derived}"
APP="$OUTPUT/LumiBase.app"
ZIP="$OUTPUT/LumiBase-1.14.15.zip"
if [[ -e "$APP" || -e "$ZIP" ]]; then
    printf 'Refusing to overwrite existing LumiBase artifacts. Archive them or set LUMIBASE_FAST_OUTPUT.\n' >&2
    exit 1
fi
mkdir -p "$OUTPUT"
xcodebuild -project "$ROOT/LumiBase.xcodeproj" -scheme LumiBase -configuration Release \
    -derivedDataPath "$DERIVED" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build > "$OUTPUT/fast-library-1.14.15-xcode-release.log" 2>&1
BUILT="$DERIVED/Build/Products/Release/LumiBase.app"
mkdir -p "$BUILT/Contents/Helpers"
xcrun swiftc -O -target arm64-apple-macos14.0 "$ROOT/Tools/LibraryJPEGROIHelper/main.swift" -o "$BUILT/Contents/Helpers/LumiBaseJPEGROIHelper"
/usr/bin/codesign --force --sign - --timestamp=none "$BUILT/Contents/Helpers/LumiBaseJPEGROIHelper"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$ROOT/LumiBase/Resources/LumiBase.entitlements" "$BUILT"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUILT"
/usr/bin/ditto "$BUILT" "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
/usr/bin/zip -q -j "$ZIP" "$ROOT/docs/1.14.15-fast-library-zhTW.md"
/usr/bin/unzip -t "$ZIP" > "$OUTPUT/fast-library-1.14.15-zip-verification.log"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
printf '%s\n%s\n' "$APP" "$ZIP"
