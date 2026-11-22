#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""树木 facade 贴图程序生成：工笔风、低饱和，色调取色对齐原 billboard tree.png。

- facade/tree_leaf.png  128x128 RGBA：丛状叶团（多团圆润叶簇 + 细枝点缀），
  中心完整、边缘不规则；alpha 平滑（mipmap 友好，校验思路同 smoke_puff）
- facade/tree_trunk.png 64x64 RGBA：竖纹木色（全不透明），柱面 UV 重复无接缝感

主色来源（PIL 对 tree.png 取色）：叶亮 (128,176,96)、叶中 (112,160,96)、
叶暗 (48,80,64)；干亮 (192,128,96)、干中 (144,80,64)、干暗 (96,48,48)。
用法: python tools/gen_tree_textures.py
"""
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "packs" / "gongbi" / "facade"

LEAF_SIZE = 128
TRUNK_SIZE = 64
SS = 4

# tree.png 取色（工笔低饱和）
LEAF_LIGHT = (128, 176, 96)
LEAF_MID = (104, 152, 88)
LEAF_DARK = (48, 80, 64)
LEAF_DEEP = (34, 60, 46)
BRANCH = (96, 60, 44)
TRUNK_LIGHT = (192, 128, 96)
TRUNK_MID = (144, 80, 64)
TRUNK_DARK = (96, 48, 48)


def _bump(d: float, strength: float) -> float:
    """簇内平滑 bump：中心平台 + cos 柔和边"""
    if d >= 1.0:
        return 0.0
    return strength * (0.5 + 0.5 * math.cos(d * math.pi)) ** 1.2


def make_leaf() -> Image.Image:
    n = LEAF_SIZE * SS
    rng = random.Random(20240308)

    # 细枝点缀：自底部中心向外上发散的短弧枝（画在叶层之下，叶簇间隙可见）
    branches = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    bd = ImageDraw.Draw(branches)
    base = (n * 0.5, n * 0.95)
    for i in range(7):
        a = -math.pi / 2 + (i - 3) * 0.30 + rng.uniform(-0.08, 0.08)
        ln = n * rng.uniform(0.28, 0.46)
        tip = (base[0] + math.cos(a) * ln, base[1] + math.sin(a) * ln)
        mid = (base[0] + math.cos(a) * ln * 0.55 + rng.uniform(-n * 0.03, n * 0.03),
               base[1] + math.sin(a) * ln * 0.55)
        bd.line([base, mid, tip], fill=BRANCH + (230,), width=max(3, n // 120))

    # 叶簇：圆冠椭圆内布团，中心实、外圈碎（不规则边缘）、顶部提亮
    clusters = []  # (x, y, r, strength, hue_bias)
    cx, cy = n * 0.5, n * 0.46
    rx, ry = n * 0.40, n * 0.40
    for _ in range(14):  # 内圈实团
        a = rng.uniform(0, math.tau)
        rr = math.sqrt(rng.uniform(0, 1)) * 0.60
        clusters.append((cx + math.cos(a) * rx * rr, cy + math.sin(a) * ry * rr,
                         n * rng.uniform(0.13, 0.19), rng.uniform(0.85, 1.0), rng.uniform(-0.2, 0.2)))
    for _ in range(10):  # 外圈碎团
        a = rng.uniform(0, math.tau)
        rr = rng.uniform(0.66, 1.0)
        clusters.append((cx + math.cos(a) * rx * rr, cy + math.sin(a) * ry * rr,
                         n * rng.uniform(0.07, 0.12), rng.uniform(0.55, 0.9), rng.uniform(-0.3, 0.1)))
    for _ in range(4):  # 顶部亮团
        clusters.append((cx + rng.uniform(-n * 0.12, n * 0.12),
                         cy - ry * rng.uniform(0.55, 0.85),
                         n * rng.uniform(0.09, 0.13), 1.0, 0.35))

    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    bpx = branches.load()
    for y in range(n):
        for x in range(n):
            a_best = 0.0
            w_best = 0.0
            for (qx, qy, qr, qs, qh) in clusters:
                d = math.hypot(x - qx, y - qy) / qr
                b = _bump(d, qs)
                if b > a_best:
                    a_best = b
                    w_best = qh
            if a_best <= 0.02:
                continue
            # 颜色：纵向明暗（下深上浅）+ 簇间冷暖微差；噪声抖动防平涂
            v = (cy - y) / (2 * ry) + 0.5 + w_best * 0.5
            v = max(0.0, min(1.0, v + rng.uniform(-0.06, 0.06)))
            if v < 0.35:
                c0, c1, t0, t1 = LEAF_DEEP, LEAF_DARK, 0.0, 0.35
            elif v < 0.7:
                c0, c1, t0, t1 = LEAF_DARK, LEAF_MID, 0.35, 0.7
            else:
                c0, c1, t0, t1 = LEAF_MID, LEAF_LIGHT, 0.7, 1.0
            f = (v - t0) / (t1 - t0)
            col = tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(3))
            a = int(round(min(1.0, a_best) * 255))
            # 细枝仅在叶内混色（不增 alpha，避免边缘跳变）
            br = bpx[x, y]
            if br[3] > 0 and a > 0:
                mix = br[3] / 255.0 * (1.0 - a / 255.0) * 0.8
                col = tuple(int(col[k] * (1 - mix) + br[k] * mix) for k in range(3))
            px[x, y] = col + (a,)
    return img.resize((LEAF_SIZE, LEAF_SIZE), Image.LANCZOS)


def make_trunk() -> Image.Image:
    n = TRUNK_SIZE * SS
    rng = random.Random(20240309)
    img = Image.new("RGBA", (n, n))
    px = img.load()
    # 竖纹：多条正弦摆动条纹，明度沿 x 正弦渐变（柱面 UV 重复无缝）
    streaks = []
    for i in range(9):
        streaks.append((rng.uniform(0, n), rng.uniform(-0.5, 0.5),
                        rng.uniform(0.4, 1.0), rng.uniform(4, 10)))
    for y in range(n):
        for x in range(n):
            v = 0.5
            for (sx, sway, amp, wdt) in streaks:
                d = abs(x - (sx + sway * math.sin(y / n * math.tau * 1.5)))
                v += amp * 0.55 * math.exp(-(d / wdt) ** 2)
            v += rng.uniform(-0.06, 0.06)
            v = max(0.0, min(1.0, v))
            if v < 0.5:
                c0, c1, t0, t1 = TRUNK_DARK, TRUNK_MID, 0.0, 0.5
            else:
                c0, c1, t0, t1 = TRUNK_MID, TRUNK_LIGHT, 0.5, 1.0
            f = (v - t0) / (t1 - t0)
            px[x, y] = tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(3)) + (255,)
    img = img.resize((TRUNK_SIZE, TRUNK_SIZE), Image.LANCZOS)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    return img


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    leaf = make_leaf()
    leaf.save(OUT_DIR / "tree_leaf.png")
    trunk = make_trunk()
    trunk.save(OUT_DIR / "tree_trunk.png")
    print(f"OK: tree_leaf.png ({LEAF_SIZE}x{LEAF_SIZE}) + tree_trunk.png ({TRUNK_SIZE}x{TRUNK_SIZE})")


if __name__ == "__main__":
    main()
