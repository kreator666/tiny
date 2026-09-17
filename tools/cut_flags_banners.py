#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""幌子动画素材准备：市集三角旗抹除 + 酒楼悬挂幌子抠出。

1. 市集 market_d0..d3：抹除贴图里静态的三角旗（只删红色像素，天空/屋顶不动），
   运行时由程序绘制飘动旗帜替代。
2. 酒楼 restaurant_d0..d3：把悬挂幌子（带"酒"字，程序重绘会丢失字形）
   按矩形抠为 rest_banner_dN.png，原位置补绘（天空保持透明/墙面最近邻填充），
   运行时绕顶部挂点摆动。

用法: python tools/cut_flags_banners.py
"""
import numpy as np
from PIL import Image
from pathlib import Path

PACK = Path(__file__).resolve().parent.parent / "assets" / "packs" / "gongbi"

# 市集三角旗抹除矩形（96x96 画布坐标 x0,y0,x1,y1，截图校订；只删红色像素）
FLAG_RECTS = {0: (25, 1, 48, 12), 1: (62, 1, 82, 13), 2: (27, 1, 43, 11), 3: (12, 1, 33, 12)}

# 酒楼幌子矩形（紧贴幌子边，不含横杆/挂臂）
BANNER_RECTS = {0: (5, 21, 20, 58), 1: (54, 37, 70, 64), 2: (5, 21, 21, 59), 3: (33, 38, 46, 65)}


def inpaint(img: np.ndarray, hole: np.ndarray, passes: int = 96) -> None:
    """最近邻补绘（与 cut_mill_wheel.inpaint 相同）：优先上下邻居。"""
    for _ in range(passes):
        filled_any = False
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            src_ok = np.roll(~hole, (-dy, -dx), (0, 1))
            target = hole & src_ok
            if target.any():
                filled_any = True
                img[target] = np.roll(img, (-dy, -dx), (0, 1))[target]
                hole = hole & ~target
        if not filled_any:
            break
    img[hole, 3] = 0


def erase_market_flag(d: int) -> None:
    x0, y0, x1, y1 = FLAG_RECTS[d]
    img = np.array(Image.open(PACK / f"market_d{d}.png").convert("RGBA")).astype(np.float32)
    r, g, b = img[:, :, 0], img[:, :, 1], img[:, :, 2]
    red = (r > 110) & (r > g + 40) & (r > b + 40)
    mask = np.zeros(red.shape, bool)
    mask[y0:y1, x0:x1] = True
    hole = red & mask
    img[:, :, 3] = np.where(hole, 0, img[:, :, 3])
    inpaint(img, hole)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA").save(PACK / f"market_d{d}.png")
    print(f"market_d{d}: erased flag px={int(hole.sum())}")


def cut_restaurant_banner(d: int) -> None:
    x0, y0, x1, y1 = BANNER_RECTS[d]
    src = Image.open(PACK / f"restaurant_d{d}.png").convert("RGBA")
    img = np.array(src).astype(np.float32)
    opaque = img[:, :, 3] > 40
    hole = np.zeros(opaque.shape, bool)
    hole[y0:y1, x0:x1] = True
    hole &= opaque
    banner = np.zeros((y1 - y0, x1 - x0, 4), dtype=np.uint8)
    banner[:, :, :] = np.clip(img[y0:y1, x0:x1], 0, 255).astype(np.uint8)
    Image.fromarray(banner, "RGBA").save(PACK / f"rest_banner_d{d}.png")
    img[:, :, 3] = np.where(hole, 0, img[:, :, 3])
    inpaint(img, hole)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA").save(PACK / f"restaurant_d{d}.png")
    print(f"restaurant_d{d}: banner px={int(hole.sum())}")


def main() -> None:
    for d in range(4):
        erase_market_flag(d)
        cut_restaurant_banner(d)


if __name__ == "__main__":
    main()
