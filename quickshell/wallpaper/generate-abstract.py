#!/usr/bin/env python3
"""Generate abstract wallpapers from any theme in theme-switcher/themes.json.

    ./generate-abstract.py                          # Monokai Pro, all four styles
    ./generate-abstract.py --theme catppuccin/mocha
    ./generate-abstract.py --theme "rose pine" --style mesh --seed 42
    ./generate-abstract.py --list zen               # search available themes

Smooth fields are rendered small and upscaled with bicubic (fast, and gives
perfectly smooth gradients); crisp geometry is drawn at 2x and downsampled for
antialiasing. Grain is layered on at full res so dark 4K gradients don't band.

Roughly a third of the themes have light backgrounds, so the vignette direction
and the accent opacities both key off the base luminance — see Palette.light.
"""
import argparse
import json
import math
import random
import re
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter

THEMES = Path(__file__).resolve().parent.parent / "theme-switcher" / "themes.json"
DEFAULT_OUT = Path("~/Pictures/Wallpapers").expanduser()
DEFAULT_THEME = "Monokai Pro/Pro"

ACCENT_KEYS = ("accentPrimary", "accentCyan", "accentGreen", "accentOrange", "accentRed")


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def luminance(c):
    r, g, b = (v / 255 for v in c)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


class Palette:
    def __init__(self, t):
        self.name, self.family = t["name"], t["family"]
        self.base = rgb(t["bgBase"])
        self.surface = rgb(t["bgSurface"])
        self.hover = rgb(t["bgHover"])
        self.selected = rgb(t["bgSelected"])
        self.border = rgb(t["bgBorder"])
        self.text = rgb(t["textPrimary"])
        self.accents = [rgb(t[k]) for k in ACCENT_KEYS]
        self.light = luminance(self.base) > 0.5

    def alpha(self, a):
        """Accent opacities are tuned against a dark base; lift them on light ones."""
        return min(255, int(a * (1.7 if self.light else 1.0)))

    @property
    def slug(self):
        parts = self.family if self.name.lower() in self.family.lower() \
            else f"{self.family} {self.name}"
        return re.sub(r"[^a-z0-9]+", "-", parts.lower()).strip("-")


def load_themes():
    if not THEMES.exists():
        sys.exit(f"themes.json not found at {THEMES}")
    return json.loads(THEMES.read_text())


def find_theme(themes, query):
    """Exact 'family/name' wins, then exact name, then family, then substring."""
    q = query.strip().lower()

    def ident(t):
        return f"{t['family']}/{t['name']}".lower()

    for pred in (lambda t: ident(t) == q,
                 lambda t: t["name"].lower() == q,
                 lambda t: t["family"].lower() == q,
                 lambda t: q in ident(t).replace("/", " ")):
        hits = [t for t in themes if pred(t)]
        if len(hits) == 1:
            return hits[0]
        if len(hits) > 1:
            listing = "\n  ".join(f"{t['family']}/{t['name']}" for t in hits[:25])
            more = f"\n  ... and {len(hits) - 25} more" if len(hits) > 25 else ""
            sys.exit(f"'{query}' matches {len(hits)} themes:\n  {listing}{more}")
    sys.exit(f"no theme matching '{query}' — try --list")


def grain(img, strength=0.45, sigma=7):
    """Overlay-blend gaussian noise to kill banding."""
    n = Image.effect_noise((img.width, img.height), sigma).convert("RGB")
    return Image.blend(img, ImageChops.overlay(img, n), strength)


def vignette(img, p, amount=0.4, softness=1.25):
    """Darken the edges on dark themes, brighten them on light ones — multiplying
    a near-white base just turns the corners muddy grey."""
    lw, lh = 320, 180
    m = Image.new("L", (lw, lh))
    px = m.load()
    cx, cy = lw / 2, lh / 2
    maxd = math.hypot(cx, cy)
    amt = amount * (0.45 if p.light else 1.0)
    for y in range(lh):
        for x in range(lw):
            d = math.hypot(x - cx, y - cy) / maxd
            px[x, y] = max(0, min(255, int((1.0 - amt * (d ** softness)) * 255)))
    m = m.resize((img.width, img.height), Image.BICUBIC)
    if p.light:
        inv = ImageChops.invert(m)
        return ImageChops.screen(img, Image.merge("RGB", (inv, inv, inv)))
    return ImageChops.multiply(img, Image.merge("RGB", (m, m, m)))


