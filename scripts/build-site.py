#!/usr/bin/env python3
"""Build the dependency-free GitHub Pages site from reviewed repository assets."""
import plistlib
import shutil
import struct
from html import escape
from pathlib import Path

root = Path(__file__).resolve().parent.parent
output = root / '_site'
output.mkdir(exist_ok=True)
assets = output / 'assets'
assets.mkdir(exist_ok=True)
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
image = root / 'docs/images/overview.png'
header = image.read_bytes()[:24]
assert header[:8] == b'\x89PNG\r\n\x1a\n', 'Overview must be a PNG'
width, height = struct.unpack('>II', header[16:24])
html = (root / 'site/index.html').read_text()
for key, value in {'VERSION': info['CFBundleShortVersionString'], 'IMAGE_WIDTH': width, 'IMAGE_HEIGHT': height}.items():
    html = html.replace('{{' + key + '}}', escape(str(value)))
assert '{{' not in html, 'Unresolved site template field'
(output / 'index.html').write_text(html)
for name in ['styles.css', 'script.js']:
    shutil.copyfile(root / 'site' / name, output / name)
shutil.copyfile(image, assets / 'overview.png')
shutil.copyfile(root / 'Resources/Brand/AppIcon-1024.png', assets / 'app-icon.png')
(output / '.nojekyll').write_text('')
(output / 'robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: https://salilchincholikar.github.io/bridge/sitemap.xml\n')
(output / 'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://salilchincholikar.github.io/bridge/</loc></url></urlset>\n')
print(f'Built GitHub Pages site: {output}')
