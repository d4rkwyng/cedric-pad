#!/usr/bin/env python3
"""Cedric's app icon and assistant owl (flat vector style).

    python3 tools/icon/cedric_icon.py            # writes Resources/AppIcon.icns and Resources/Owl/*.png
    python3 tools/icon/cedric_icon.py --sheet S  # also a contact sheet PNG at S
    python3 tools/icon/cedric_icon.py --keep D   # also leave the .iconset in D

Needs Pillow (pip install pillow) and iconutil (Command Line Tools).

The art is drawn from simple shapes (circles, rounded rectangles, triangles)
in a unit square and rendered at 4x the target size, then reduced with
Lanczos, so every size from 64 px up is drawn for its own size, not shrunk
from the 1024. The 16 and 32 px icons are hand-placed pixel masters (SMALL
below): at those sizes a reduction of the vector art blurs the eyes and the
monocle into the body.

Palette: navy owl, white eyes, yellow monocle/beak/feet, coral plate.
"""
import argparse, math, os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))


def hx(s, a=255):
    s = s.lstrip('#')
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), a)


NAVY = hx('27295a')
WING = hx('3b3e7c')     # wings and lids: a lighter navy so they read against the body
CHEV = hx('5d5f83')     # the chest chevron (white at 25% over navy)
WHITE = hx('ffffff')
YEL = hx('ffc533')
YEL_D = hx('e09a12')
CORAL = hx('ff7c5c')
CORAL_TOP = hx('ff8d6b')
CORAL_BOT = hx('f56a4b')
INK = NAVY

SS = 4  # supersampling factor


class Canvas:
    """Unit-square drawing at size*SS px, with an owl transform (s, ox, oy):
    owl point (x, y) lands at (ox + (x - .5) * s, oy + (y - .85) * s)."""

    def __init__(self, size, s=1.0, ox=0.5, oy=0.85):
        self.size = size
        self.n = size * SS
        self.im = Image.new('RGBA', (self.n, self.n), (0, 0, 0, 0))
        self.s, self.ox, self.oy = s, ox, oy

    # coordinates
    def T(self, x, y):
        return ((self.ox + (x - 0.5) * self.s) * self.n, (self.oy + (y - 0.85) * self.s) * self.n)

    def R(self, r):
        return r * self.s * self.n

    def U(self, x, y):  # canvas-unit coordinates, no owl transform
        return (x * self.n, y * self.n)

    # primitives on a mask, then fill
    def _mask(self):
        return Image.new('L', (self.n, self.n), 0)

    def _fill(self, m, col):
        layer = Image.new('RGBA', (self.n, self.n), col)
        a = Image.new('L', (self.n, self.n), 0)
        a.paste(m, (0, 0))
        from PIL import ImageChops
        layer.putalpha(ImageChops.multiply(a, Image.new('L', a.size, col[3])))
        self.im.alpha_composite(layer)

    def circle(self, x, y, r, col, owl=True):
        cx, cy = self.T(x, y) if owl else self.U(x, y)
        rr = self.R(r) if owl else r * self.n
        m = self._mask()
        ImageDraw.Draw(m).ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)
        self._fill(m, col)

    def ring(self, x, y, ro, ri, col, owl=True):
        cx, cy = self.T(x, y) if owl else self.U(x, y)
        a, b = (self.R(ro), self.R(ri)) if owl else (ro * self.n, ri * self.n)
        m = self._mask()
        d = ImageDraw.Draw(m)
        d.ellipse([cx - a, cy - a, cx + a, cy + a], fill=255)
        d.ellipse([cx - b, cy - b, cx + b, cy + b], fill=0)
        self._fill(m, col)

    def poly(self, pts, col, owl=True):
        f = self.T if owl else self.U
        m = self._mask()
        ImageDraw.Draw(m).polygon([f(x, y) for x, y in pts], fill=255)
        self._fill(m, col)

    def rrect(self, x0, y0, x1, y1, r, col, owl=True, outline=None, width=0):
        f = self.T if owl else self.U
        (a, b), (c, d) = f(x0, y0), f(x1, y1)
        rr = self.R(r) if owl else r * self.n
        m = self._mask()
        ImageDraw.Draw(m).rounded_rectangle([a, b, c, d], radius=rr, fill=255)
        if outline:
            ww = self.R(width) if owl else width * self.n
            mo = self._mask()
            ImageDraw.Draw(mo).rounded_rectangle([a - ww, b - ww, c + ww, d + ww], radius=rr + ww, fill=255)
            self._fill(mo, outline)
        self._fill(m, col)

    def arc_line(self, x, y, r, a0, a1, w, col, owl=True):
        pts = [(x + r * math.cos(math.radians(a0 + (a1 - a0) * i / 40)),
                y + r * math.sin(math.radians(a0 + (a1 - a0) * i / 40))) for i in range(41)]
        self.line(pts, w, col, owl)

    def line(self, pts, w, col, owl=True):
        f = self.T if owl else self.U
        pp = [f(x, y) for x, y in pts]
        ww = self.R(w) if owl else w * self.n
        m = self._mask()
        d = ImageDraw.Draw(m)
        d.line(pp, fill=255, width=max(1, int(ww)), joint='curve')
        for px, py in (pp[0], pp[-1]):
            d.ellipse([px - ww / 2, py - ww / 2, px + ww / 2, py + ww / 2], fill=255)
        self._fill(m, col)

    def rot_ellipse(self, x, y, rx, ry, ang, col):
        a = math.radians(ang)
        pts = []
        for i in range(64):
            t = 2 * math.pi * i / 64
            px, py = rx * math.cos(t), ry * math.sin(t)
            pts.append((x + px * math.cos(a) - py * math.sin(a), y + px * math.sin(a) + py * math.cos(a)))
        self.poly(pts, col)

    def image(self):
        return self.im.resize((self.size, self.size), Image.LANCZOS)


