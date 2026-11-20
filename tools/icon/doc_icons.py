#!/usr/bin/env python3
"""Owlink's document icons: one template (a white page with a folded corner,
Cedric the owl as the badge, a coral label with the type's name), one .icns
per file type.

    python3 tools/icon/doc_icons.py            # writes Resources/DocIcons/*.icns
    python3 tools/icon/doc_icons.py --sheet S  # also a contact sheet PNG at S

Needs Pillow and iconutil, like cedric_icon.py (whose owl it draws).

Why .icns files: Finder shows the icon named by CFBundleTypeIconFile in the
default app's CFBundleDocumentTypes entry. The other mechanism, UTTypeIcons
(badge + text composed by the system), only works on a type the app itself
exports and needs an asset catalog (actool, Xcode only); every type here is
declared by the system or by others. See docs/MANUAL.md, "File types and
icons", and the 0.3.0 research notes.

The list of types (label -> file name) must match DocumentTypes.all in
Sources/CedricCore/DocumentTypes.swift; Tests/CedricCoreTests checks that
each type's icon file exists.

Sizes: 16 to 512 px (no 1024: a document icon is never shown at 512 pt on
a Retina screen in Finder, and the 1024 doubles the file). 16 px is the page
and the label band only; 32 px adds the owl; the label text from 32 px up.
"""
import argparse, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(__file__))
import cedric_icon as ci  # noqa: E402

ROOT = ci.ROOT
OUT = os.path.join(ROOT, 'Resources', 'DocIcons')

# (label, icon file name without .icns). "" = the generic text icon (no label).
TYPES = [
    ('TXT', 'doc-txt'), ('MD', 'doc-md'), ('JSON', 'doc-json'), ('YAML', 'doc-yaml'), ('SWIFT', 'doc-swift'),
    ('PY', 'doc-py'), ('JS', 'doc-js'), ('TS', 'doc-ts'), ('SH', 'doc-sh'), ('LOG', 'doc-log'), ('CSV', 'doc-csv'),
    ('XML', 'doc-xml'), ('HTML', 'doc-html'), ('CSS', 'doc-css'), ('TOML', 'doc-toml'), ('INI', 'doc-ini'),
    ('SQL', 'doc-sql'), ('PS1', 'doc-ps1'), ('', 'doc-text'),
]

ICONSET = [  # (iconset file, pixel size); 512@2x left out on purpose (see top)
    ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32), ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256), ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512), ('icon_512x512.png', 512),
]

PAGE = ci.hx('fdfdfd')
EDGE = ci.hx('c9cad6')
FOLD = ci.hx('e4e5ee')
LINE = ci.hx('d9dae6')

# Page geometry in the unit square (Apple's document shape is roughly 0.69 x 0.88).
X0, X1, Y0, Y1 = 0.155, 0.845, 0.06, 0.94
F = 0.19  # folded corner


def label_font(px):
    for f in ('/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/HelveticaNeue.ttc', '/System/Library/Fonts/Helvetica.ttc'):
        if os.path.exists(f):
            try:
                ft = ImageFont.truetype(f, px)
                try:
                    ft.set_variation_by_name('Bold')
                except Exception:
                    pass
                return ft
            except OSError:
                continue
    return ImageFont.load_default()


def page(c):
    n = c.n
    pts = [(X0, Y0), (X1 - F, Y0), (X1, Y0 + F), (X1, Y1), (X0, Y1)]
    # soft shadow, then the edge, then the page
    if c.size >= 64:
        from PIL import ImageFilter
        m = Image.new('L', (n, n), 0)
        ImageDraw.Draw(m).polygon([(x * n, (y + 0.012) * n) for x, y in pts], fill=255)
        c._fill(m.filter(ImageFilter.GaussianBlur(0.01 * n)), (0, 0, 0, 70))
    e = 0.012 if c.size >= 64 else 1.0 / c.size
    c.poly([(X0 - e, Y0 - e), (X1 - F + e * 0.4, Y0 - e), (X1 + e, Y0 + F - e * 0.4), (X1 + e, Y1 + e), (X0 - e, Y1 + e)], EDGE, owl=False)
    c.poly(pts, PAGE, owl=False)
    c.poly([(X1 - F, Y0), (X1 - F, Y0 + F), (X1, Y0 + F)], FOLD, owl=False)
    # a few faint text lines under the owl, from 128 px up
    if c.size >= 128:
        for i, (a, b) in enumerate(((0.25, 0.75), (0.25, 0.68), (0.25, 0.72))):
            y = 0.62 + i * 0.045
            c.rrect(a, y, b, y + 0.016, 0.008, LINE, owl=False)


def band(c, text):
    y0, y1 = 0.755, 0.885
    c.rrect(X0 + 0.045, y0, X1 - 0.045, y1, 0.035, ci.CORAL, owl=False)
    if c.size < 32:
        return
    # the label, as large as fits the band
    d = ImageDraw.Draw(c.im)
    w_max = (X1 - X0 - 0.15) * c.n
    h_max = (y1 - y0) * c.n * 0.72
    px = int(h_max)
    while px > 4:
        ft = label_font(px)
        l, t, r, b = d.textbbox((0, 0), text, font=ft)
        if r - l <= w_max and b - t <= h_max:
            break
        px -= 1
    cx, cy = 0.5 * c.n, (y0 + y1) / 2 * c.n
    d.text((cx - (l + r) / 2, cy - (t + b) / 2), text, font=ft, fill=ci.WHITE)


def doc_icon(text, size):
    # the owl: centred over the lines, its feet at y 0.6 (owl units 0.22..0.85 -> 0.27..0.60 here)
    c = ci.Canvas(size, s=0.52, ox=0.5, oy=0.60)
    page(c)
    if size >= 32:
        ci.owl(c, chevron=size >= 64)
    if text:
        band(c, text)
    return c.image()


def build(sheet=None):
    os.makedirs(OUT, exist_ok=True)
    made = {}
    for text, name in TYPES:
        cache = {}
        with tempfile.TemporaryDirectory() as w:
            iset = os.path.join(w, name + '.iconset')
            os.makedirs(iset)
            for fn, px in ICONSET:
                if px not in cache:
                    cache[px] = doc_icon(text, px)
                cache[px].save(os.path.join(iset, fn))
            subprocess.run(['iconutil', '-c', 'icns', iset, '-o', os.path.join(OUT, name + '.icns')], check=True)
        made[name] = (text, cache)
    # anything left from an older list
    keep = {name + '.icns' for _, name in TYPES}
    for f in os.listdir(OUT):
        if f.endswith('.icns') and f not in keep:
            os.remove(os.path.join(OUT, f))
    if sheet:
        write_sheet(sheet, made)
    return made


def write_sheet(path, made):
    sizes = [256, 128, 64, 32, 16]
    pad = 16
    row_w = sum(sizes) + pad * (len(sizes) + 1)
    rows = len(made)
    sh = Image.new('RGBA', (row_w * 2, (256 + pad) * ((rows + 1) // 2) + pad), (236, 236, 240, 255))
    for i, (name, (text, cache)) in enumerate(made.items()):
        x = pad + (i % 2) * row_w
        y = pad + (i // 2) * (256 + pad)
        for s in sizes:
            sh.alpha_composite(cache[s], (x, y + 256 - s))
            x += s + pad
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sh.save(path)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--sheet')
    a = ap.parse_args()
    build(a.sheet)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    print(f'wrote {len(TYPES)} icons to {OUT} ({total // 1024} KB)')
