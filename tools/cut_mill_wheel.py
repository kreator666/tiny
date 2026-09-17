#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""磨坊水车抠图：把 AI 贴图里静态的水车轮拆成独立素材，供运行时旋转。

对 mill_d0..d3 四个方向贴图：
1. 按标定的轮心/半径取圆形区域；
2. 圆内像素分类：轮子木色像素 -> mill_wheel_dN.png（转轮层），
   其余不透明像素（石柱/水流等前景）-> mill_front_dN.png（前景层，保持静止）；
3. 原贴图圆内被抠掉的区域向周围扩散补绘（原本透明的天空区域保持透明），
   得到无轮磨坊底图，就地覆盖 mill_dN.png。

输出均为以轮心为中心的正方形贴图，运行时绕中心旋转即可。

用法: python tools/cut_mill_wheel.py
（重复运行会基于已抠过的图继续抠，结果不变：轮子层已透明，可安全重跑）
"""
import numpy as np
from PIL import Image
from pathlib import Path

PACK = Path(__file__).resolve().parent.parent / "assets" / "packs" / "gongbi"

# 逐方向标定：轮心 (cx, cy) 与半径 r（96x96 画布坐标，截图校订）
WHEELS = {0: (75, 57, 15), 1: (70, 55, 16), 2: (72, 52, 15), 3: (25, 55, 16)}

MARGIN = 3  # 裁剪边距


def wheel_mask(px: np.ndarray) -> np.ndarray:
    """轮子像素判定：暖棕色（r 明显大于 b）或极暗（轮子描边，max<85）。
    白墙/灰石/蓝水留在前景层。px: (...,3) float，返回 bool 掩码。"""
    r, g, b = px[..., 0], px[..., 1], px[..., 2]
    warm = r > b + 20
    dark = np.maximum(np.maximum(r, g), b) < 85
    return warm | dark


def circle_interior(circle: np.ndarray) -> np.ndarray:
    """圆掩码的"内部"（不与圆外相邻的部分），用于找边界种子。"""
    inner = circle.copy()
    inner[1:, :] &= circle[:-1, :]
    inner[:-1, :] &= circle[1:, :]
    inner[:, 1:] &= circle[:, :-1]
    inner[:, :-1] &= circle[:, 1:]
    return inner


def inpaint(img: np.ndarray, hole: np.ndarray, passes: int = 96) -> None:
    """最近邻补绘：hole 内像素逐圈取非 hole 邻居的颜色（优先上下邻居，
    保持墙面/水流的纵向结构），就地修改。"""
    for _ in range(passes):
        filled_any = False
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            src_ok = np.roll(~hole, (-dy, -dx), (0, 1))  # p+(dy,dx) 不在洞内
            target = hole & src_ok
            if target.any():
                filled_any = True
                img[target] = np.roll(img, (-dy, -dx), (0, 1))[target]
                hole = hole & ~target
        if not filled_any:
            break
    img[hole, 3] = 0


def cut_one(d: int) -> None:
    cx, cy, r = WHEELS[d]
    rc = r + 1
    src = Image.open(PACK / f"mill_d{d}.png").convert("RGBA")
    img = np.array(src).astype(np.float32)
    h, w = img.shape[:2]

    yy, xx = np.mgrid[0:h, 0:w]
    circle = (xx - cx) ** 2 + (yy - cy) ** 2 <= rc * rc
    opaque = img[:, :, 3] > 40

    in_circle = circle & opaque
    wheel_px = in_circle & wheel_mask(img[:, :, :3])
    front_px = in_circle & ~wheel_px

    # 连通块清理：前景层只保留与圆边界相连的组件（石柱/水流/平台边），
    # 被轮子包围的孤立前景斑点（高光/雪花）还给轮子层，避免旋转时留下静止杂点
    keep = np.zeros_like(front_px)
    seeds = front_px & ~circle_interior(circle)
    stack = [tuple(p) for p in np.argwhere(seeds)]
    for p in stack:
        keep[p] = True
    while stack:
        y, x = stack.pop()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and front_px[ny, nx] and not keep[ny, nx]:
                keep[ny, nx] = True
                stack.append((ny, nx))
    front_px = keep
    wheel_px = in_circle & ~front_px

    side = 2 * (rc + MARGIN)
    x0, y0 = cx - rc - MARGIN, cy - rc - MARGIN

    def crop(mask: np.ndarray) -> Image.Image:
        out = np.zeros((side, side, 4), dtype=np.uint8)
        region = img[y0:y0 + side, x0:x0 + side].copy()
        region[~mask[y0:y0 + side, x0:x0 + side]] = 0
        out[:, :, :] = np.clip(region, 0, 255).astype(np.uint8)
        return Image.fromarray(out, "RGBA")

    crop(wheel_px).save(PACK / f"mill_wheel_d{d}.png")
    crop(front_px).save(PACK / f"mill_front_d{d}.png")

    # 底图：抠掉整个圆形区域（原本透明的部分保持透明），扩散补洞
    hole = in_circle.copy()
    img[:, :, 3] = np.where(hole, 0, img[:, :, 3])
    inpaint(img, hole)
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGBA").save(PACK / f"mill_d{d}.png")
    print(f"mill_d{d}: center=({cx},{cy}) r={rc} wheel_px={int(wheel_px.sum())} front_px={int(front_px.sum())}")


def main() -> None:
    for d in range(4):
        cut_one(d)


if __name__ == "__main__":
    main()