# ---------------------------------------------------------------- the owl

EL, ER = (0.405, 0.50), (0.595, 0.50)
EYE_R, PUP_R = 0.112, 0.05
MONO_R = 0.135
TUFT = [(0.27, 0.47), (0.27, 0.22), (0.43, 0.33)]


def mirror(pts):
    return [(1 - x, y) for x, y in pts]


def sparkle(c, x, y, r, col=YEL, owl=True):
    k = 0.28
    c.poly([(x, y - r), (x + r * k, y - r * k), (x + r, y), (x + r * k, y + r * k),
            (x, y + r), (x - r * k, y + r * k), (x - r, y), (x - r * k, y - r * k)], col, owl)


def one_wing(c, side, angle):
    """side -1 = viewer's left, 1 = viewer's right; angle as in wings()."""
    a = side * (angle - 10)
    px, py = 0.5 + side * 0.215, 0.60   # shoulder
    L = 0.17
    cx = px + side * L * math.sin(math.radians(angle)) * 0.9
    cy = py + L * math.cos(math.radians(angle)) * 0.55 - L * math.sin(math.radians(angle)) * 0.45
    c.rot_ellipse(cx, cy, 0.06, 0.15, -a if side > 0 else -a, WING)


def wings(c, angle):
    """angle 0 = folded at the sides, 90 = raised straight out."""
    for side in (-1, 1):
        one_wing(c, side, angle)


