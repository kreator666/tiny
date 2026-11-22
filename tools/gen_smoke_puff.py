#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""柔和烟团贴图生成：径向平滑衰减 + 低频噪声扰动边缘，64x64 RGBA 透明底。

背景：硬边圆盘贴图在低分辨率/mipmap 下呈"大像素圆饼"。本贴图以低频平滑为主，
mipmap 逐级缩小仍保持弥散团状；颜色由渲染层 Sprite3D.modulate 按 2D 原公式调制，
故 RGB 输出纯白、只关心 alpha 形状。
用法: python tools/gen_smoke_puff.py
"""
import math
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "packs" / "gongbi" / "facade" / "smoke_puff.png"

SIZE = 64
SS = 4           # 超采样倍数（边缘平滑）
RADIUS = 0.44    # 烟团半径占比（留白边，mipmap 不裁切）
NOISE_AMP = 0.42  # 边缘扰动幅度（低频）


def make_noise(n: int, blur: float) -> Image.Image:
    """低频值噪声：随机网格 -> 双线性放大 -> 高斯模糊，输出 0..255 灰度"""
    import random
    random.seed(20240229)
    g = n // 8
    small = Image.new("L", (g, g))
    px = small.load()
    for y in range(g):
        for x in range(g):
            px[x, y] = random.randint(0, 255)
    big = small.resize((n, n), Image.BICUBIC)
    return big.filter(ImageFilter.GaussianBlur(blur))


def main() -> None:
    n = SIZE * SS
    noise = make_noise(n, n * 0.06)   # 低频扰动
    noise2 = make_noise(n, n * 0.03)  # 更轻的第二层，打散单调
    npx = noise.load()
    n2px = noise2.load()
    img = Image.new("RGBA", (n, n))
    px = img.load()
    c = (n - 1) / 2.0
    r_out = n * RADIUS
    for y in range(n):
        for x in range(n):
            d = math.hypot(x - c, y - c) / r_out
            if d >= 1.35:  # 完全透明区跳过
                continue
            # 径向平滑衰减（cos 曲线，中心平台 + 柔和边缘）
            fall = max(0.0, 0.5 + 0.5 * math.cos(min(d, 1.0) * math.pi))
            fall **= 1.35
            # 噪声扰动半径与密度：只在中外环起作用，保中心完整
            w = min(1.0, max(0.0, (d - 0.25) / 0.75))
            perturb = 1.0 + (npx[x, y] / 255.0 - 0.5) * NOISE_AMP * w \
                + (n2px[x, y] / 255.0 - 0.5) * 0.12 * w
            a = max(0.0, min(1.0, fall * perturb))
            px[x, y] = (255, 255, 255, int(round(a * 255)))
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"OK: {OUT.relative_to(ROOT)} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
