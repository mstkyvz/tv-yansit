#!/usr/bin/env python3
"""Uygulama simgesini (Resources/AppIcon.icns) uretir. Gerekli: Pillow, macOS iconutil."""
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

S = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS simge izgarasi: 824px yuvarlatilmis kare, golgeli
    margin, radius = 100, 185
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (margin, margin + 14, S - margin, S - margin + 14), radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    bg = Image.new("RGBA", (S, S))
    top, bottom = (78, 70, 229), (20, 184, 166)
    px = bg.load()
    for y in range(S):
        for x in range(S):
            t = (x * 0.35 + y * 0.65) / S
            px[x, y] = lerp(top, bottom, t) + (255,)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((margin, margin, S - margin, S - margin), radius, fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # TV govdesi
    tv = (235, 330, 789, 680)
    d.rounded_rectangle(tv, 46, fill=(255, 255, 255, 255))
    d.rounded_rectangle((tv[0] + 30, tv[1] + 30, tv[2] - 30, tv[3] - 30), 22, fill=(17, 24, 39, 255))
    # Ayak
    d.rounded_rectangle((462, 680, 562, 728), 12, fill=(255, 255, 255, 255))
    d.rounded_rectangle((382, 722, 642, 758), 18, fill=(255, 255, 255, 255))
    # Ekrandaki oynat isareti
    cx, cy = 512, 505
    d.polygon([(cx - 52, cy - 70), (cx - 52, cy + 70), (cx + 72, cy)], fill=(94, 234, 212, 255))
    # Yayin dalgalari
    for i, r in enumerate((70, 120, 170)):
        box = (cx - r, 300 - r, cx + r, 300 + r)
        d.arc(box, 225, 315, fill=(255, 255, 255, 235 - i * 55), width=26)
    return img


def main():
    icon = draw()
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    out = os.path.join(ROOT, "Resources", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "docs", "icon.png"))
    shutil.rmtree(tmp)
    print("Olusturuldu:", out)


if __name__ == "__main__":
    main()