def wing_between(c, p0, p1, rx=0.06, col=WING):
    """A wing as an ellipse whose long axis runs from p0 to p1 (owl units)."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    ang = math.degrees(math.atan2(-dx, dy))
    c.rot_ellipse((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2, rx, math.hypot(dx, dy) / 2, ang, col)


def arm(c, side, angle, L=0.30):
    """One wing raised from the shoulder, staying attached: angle 0 = hanging
    down, 90 = straight out, 180 = straight up. Drawn behind the body."""
    sx, sy = 0.5 + side * 0.20, 0.63
    a = math.radians(angle)
    tip = (sx + side * L * math.sin(a), sy + L * math.cos(a))
    root = (sx - side * 0.04 * math.sin(a), sy - 0.04 * math.cos(a))
    wing_between(c, root, tip, rx=0.062)


def quill(c, nib, tip):
    """A feather quill: navy shaft from the nib, yellow vane with a coral edge toward the tip."""
    dx, dy = tip[0] - nib[0], tip[1] - nib[1]
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    nx, ny = -uy, ux
    def at(t, w):
        return (nib[0] + ux * L * t + nx * w, nib[1] + uy * L * t + ny * w)
    VW = 0.032
    vane = []
    for i in range(21):           # pointed leaf from t=0.25 to t=1
        t = 0.25 + 0.75 * i / 20
        w = VW * math.sin(math.pi * i / 20) ** 0.8
        vane.append(at(t, w))
    for i in range(20, -1, -1):
        t = 0.25 + 0.75 * i / 20
        w = VW * math.sin(math.pi * i / 20) ** 0.8
        vane.append(at(t, -w))
    c.poly([at(0.25 + 0.75 * i / 20, VW * math.sin(math.pi * i / 20) ** 0.8 + 0.01 * (i > 0 and i < 20))
            for i in range(21)] + [at(0.25 + 0.75 * i / 20, 0) for i in range(20, -1, -1)], CORAL)
    c.poly(vane, YEL)
    c.line([at(0.0, 0), at(0.3, 0)], 0.016, YEL_D)    # bare shaft and nib, readable on the navy body
    c.line([at(0.27, 0), at(0.97, 0)], 0.011, NAVY)


def owl(c, eyes='open', beak='closed', monocle='on', wing=None, look=(0.0, 0.0), chevron=True):
    if wing is not None:
        wings(c, wing)
    # body: head circle + rounded base + tufts
    c.circle(0.5, 0.55, 0.25, NAVY)
    c.rrect(0.25, 0.55, 0.75, 0.83, 0.12, NAVY)
    c.poly(TUFT, NAVY)
    c.poly(mirror(TUFT), NAVY)
    if chevron:
        c.poly([(0.40, 0.73), (0.5, 0.78), (0.60, 0.73), (0.60, 0.755), (0.5, 0.805), (0.40, 0.755)], CHEV)
    # eyes
    for i, (ex, ey) in enumerate((EL, ER)):
        if eyes == 'closed':
            c.circle(ex, ey, EYE_R, WING)
            c.arc_line(ex, ey - 0.02, 0.06, 20, 160, 0.026, WHITE)
            continue
        c.circle(ex, ey, EYE_R, WHITE)
        c.circle(ex + 0.01 + look[0], ey + 0.006 + look[1], PUP_R, NAVY)
        if eyes in ('half', 'sleepy'):
            # upper lid: covers the top of the eye
            cut = {'half': 0.0, 'sleepy': 0.03}[eyes]
            lid = Image.new('L', (c.n, c.n), 0)
            cx, cy = c.T(ex, ey)
            rr = c.R(EYE_R)
            ImageDraw.Draw(lid).ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)
            ImageDraw.Draw(lid).rectangle([0, c.T(0, ey + cut)[1], c.n, c.n], fill=0)
            c._fill(lid, WING)
            a, b = c.T(ex - EYE_R, ey + cut), c.T(ex + EYE_R, ey + cut)
            c.line([(ex - EYE_R * 0.98, ey + cut), (ex + EYE_R * 0.98, ey + cut)], 0.012, NAVY)
    # monocle
    if monocle == 'on':
        c.ring(ER[0], ER[1], MONO_R, EYE_R, YEL)
        c.rrect(0.70, 0.60, 0.716, 0.76, 0.008, YEL)
    elif monocle == 'slipped':
        c.ring(ER[0] + 0.02, ER[1] + 0.05, MONO_R, EYE_R, YEL)
        c.rrect(0.722, 0.66, 0.738, 0.80, 0.008, YEL)
    # beak
    if beak == 'open':
        c.poly([(0.455, 0.595), (0.545, 0.595), (0.5, 0.645)], YEL)
        c.poly([(0.47, 0.66), (0.53, 0.66), (0.5, 0.70)], YEL_D)
    else:
        c.poly([(0.46, 0.60), (0.54, 0.60), (0.5, 0.68)], YEL)
    for fx in (0.42, 0.58):
        c.rrect(fx - 0.045, 0.81, fx + 0.045, 0.85, 0.02, YEL)


def plate(c):
    side = 824 / 1024
    x0 = (1 - side) / 2
    # soft drop shadow
    sh = Canvas(c.size)
    m = Image.new('L', (c.n, c.n), 0)
    ImageDraw.Draw(m).rounded_rectangle([x0 * c.n, (x0 + 0.01) * c.n, (1 - x0) * c.n, (1 - x0 + 0.01) * c.n],
                                        radius=side * 0.225 * c.n, fill=255)
    from PIL import ImageFilter
    if c.size >= 64:
        m = m.filter(ImageFilter.GaussianBlur(0.012 * c.n))
        c._fill(m, (0, 0, 0, 90))
    g = Image.linear_gradient('L').resize((c.n, c.n))
    grad = Image.composite(Image.new('RGBA', (c.n, c.n), CORAL_BOT), Image.new('RGBA', (c.n, c.n), CORAL_TOP), g)
    pm = Image.new('L', (c.n, c.n), 0)
    ImageDraw.Draw(pm).rounded_rectangle([x0 * c.n, x0 * c.n, (1 - x0) * c.n, (1 - x0) * c.n],
                                         radius=side * 0.225 * c.n, fill=255)
    grad.putalpha(pm)
    c.im.alpha_composite(grad)


def icon(size):
    c = Canvas(size)
    plate(c)
    owl(c)
    return c.image()


# ---------------------------------------------------------------- hand-tuned 16 and 32

# N navy, W white, Y yellow, n chest chevron, . transparent (plate shows)
SMALL = {32: """
................................
................................
................................
................................
................................
................................
......N..................N......
......NN................NN......
......NNN..............NNN......
......NNNN..NNNNNNNN..NNNN......
......NNNNNNNNNNNNNNNNNNNN......
......NNNNNNNNNNNYYYYNNNNN......
......NNNWWWWNNYYWWWWYYNNN......
......NNWWWWWWNYWWWWWWYNNN......
......NWWNNWWWYWWNNWWWWYNN......
......NWNNNNWWYWNNNNWWWYNN......
......NWNNNNWWYWNNNNWWWYNN......
......NWWNNWWWYWWNNWWWWYNN......
......NNWWWWWWNYWWWWWWYNNN......
......NNNWWWWNNYYWWWWYYNNN......
......NNNNNNNYYNNYYYYNNNNN......
......NNNNNNNNYYNNNNNNNYNN......
......NNNNNNNNNNNNNNNNNYNN......
......NNNNNNnnNNNNnnNNNYNN......
......NNNNNNNnnNNnnNNNNYNN......
......NNNNNNNNnnnnNNNNNNNN......
.......NNNNNNNNnnNNNNNNNN.......
........NNYYYYNNNNYYYYNN........
..........YYYY....YYYY..........
................................
................................
................................""",
16: """
................
................
...N........N...
...NN.NNNN.NN...
...NNNNNNYYNN...
...NNWWNYWWYN...
...NWNNWWNNWY...
...NWNNWWNNWY...
...NNWWNNWWYN...
...NNNNYYNNNY...
...NNNNNNNNNY...
...NNNnNNnNNN...
...NNNNnnNNNN...
....NYYNNYYN....
................
................""",
}
SKEY = {'N': NAVY, 'W': WHITE, 'Y': YEL, 'n': CHEV}


def pixel_plate(n):
    side = round(n * 824 / 1024)
    side += side % 2   # keep it centred on whole pixels
    x0 = (n - side) // 2
    x1 = x0 + side - 1
    r = round(side * 0.225)
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    for y in range(x0, x1 + 1):
        t = (y - x0) / max(1, side - 1)
        col = tuple(int(CORAL_TOP[i] + (CORAL_BOT[i] - CORAL_TOP[i]) * t) for i in range(3)) + (255,)
        for x in range(x0, x1 + 1):
            dx = max(x0 + r - x - 0.5, 0, x + 0.5 - (x1 + 1 - r))
            dy = max(x0 + r - y - 0.5, 0, y + 0.5 - (x1 + 1 - r))
            d = math.hypot(dx, dy)
            if d <= r:
                a = 255 if d <= r - 1 else int(255 * (r - d))   # one pixel of edge softening
                im.putpixel((x, y), col[:3] + (a,))
    return im


def small_icon(n):
    rows = SMALL[n].strip('\n').split('\n')
    assert len(rows) == n and all(len(r) == n for r in rows), (n, [len(r) for r in rows])
    im = pixel_plate(n)
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            if ch in SKEY:
                im.putpixel((x, y), SKEY[ch])
    return im


# ---------------------------------------------------------------- assistant poses

# The assistant owl: same shapes, scaled to 0.78 and standing on the bottom
# edge, leaving the top of the frame for bubbles, sparkles and Zs.
AS, AX, AY = 0.9, 0.5, 0.96


def speech_bubble(c):
    c.rrect(0.66, 0.05, 0.96, 0.25, 0.06, WHITE, owl=False, outline=NAVY, width=0.014)
    c.poly([(0.69, 0.24), (0.76, 0.24), (0.66, 0.33)], NAVY, owl=False)
    c.poly([(0.70, 0.235), (0.745, 0.235), (0.68, 0.30)], WHITE, owl=False)
    for i in range(3):
        c.circle(0.73 + i * 0.08, 0.15, 0.022, NAVY, owl=False)


def thought_bubble(c, dots=None):
    for (x, y, r) in ((0.73, 0.15, 0.08), (0.82, 0.12, 0.09), (0.90, 0.17, 0.07), (0.80, 0.21, 0.07)):
        c.circle(x, y, r + 0.014, NAVY, owl=False)
    for (x, y, r) in ((0.73, 0.15, 0.08), (0.82, 0.12, 0.09), (0.90, 0.17, 0.07), (0.80, 0.21, 0.07)):
        c.circle(x, y, r, WHITE, owl=False)
    for (x, y, r) in ((0.66, 0.31, 0.028), (0.62, 0.37, 0.018)):
        c.circle(x, y, r + 0.012, NAVY, owl=False)
        c.circle(x, y, r, WHITE, owl=False)
    if dots is not None:   # a "..." being thought, one dot per frame
        for i in range(dots):
            c.circle(0.745 + i * 0.07, 0.16, 0.021, NAVY, owl=False)
        return
    sparkle(c, 0.815, 0.155, 0.06, YEL, owl=False)
    sparkle(c, 0.73, 0.14, 0.03, YEL_D, owl=False)
    sparkle(c, 0.90, 0.19, 0.025, YEL_D, owl=False)


def zzz(c):
    for (x, y, s) in ((0.70, 0.30, 0.05), (0.79, 0.19, 0.065), (0.89, 0.06, 0.08)):
        c.line([(x, y), (x + s, y), (x, y + s), (x + s, y + s)], 0.016, NAVY, owl=False)


def pose(name, size=256, frame=None):
    hop = 0.0
    c = Canvas(size, AS, AX, AY)
    if name == 'idle':
        owl(c)
    elif name == 'talking':
        owl(c, beak='open')
        speech_bubble(c)
    elif name == 'blink':
        owl(c, eyes='closed')
    elif name == 'polish':
        owl(c, monocle='off', look=(-0.012, 0.0))
        # raised wing across the chest holding the monocle and a cloth
        c.rot_ellipse(0.62, 0.66, 0.065, 0.14, 35, WING)
        c.ring(0.70, 0.56, MONO_R * 0.8, EYE_R * 0.8, YEL)
        c.circle(0.70, 0.56, EYE_R * 0.8, (220, 238, 250, 140))
        c.poly([(0.60, 0.62), (0.72, 0.60), (0.75, 0.68), (0.63, 0.71)], WHITE)
        sparkle(c, 0.80, 0.47, 0.035)
        sparkle(c, 0.76, 0.42, 0.02)
    elif name == 'flap':
        owl(c, wing=130, look=(0.0, -0.01))
        sparkle(c, 0.16, 0.42, 0.04, YEL, owl=False)
        sparkle(c, 0.84, 0.40, 0.045, YEL, owl=False)
        sparkle(c, 0.90, 0.30, 0.025, YEL, owl=False)
    elif name == 'sleepy':
        owl(c, eyes='sleepy', monocle='slipped')
        zzz(c)
    elif name == 'thinking':
        owl(c, look=(-0.02, -0.035))
        c.rot_ellipse(0.40, 0.70, 0.06, 0.12, -40, WING)   # wing to the chin
        thought_bubble(c)
    elif name == 'blink-strip':
        eyes = ['open', 'half', 'closed'][frame]
        owl(c, eyes=eyes)
    elif name == 'flap-strip':
        ang = [5, 65, 130, 65][frame]
        hop = [0.0, -0.02, -0.04, -0.02][frame]
        c.oy = AY + hop
        owl(c, wing=ang)
    elif name == 'look-strip':
        # right, up-right, up, up-left, left, down-left, down, down-right
        a = math.radians(45 * frame)
        owl(c, look=(round(0.028 * math.cos(a), 4), round(-0.028 * math.sin(a), 4)))
    elif name == 'wave-strip':
        arm(c, 1, [100, 140, 100, 140][frame])
        owl(c, beak=['closed', 'open'][frame % 2])
    elif name == 'nod-strip':
        c.oy = AY + [0.015, 0.03, 0.015][frame]
        owl(c, eyes=['open', 'half', 'open'][frame], look=(0.0, 0.02))
    elif name == 'point-strip':
        side, ang, look = [(1, 90, (0.03, 0.0)), (1, 160, (0.0, -0.03)),
                           (-1, 90, (-0.03, 0.0)), (1, 40, (0.0, 0.03))][frame]
        arm(c, side, ang)
        owl(c, look=look)
    elif name == 'think-strip':
        owl(c, look=(-0.02, -0.035))
        c.rot_ellipse(0.40, 0.70, 0.06, 0.12, -40, WING)   # wing to the chin
        thought_bubble(c, dots=frame + 1)
    elif name == 'search-strip':
        look = [(-0.03, 0.0), (0.0, 0.03), (0.03, 0.0)][frame]
        owl(c, monocle='off', look=look)
        mx, my = ER[0] + look[0] * 0.8, ER[1] + 0.02 + look[1] * 0.8
        r = MONO_R * 1.1
        g = (mx + r * 0.6, my + r * 0.85)                      # where the wing grips the rim
        wing_between(c, (0.80, 0.86), g, rx=0.062)
        c.ring(mx, my, r, r - (MONO_R - EYE_R), YEL)
        c.circle(mx, my, r - (MONO_R - EYE_R), (220, 238, 250, 70))
        c.circle(g[0], g[1], 0.042, WING)                      # wing tip over the rim
    elif name == 'write-strip':
        owl(c, look=(0.0, 0.035))
        nib = [(0.47, 0.80), (0.50, 0.785), (0.53, 0.80)][frame]
        tip = (nib[0] + 0.22, nib[1] - 0.23)
        grip = (nib[0] + 0.06, nib[1] - 0.06)
        wing_between(c, (0.79, 0.70), grip, rx=0.058)
        quill(c, nib, tip)
        c.circle(grip[0], grip[1], 0.032, WING)              # wing tip over the shaft
    return c.image()


POSES = ['idle', 'talking', 'blink', 'polish', 'flap', 'sleepy', 'thinking']
STRIPS = [('blink-strip', 3), ('flap-strip', 4), ('look-strip', 8), ('wave-strip', 4), ('nod-strip', 3),
          ('point-strip', 4), ('think-strip', 3), ('search-strip', 3), ('write-strip', 3)]


def strip(name, frames, size):
    out = Image.new('RGBA', (size * frames, size), (0, 0, 0, 0))
    for i in range(frames):
        out.alpha_composite(pose(name, size, i), (i * size, 0))
    return out


# ---------------------------------------------------------------- outputs

ICONSET = [  # (iconset file, pixel size)
    ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32), ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256), ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512), ('icon_512x512.png', 512), ('icon_512x512@2x.png', 1024),
]


def render_icon(px):
    return small_icon(px) if px in SMALL else icon(px)


def build(keep=None):
    res = os.path.join(ROOT, 'Resources')
    owl_dir = os.path.join(res, 'Owl')
    os.makedirs(owl_dir, exist_ok=True)
    cache = {}
    with tempfile.TemporaryDirectory() as w:
        iset = os.path.join(w, 'AppIcon.iconset')
        os.makedirs(iset)
        for fn, px in ICONSET:
            if px not in cache:
                cache[px] = render_icon(px)
            cache[px].save(os.path.join(iset, fn))
        subprocess.run(['iconutil', '-c', 'icns', iset, '-o', os.path.join(res, 'AppIcon.icns')], check=True)
        if keep:
            os.makedirs(keep, exist_ok=True)
            shutil.rmtree(os.path.join(keep, 'AppIcon.iconset'), ignore_errors=True)
            shutil.copytree(iset, os.path.join(keep, 'AppIcon.iconset'))
    for p in POSES:
        pose(p, 256).save(os.path.join(owl_dir, f'owl-{p}.png'))
        pose(p, 512).save(os.path.join(owl_dir, f'owl-{p}@2x.png'))
    for name, n in STRIPS:
        strip(name, n, 256).save(os.path.join(owl_dir, f'owl-{name}.png'))
        strip(name, n, 512).save(os.path.join(owl_dir, f'owl-{name}@2x.png'))
    return cache


def font(sz):
    for f in ('/System/Library/Fonts/SFNSMono.ttf', '/System/Library/Fonts/Menlo.ttc'):
        if os.path.exists(f):
            return ImageFont.truetype(f, sz)
    return ImageFont.load_default()


def sheet(path, cache):
    pad = 32
    sizes = [1024, 512, 256, 128, 64, 32, 16]
    W = 2400
    H = 6000
    sh = Image.new('RGBA', (W, H), (238, 238, 242, 255))
    d = ImageDraw.Draw(sh)
    d.text((pad, pad), 'Cedric: app icon, flat vector (16 and 32 hand-tuned)', fill=(30, 30, 40), font=font(40))
    x, y = pad, pad + 70
    for s in sizes:
        im = cache.get(s) or render_icon(s)
        sh.alpha_composite(im, (x, y + 1024 - s))
        d.text((x, y + 1024 + 8), f'{s}', fill=(60, 60, 70), font=font(24))
        x += s + pad
    # zooms of the hand-tuned sizes
    zx = pad
    zy = y + 1024 + 60
    for s, z in ((32, 8), (16, 16)):
        sh.alpha_composite(cache[s].resize((s * z, s * z), Image.NEAREST), (zx, zy))
        d.text((zx, zy + 256 + 6), f'{s} px x{z}', fill=(60, 60, 70), font=font(24))
        zx += 256 + pad
    # dark-background check
    dk = Image.new('RGBA', (300, 256), (30, 30, 34, 255))
    for i, s in enumerate((64, 32, 16)):
        dk.alpha_composite(cache[s], (20 + i * 100, 128 - s // 2))
    sh.alpha_composite(dk, (zx, zy))
    d.text((zx, zy + 256 + 6), 'on dark', fill=(60, 60, 70), font=font(24))
    # poses
    py = zy + 320
    d.text((pad, py), 'Assistant owl (256 px, transparent)', fill=(30, 30, 40), font=font(36))
    py += 60
    for i, p in enumerate(POSES):
        im = Image.open(os.path.join(ROOT, 'Resources', 'Owl', f'owl-{p}.png'))
        px = pad + i * (256 + 70)
        d.rectangle([px, py, px + 255, py + 255], fill=(252, 252, 254), outline=(215, 215, 222))
        sh.alpha_composite(im, (px, py))
        d.text((px, py + 262), p, fill=(60, 60, 70), font=font(24))
    py += 330
    for name, n in STRIPS:
        name = f'owl-{name}'
        im = Image.open(os.path.join(ROOT, 'Resources', 'Owl', f'{name}.png'))
        d.text((pad, py), f'{name}.png ({n} frames)', fill=(30, 30, 40), font=font(30))
        py += 44
        d.rectangle([pad, py, pad + im.width - 1, py + 255], fill=(252, 252, 254), outline=(215, 215, 222))
        sh.alpha_composite(im, (pad, py))
        py += 290
    sh = sh.crop((0, 0, W, py + pad))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sh.save(path)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--sheet')
    ap.add_argument('--keep')
    a = ap.parse_args()
    cache = build(a.keep)
    for s in (1024, 512, 256, 128, 64, 32, 16):
        cache.setdefault(s, render_icon(s))
    if a.sheet:
        sheet(a.sheet, cache)
    print('wrote', os.path.join(ROOT, 'Resources', 'AppIcon.icns'), 'and Resources/Owl/')