# ---------------------------------------------------------------- style: mesh
def mesh(p, w, h, seed):
    """Soft mesh gradient — inverse-distance blend of accent blobs."""
    rnd = random.Random(seed)
    lw, lh = 384, 216

    pts = []
    # accents pushed toward the edges so the centre stays calm (icons/text sit there)
    for i, c in enumerate(p.accents):
        ang = (i / len(p.accents)) * math.tau + rnd.uniform(-0.35, 0.35)
        r = rnd.uniform(0.42, 0.62)
        pts.append((lw * (0.5 + r * math.cos(ang) * 1.35),
                    lh * (0.5 + r * math.sin(ang)), c, rnd.uniform(0.55, 0.85)))
    # dark anchors keep it grounded
    for c in (p.base, p.hover, p.surface):
        pts.append((rnd.uniform(0, lw), rnd.uniform(0, lh), c, 1.0))

    img = Image.new("RGB", (lw, lh))
    px = img.load()
    diag = math.hypot(lw, lh)
    for y in range(lh):
        for x in range(lw):
            tw, acc = 0.0, [0.0, 0.0, 0.0]
            for (bx, by, bc, inten) in pts:
                d = math.hypot(x - bx, y - by) / diag
                wt = inten / (d ** 3.1 + 0.0016)
                tw += wt
                for k in range(3):
                    acc[k] += bc[k] * wt
            col = tuple(int(acc[k] / tw) for k in range(3))
            # pull back toward the base so accents stay as tints
            px[x, y] = mix(p.base, col, 0.62)

    img = img.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(2))
    # inverse-distance blending averages hues toward mud; put the chroma back
    img = ImageEnhance.Color(img).enhance(1.45)
    return grain(vignette(img, p, 0.42))


# --------------------------------------------------------------- style: waves
def waves(p, w, h, seed):
    """Flowing ribbons of finite thickness — the base stays dominant.

    Each ribbon is bounded top *and* bottom; filling to the canvas edge would
    let the bright accents stack and wash the whole lower half out.
    """
    rnd = random.Random(seed)
    img = Image.new("RGB", (w, h), p.base)
    d = ImageDraw.Draw(img, "RGBA")

    def curve(ybase, amp, freq, phase, amp2, freq2, phase2, step=8):
        return [(x, h * ybase
                 + amp * math.sin(x / w * math.tau * freq + phase)
                 + amp2 * math.sin(x / w * math.tau * freq2 + phase2))
                for x in range(0, w + step, step)]

    ac = p.accents
    ribbons = [
        (p.hover, 200, 0.16, 0.13),        (p.surface, 185, 0.30, 0.10),
        (ac[1], p.alpha(70), 0.40, 0.045), (p.selected, 175, 0.47, 0.11),
        (ac[2], p.alpha(62), 0.57, 0.038), (p.surface, 190, 0.64, 0.09),
        (ac[0], p.alpha(75), 0.72, 0.042), (p.hover, 205, 0.79, 0.12),
        (ac[4], p.alpha(68), 0.87, 0.040), (p.selected, 165, 0.93, 0.10),
    ]

    for col, alpha, ybase, thick in ribbons:
        amp = h * rnd.uniform(0.020, 0.045)
        freq = rnd.uniform(0.9, 1.8)
        phase = rnd.uniform(0, math.tau)
        amp2, freq2 = amp * 0.4, freq * rnd.uniform(2.0, 3.2)
        phase2 = rnd.uniform(0, math.tau)
        top = curve(ybase, amp, freq, phase, amp2, freq2, phase2)
        bot = curve(ybase + thick, amp * 0.85, freq, phase + 0.25,
                    amp2, freq2, phase2 + 0.2)
        d.polygon(top + bot[::-1], fill=col + (alpha,))

    img = img.filter(ImageFilter.GaussianBlur(2.2))
    return grain(vignette(img, p, 0.34))


