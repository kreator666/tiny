#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""矿脉贴图程序生成：低模岩簇用的石纹贴图 + 立牌回退用的矿脉剪影贴图。

- facade/ore_iron.png  64x64 RGBA 铁矿石纹：青灰岩底 + 深色铁纹斑块
- facade/ore_gold.png  64x64 RGBA 金矿石纹：土黄岩底 + 亮金砂点
- facade/ore_iron_sprite.png / ore_gold_sprite.png 64x64 RGBA 立牌：不规则岩簇剪影
  （多面石块堆叠 + 描边，风格对齐 gongbi 低饱和）
用法: python tools/gen_ore_textures.py
"""
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "packs" / "gongbi" / "facade"
SS = 4

IRON_BASE = (108, 116, 122)   # 青灰
IRON_DARK = (70, 78, 88)
IRON_PATCH = (52, 60, 74)     # 铁纹（青黑）
GOLD_BASE = (150, 124, 88)    # 土黄
GOLD_DARK = (110, 88, 60)
GOLD_FLECK = (212, 178, 96)   # 金砂亮黄
OUTLINE = (50, 44, 38, 255)


def _noise_streaks(n: int, rng: random.Random, col_a, col_b, streaks: int, wob: float) -> Image.Image:
    img = Image.new("RGBA", (n, n))
    px = img.load()
    for y in range(n):
        for x in range(n):
            v = 0.5 + 0.28 * math.sin(x / n * math.tau * streaks + wob * math.sin(y / 17.0))
            v += rng.uniform(-0.10, 0.10)
            v = max(0.0, min(1.0, v))
            px[x, y] = tuple(int(col_a[k] + (col_b[k] - col_a[k]) * v) for k in range(3)) + (255,)
    return img


def make_rock_texture(path: Path, base, dark, accent, accent_prob: float,
                      accent_col, rng: random.Random) -> None:
    n = 64 * SS
    img = _noise_streaks(n, rng, dark, base, 5, rng.uniform(0, 6))
    px = img.load()
    # 斑块/砂点
    for _ in range(int(n * n * accent_prob)):
        x = rng.randrange(2, n - 2)
        y = rng.randrange(2, n - 2)
        r = rng.choice([1, 1, 2])
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy <= r * r:
                    px[x + dx, y + dy] = accent_col + (255,)
    img = img.resize((64, 64), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.4))
    img.save(path)


def _rock_poly(d: ImageDraw.ImageDraw, cx, cy, w, h, rng: random.Random, base, lite) -> None:
    """不规则石块：扰动六边形 + 顶面亮边 + 描线"""
    pts = []
    for i in range(6):
        a = math.tau * i / 6 + rng.uniform(-0.2, 0.2)
        rr = rng.uniform(0.75, 1.1)
        pts.append((cx + math.cos(a) * w * rr, cy + math.sin(a) * h * rr))
    d.polygon(pts, fill=base, outline=OUTLINE)
    # 顶面高光折线
    d.line([pts[5], pts[0], pts[1]], fill=lite, width=max(2, int(w * 0.09)))


def make_sprite(path: Path, rocks, rng: random.Random) -> None:
    n = 64 * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for (cx, cy, w, h, base, lite) in rocks:
        _rock_poly(d, cx * n, cy * n, w * n, h * n, rng, base, lite)
    img = img.resize((64, 64), Image.LANCZOS)
    img.save(path)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20240520)
    make_rock_texture(OUT / "ore_iron.png", IRON_BASE, IRON_DARK, None, 0.010,
                      IRON_PATCH, rng)
    make_rock_texture(OUT / "ore_gold.png", GOLD_BASE, GOLD_DARK, None, 0.014,
                      GOLD_FLECK, rng)
    # 立牌剪影：铁矿青灰簇 / 金矿土黄簇（底部致密贴地）
    iron_rocks = [
        (0.50, 0.66, 0.16, 0.20, IRON_BASE + (255,), (140, 148, 154, 255)),
        (0.34, 0.74, 0.12, 0.14, IRON_DARK + (255,), (120, 128, 138, 255)),
        (0.66, 0.74, 0.13, 0.15, IRON_DARK + (255,), (120, 128, 138, 255)),
        (0.48, 0.48, 0.11, 0.13, IRON_BASE + (255,), (140, 148, 154, 255)),
        (0.30, 0.56, 0.08, 0.10, IRON_PATCH + (255,), (96, 104, 116, 255)),
    ]
    rng2 = random.Random(7)
    make_sprite(OUT / "ore_iron_sprite.png", iron_rocks, rng2)
    gold_rocks = [
        (0.50, 0.66, 0.16, 0.20, GOLD_BASE + (255,), (178, 150, 110, 255)),
        (0.33, 0.74, 0.12, 0.14, GOLD_DARK + (255,), (150, 122, 86, 255)),
        (0.67, 0.74, 0.13, 0.15, GOLD_DARK + (255,), (150, 122, 86, 255)),
        (0.48, 0.47, 0.11, 0.13, GOLD_BASE + (255,), (178, 150, 110, 255)),
        (0.52, 0.60, 0.05, 0.06, GOLD_FLECK + (255,), (232, 200, 120, 255)),
    ]
    make_sprite(OUT / "ore_gold_sprite.png", gold_rocks, rng2)
    print("OK: ore_iron.png ore_gold.png ore_iron_sprite.png ore_gold_sprite.png")


if __name__ == "__main__":
    main()
