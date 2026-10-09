"""Renders the $GAPG token logo (PNG 1024/512/256 + SVG) from the Gapguard shield mark.

Run: python brand/make_logo.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).parent
S = 4096  # supersampled canvas, downscaled at the end for smooth edges
BG = (11, 15, 14)
BG2 = (20, 30, 26)
ACCENT = (61, 220, 151)
ACCENT_DARK = (31, 150, 100)
INK = (6, 18, 12)


def cubic(p0, p1, p2, p3, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t**2
        d = t**3
        pts.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return pts


def shield_points():
    # "M16 2 4 7v8c0 7.5 5.1 13.6 12 15 6.9-1.4 12-7.5 12-15V7L16 2z" in a 32-unit box
    pts = [(16, 2), (4, 7), (4, 15)]
    pts += cubic((4, 15), (4, 22.5), (9.1, 28.6), (16, 30))[1:]
    pts += cubic((16, 30), (22.9, 28.6), (28, 22.5), (28, 15))[1:]
    pts += [(28, 7)]
    return pts


ARROW = [(10, 17), (15, 17), (15, 11), (17, 11), (17, 17), (22, 17), (16, 23)]


def to_canvas(pts, scale, ox, oy):
    return [(ox + x * scale, oy + y * scale) for x, y in pts]


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # radial background disc
    disc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(disc)
    steps = 120
    for i in range(steps):
        r = S / 2 * (1 - i / steps)
        t = i / steps
        col = tuple(int(BG[k] + (BG2[k] - BG[k]) * t) for k in range(3)) + (255,)
        dd.ellipse((S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r), fill=col)
    img.alpha_composite(disc)

    d = ImageDraw.Draw(img)
    # accent ring
    ring = S * 0.035
    d.ellipse((ring, ring, S - ring, S - ring), outline=ACCENT + (255,), width=int(S * 0.022))

    # soft glow behind the shield
    scale = S * 0.62 / 32
    ox = (S - 32 * scale) / 2
    oy = (S - 32 * scale) / 2 + S * 0.01
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).polygon(to_canvas(shield_points(), scale, ox, oy), fill=ACCENT + (110,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * 0.03)))

    # shield with a subtle two-tone split (the "gap")
    shield = to_canvas(shield_points(), scale, ox, oy)
    d.polygon(shield, fill=ACCENT + (255,))
    left = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(left).polygon(shield, fill=ACCENT_DARK + (90,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rectangle((0, 0, S / 2, S), fill=255)
    left.putalpha(Image.composite(left.getchannel("A"), Image.new("L", (S, S), 0), mask))
    img.alpha_composite(left)

    # down arrow = protection against the drop
    d.polygon(to_canvas(ARROW, scale, ox, oy), fill=INK + (255,))

    for size in (1024, 512, 256):
        img.resize((size, size), Image.LANCZOS).save(OUT / f"gapg-logo-{size}.png")

    # vector version
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="rgb{BG2}"/><stop offset="100%" stop-color="rgb{BG}"/>
    </radialGradient>
    <clipPath id="left"><rect width="256" height="512"/></clipPath>
  </defs>
  <circle cx="256" cy="256" r="256" fill="url(#bg)"/>
  <circle cx="256" cy="256" r="232" fill="none" stroke="rgb{ACCENT}" stroke-width="11"/>
  <g transform="translate(97 102) scale(9.92)">
    <path d="M16 2 4 7v8c0 7.5 5.1 13.6 12 15 6.9-1.4 12-7.5 12-15V7L16 2z" fill="rgb{ACCENT}"/>
    <path d="M16 2 4 7v8c0 7.5 5.1 13.6 12 15 6.9-1.4 12-7.5 12-15V7L16 2z" fill="rgb{ACCENT_DARK}" fill-opacity="0.35" clip-path="url(#left)"/>
    <path d="M10 17h5v-6h2v6h5l-6 6z" fill="rgb{INK}"/>
  </g>
</svg>
"""
    (OUT / "gapg-logo.svg").write_text(svg)
    print("wrote", [p.name for p in sorted(OUT.glob("gapg-logo*"))])


if __name__ == "__main__":
    main()