# ------------------------------------------------------------- style: bauhaus
def bauhaus(p, w, h, seed):
    """Crisp geometry — circles, arcs and rules on a flat base."""
    rnd = random.Random(seed)
    s = 2  # supersample, downsampled at the end for antialiasing
    img = Image.new("RGB", (w * s, h * s), p.base)
    d = ImageDraw.Draw(img, "RGBA")

    # faint background rules
    for i in range(1, 9):
        x = w * s * i / 9
        d.line([(x, 0), (x, h * s)], fill=p.hover + (170,), width=2 * s)

    # concentric arcs
    cx, cy = w * s * 0.5, h * s * 0.52
    for i in range(9):
        r = (0.10 + i * 0.075) * h * s
        a0 = rnd.uniform(0, 360)
        d.arc([cx - r, cy - r, cx + r, cy + r], a0, a0 + rnd.uniform(55, 190),
              fill=p.accents[i % len(p.accents)] + (205,), width=int(5 * s))

    # solid + outlined discs
    for i in range(7):
        r = rnd.uniform(0.045, 0.15) * h * s
        px_, py_ = rnd.uniform(r, w * s - r), rnd.uniform(r, h * s - r)
        col = p.accents[i % len(p.accents)]
        box = [px_ - r, py_ - r, px_ + r, py_ + r]
        if i % 2:
            d.ellipse(box, fill=col + (p.alpha(52),), outline=col + (190,),
                      width=int(4 * s))
        else:
            d.ellipse(box, fill=col + (p.alpha(30),))

    # one bright accent bar
    by = h * s * rnd.uniform(0.3, 0.7)
    d.rectangle([0, by, w * s, by + 7 * s], fill=p.accents[0] + (190,))

    return grain(vignette(img.resize((w, h), Image.LANCZOS), p, 0.30), 0.4)


# -------------------------------------------------------------- style: aurora
def aurora(p, w, h, seed):
    """Diagonal soft ribbons of light — heavy blur, very subtle."""
    rnd = random.Random(seed)
    lw, lh = 480, 270
    img = Image.new("RGB", (lw, lh), p.base)
    d = ImageDraw.Draw(img, "RGBA")

    for i in range(14):
        x0 = rnd.uniform(-0.3, 1.0) * lw
        bw = rnd.uniform(0.03, 0.11) * lw
        skew = rnd.uniform(0.25, 0.75) * lw
        d.polygon([(x0, 0), (x0 + bw, 0), (x0 + bw + skew, lh), (x0 + skew, lh)],
                  fill=p.accents[i % len(p.accents)] + (p.alpha(rnd.uniform(28, 72)),))

    img = img.filter(ImageFilter.GaussianBlur(9))
    img = img.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(24))
    return grain(vignette(img, p, 0.5), 0.5)


STYLES = {"mesh": mesh, "waves": waves, "bauhaus": bauhaus, "aurora": aurora}
SEEDS = {"mesh": 7, "waves": 3, "bauhaus": 11, "aurora": 5}


def parse_size(s):
    m = re.fullmatch(r"(\d+)\s*[x×]\s*(\d+)", s.strip())
    if not m:
        raise argparse.ArgumentTypeError(f"expected WIDTHxHEIGHT, got '{s}'")
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser(
        description="Generate abstract wallpapers from a theme-switcher theme.")
    ap.add_argument("--theme", default=DEFAULT_THEME,
                    help=f"name, family, or 'family/name' (default: {DEFAULT_THEME})")
    ap.add_argument("--style", choices=sorted(STYLES), action="append",
                    help="style to render, repeatable (default: all)")
    ap.add_argument("--seed", type=int, help="override the per-style seed")
    ap.add_argument("--size", type=parse_size, default=(3840, 2160), metavar="WxH")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--list", nargs="?", const="", metavar="SEARCH",
                    help="list matching themes and exit")
    a = ap.parse_args()

    themes = load_themes()

    if a.list is not None:
        q = a.list.lower()
        hits = [t for t in themes if q in f"{t['family']}/{t['name']}".lower()]
        for t in sorted(hits, key=lambda t: (t["family"], t["name"])):
            tag = "light" if luminance(rgb(t["bgBase"])) > 0.5 else "dark"
            print(f"{t['family']}/{t['name']}  [{tag}]")
        sys.stdout.flush()  # keep the summary below the listing when stderr is a tty
        print(f"\n{len(hits)} of {len(themes)} themes", file=sys.stderr)
        return

    p = Palette(find_theme(themes, a.theme))
    w, h = a.size
    a.out.mkdir(parents=True, exist_ok=True)

    print(f"{p.family}/{p.name} ({'light' if p.light else 'dark'})  {w}x{h}",
          file=sys.stderr)
    for style in (a.style or sorted(STYLES)):
        img = STYLES[style](p, w, h, a.seed if a.seed is not None else SEEDS[style])
        path = a.out / f"{p.slug}-{style}.png"
        img.save(path, "PNG", optimize=True)
        print(f"{path}  {path.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
