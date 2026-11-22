#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""磨坊水车正交圆盘贴图生成：径向轮辐 + 轮缘 + 水斗（斗式水车），工笔木色，透明底。

2D 版的 mill_wheel_dN.png 是从 3/4 透视画上抠的切片，直接当 3D 圆盘自转必然不对。
本工具程序绘制一张正交（正视）水车轮，供 3D 模式做竖直圆盘绕水平轮轴旋转；
立牌模式（use_meshes=false）仍用旧的切片贴图，不受影响。
用法: python tools/gen_mill_wheel_disc.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "packs" / "gongbi" / "facade" / "mill_wheel_disc.png"

SIZE = 128        # 输出边长
SS = 4            # 超采样倍数（抗锯齿）
WOOD_DARK = (86, 58, 36, 255)    # 轮缘/轮毂 深木
WOOD_MID = (122, 88, 54, 255)    # 轮辐 中木
WOOD_LITE = (150, 114, 72, 255)  # 水斗内侧/高光
OUTLINE = (58, 38, 24, 255)      # 工笔勾线
SPOKES = 8
BUCKETS = 12


def draw_disc(img: Image.Image) -> None:
    d = ImageDraw.Draw(img)
    w = img.size[0]
    c = w / 2.0
    r_out = w * 0.46   # 轮缘外半径
    r_rim = w * 0.40   # 轮缘内半径（轮辐终点）
    r_hub = w * 0.075  # 轮毂半径

    # 水斗：轮缘外周的梯形斗（斗式水车特征），先画斗再画轮缘压边
    for i in range(BUCKETS):
        a = math.tau * i / BUCKETS
        # 斗：沿径向略外挑的矩形（切向宽、径向高）
        t_half = math.tau / BUCKETS * 0.36
        p = []
        for rr, aa in ((r_rim * 0.98, a - t_half), (r_rim * 0.98, a + t_half),
                       (r_out * 1.06, a + t_half), (r_out * 1.06, a - t_half)):
            p.append((c + rr * math.cos(aa), c + rr * math.sin(aa)))
        d.polygon(p, fill=WOOD_MID, outline=OUTLINE)

    # 轮辐
    for i in range(SPOKES):
        a = math.tau * i / SPOKES
        x0, y0 = c + r_hub * 0.8 * math.cos(a), c + r_hub * 0.8 * math.sin(a)
        x1, y1 = c + r_rim * math.cos(a), c + r_rim * math.sin(a)
        d.line([(x0, y0), (x1, y1)], fill=WOOD_MID, width=int(w * 0.035))

    # 轮缘（双圈压边，工笔描线感）
    d.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], fill=WOOD_DARK)
    d.ellipse([c - r_rim, c - r_rim, c + r_rim, c + r_rim], fill=(0, 0, 0, 0))
    d.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], outline=OUTLINE, width=max(2, w // 64))
    d.ellipse([c - r_rim, c - r_rim, c + r_rim, c + r_rim], outline=OUTLINE, width=max(2, w // 96))

    # 轮毂 + 轴套
    d.ellipse([c - r_hub, c - r_hub, c + r_hub, c + r_hub], fill=WOOD_DARK, outline=OUTLINE,
              width=max(2, w // 64))
    r_axle = w * 0.028
    d.ellipse([c - r_axle, c - r_axle, c + r_axle, c + r_axle], fill=OUTLINE)

    # 轮缘内侧细高光弧（工笔留白感）
    d.arc([c - r_out * 0.94, c - r_out * 0.94, c + r_out * 0.94, c + r_out * 0.94],
          start=200, end=320, fill=WOOD_LITE, width=max(2, w // 128))


def main() -> None:
    big = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    draw_disc(big)
    img = big.resize((SIZE, SIZE), Image.LANCZOS)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"OK: {OUT.relative_to(ROOT)} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
