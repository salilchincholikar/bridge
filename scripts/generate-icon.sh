#!/bin/sh
# Render the original vector icon, then package PNG representations as an ICNS container.
set -eu
cd "$(dirname "$0")/.."
swift -module-cache-path "${TMPDIR:-/private/tmp}/bridge-icon-module-cache" scripts/generate-icon.swift
python3 - <<'PY'
import struct
from pathlib import Path
sizes = [('icp4', '16x16'), ('icp5', '32x32'), ('icp6', '32x32@2x'), ('ic07', '128x128'), ('ic08', '256x256'), ('ic09', '512x512'), ('ic10', '512x512@2x'), ('ic11', '16x16@2x'), ('ic12', '32x32@2x'), ('ic13', '128x128@2x'), ('ic14', '256x256@2x')]
chunks = []
for kind, size in sizes:
    png = Path(f'build/AppIcon.iconset/icon_{size}.png').read_bytes()
    chunks.append(kind.encode() + struct.pack('>I', len(png) + 8) + png)
body = b''.join(chunks)
Path('Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
PY
