#!/bin/sh
# Stage the existing offline UI suite as a GUI app so it runs in a real macOS application session.
set -eu
cd "$(dirname "$0")/.."
scripts/bundle.sh release ui-test
OUT="build/Bridge UI Checks.app"
python3 - <<'PY'
import plistlib
from pathlib import Path
p = Path('build/Bridge UI Checks.app/Contents/Info.plist')
info = plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier='dev.bridge.uichecks', CFBundleName='Bridge UI Checks', CFBundleDisplayName='Bridge UI Checks')
info['LSEnvironment'] = {'BRIDGE_UI_SELFTEST': '1', 'BRIDGE_UI_SELFTEST_LOG': '/private/tmp/bridge-native-ui-checks.log', 'BRIDGE_UI_SNAPSHOT_DIR': '/private/tmp/bridge-native-snapshots'}
p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$OUT"
printf 'UI check bundle: %s\n' "$OUT"
printf 'Result log: /private/tmp/bridge-native-ui-checks.log\n'
