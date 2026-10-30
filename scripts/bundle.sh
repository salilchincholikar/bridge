#!/bin/sh
# Assemble build/Bridge.app from the SwiftPM executable. No Xcode required.
#   scripts/bundle.sh [debug|release]   (default: release)
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
MODE="${2:-app}"
case "$CONFIG" in debug|release) ;; *) echo "Unknown build configuration: $CONFIG" >&2; exit 2;; esac
case "$MODE" in app|demo|ui-test) ;; *) echo "Unknown bundle mode: $MODE" >&2; exit 2;; esac
OUT="build/Bridge.app"
[ "$MODE" = "demo" ] && OUT="build/Bridge Demo.app"
[ "$MODE" = "ui-test" ] && OUT="build/Bridge UI Checks.app"
TEST_FLAGS=""
[ "$MODE" = "ui-test" ] && TEST_FLAGS="-Xswiftc -DBRIDGE_UI_TESTS"

echo "▸ swift build ($CONFIG)"
swift build ${BRIDGE_SWIFT_FLAGS:-} $TEST_FLAGS -c "$CONFIG" --product BridgeApp --quiet
BIN=".build/$CONFIG/BridgeApp"

echo "▸ bundle"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Bridge"
[ "$CONFIG" = "release" ] && strip -x "$OUT/Contents/MacOS/Bridge" 2>/dev/null || true
cp Resources/Credits.rtf Resources/"Bridge Help.html" "$OUT/Contents/Resources/"
cp LICENSE NOTICE "$OUT/Contents/Resources/"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
if [ "$MODE" != "app" ]; then
    cp -R Fixtures "$OUT/Contents/Resources/Fixtures"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.bridge.demo" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Bridge Demo" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Bridge Demo" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :BridgeDemo bool true" "$OUT/Contents/Info.plist"
fi
codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"
du -sh "$OUT"
