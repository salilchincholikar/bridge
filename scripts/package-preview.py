#!/usr/bin/env python3
"""Package a verified, ad-hoc-signed Apple Silicon preview without local data."""
import hashlib
import json
import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent

def run(*args):
    return subprocess.check_output(args, cwd=root, text=True).strip()

app = root / 'build/Bridge.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
commit = run('git', 'rev-parse', 'HEAD')
assert not run('git', 'status', '--porcelain'), 'Package only a clean committed checkout'
assert run('lipo', '-archs', str(app / 'Contents/MacOS/Bridge')) == 'arm64', 'Expected Apple Silicon build'
assert 'Signature=adhoc' in subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True, check=True).stderr
subprocess.run(['sh', 'scripts/verify-bundle.sh', str(app)], cwd=root, check=True)
out = root / 'build/release'
out.mkdir(parents=True, exist_ok=True)
archive = out / f'Bridge-{version}-macOS-arm64-preview.zip'
with tempfile.TemporaryDirectory(prefix='bridge-release-') as tmp:
    stage = Path(tmp) / 'stage'
    stage.mkdir()
    subprocess.run(['ditto', str(app), str(stage / 'Bridge.app')], check=True)
    for name in ('LICENSE', 'NOTICE'):
        (stage / name).write_bytes((root / name).read_bytes())
    (stage / 'README.txt').write_text(f'''Bridge {version} — Apple Silicon preview

Requires macOS 14 or later and AWS CLI v2 for real accounts.
Move Bridge.app to Applications, then configure an AWS CLI named profile.

This app is ad-hoc signed, NOT Developer ID signed and NOT notarized.
macOS may block a quarantined download. This preview is for developers
comfortable evaluating a pre-release app; building from source is an alternative.
No signing identity or Apple trust approval is implied.

Source and setup: https://github.com/salilchincholikar/bridge
Commit: {commit}
Security model: https://github.com/salilchincholikar/bridge/blob/main/docs/security-model.md
License: Apache-2.0 (included)
''')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', str(stage), str(archive)], check=True)
    extracted = Path(tmp) / 'extracted'
    subprocess.run(['ditto', '-x', '-k', str(archive), str(extracted)], check=True)
    subprocess.run(['sh', 'scripts/verify-bundle.sh', str(extracted / 'Bridge.app')], cwd=root, check=True)
    manifest = sorted(str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_file())
metadata = {
    'version': version, 'build': info['CFBundleVersion'], 'commit': commit,
    'architecture': 'arm64', 'minimum_macos': info['LSMinimumSystemVersion'],
    'signing': 'ad-hoc', 'notarized': False,
    'swift': run('swift', '--version'), 'files': manifest,
}
(out / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
files = [archive, out / 'manifest.json']
(out / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print(f'Preview package verified: {archive}')
