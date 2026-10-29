#!/bin/sh
# Local production-bundle checks. This does not certify Developer ID signing or notarization.
set -eu
cd "$(dirname "$0")/.."
APP="${1:-build/Bridge.app}"
BIN="$APP/Contents/MacOS/Bridge"
test -x "$BIN"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"
test ! -e "$APP/Contents/Resources/Fixtures"
if /usr/libexec/PlistBuddy -c 'Print :BridgeDemo' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo 'Refusing demo metadata in a production bundle.' >&2
    exit 1
fi
SYMBOLS="$(/usr/bin/strings "$BIN")"
if printf '%s\n' "$SYMBOLS" | /usr/bin/grep -q 'BRIDGE_UI_SELFTEST'; then
    echo 'UI test entry point found in production binary.' >&2
    exit 1
fi
test -f "$APP/Contents/Resources/AppIcon.icns"
test -f "$APP/Contents/Resources/Bridge Help.html"
cmp LICENSE "$APP/Contents/Resources/LICENSE"
cmp NOTICE "$APP/Contents/Resources/NOTICE"
shasum -a 256 "$BIN"
echo 'Production bundle checks passed (local ad-hoc build; not a distribution approval).'
