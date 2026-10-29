#!/usr/bin/env python3
"""Dependency-free checks for curated source assets; not a secret/provenance audit."""
import json
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
count = 0
for folder in ("Fixtures", "Resources"):
    for path in (root / folder).rglob("*"):
        if path.suffix == ".json":
            json.loads(path.read_text())
            count += 1
        elif path.suffix == ".plist":
            plistlib.loads(path.read_bytes())
            count += 1
for name in ("fake-aws/aws", "fake-claude/claude", "fake-codex/codex"):
    path = root / "Fixtures" / name
    assert path.stat().st_mode & 0o111, f"Fixture must be executable: {path}"
print(f"Validated {count} JSON/plist assets and fake executable permissions.")
