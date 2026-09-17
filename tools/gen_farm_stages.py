#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""农田生长阶段贴图生成：从成熟田原图派生 幼苗/生长/茂盛/成熟 四阶段。

对五种作物贴图（farm/wheat/cotton/soy/grape，48x48 贴地 tile）：
- s0 幼苗：拔除植株像素（按与垄土中位色的距离判定），最近邻填土，仅留 20% 稀疏小苗；
- s1 生长：隔行保留 50% 植株并略调淡；
- s2 茂盛：原图；
- s3 成熟：植株向成熟色（金/白/紫）调和并膨胀 1px（更密更饱满）。

输出 {crop}_s0..s3.png 到素材包目录。用法: python tools/gen_farm_stages.py
"""
import numpy as np
from PIL import Image
from pathlib import Path

PACK = Path(__file__).resolve().parent.parent / "assets" / "packs" / "gongbi"

CROPS = {
    "farm": {"tint": (210, 175, 70), "thresh": 70},    # 水稻 -> 金黄
    "wheat": {"tint": (220, 170, 50), "thresh": 55},   # 小麦 -> 深金
    "cotton": {"tint": (255, 252, 245), "thresh": 70}, # 棉花 -> 亮白
    "soy": {"tint": (185, 170, 80), "thresh": 70},     # 大豆 -> 黄褐
    "grape": {"tint": (115, 55, 135), "thresh": 70},   # 葡萄 -> 深紫
}


def inpaint(img: np.ndarray, hole: np.ndarray, passes: int = 48) -> None:
    for _ in range(passes):
        filled = False
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            src_ok = np.roll(~hole, (-dy, -dx), (0, 1))
            t = hole & src_ok
            if t.any():
                filled = True
                img[t] = np.roll(img, (-dy, -dx), (0, 1))[t]
                hole = hole & ~t
        if not filled:
            break


def dilate(mask: np.ndarray) -> np.ndarray:
    out = mask.copy()
    out[1:, :] |= mask[:-1, :]
    out[:-1, :] |= mask[1:, :]
    out[:, 1:] |= mask[:, :-1]
    out[:, :-1] |= mask[:, 1:]
    return out


def gen(crop: str, tint: tuple, thresh: float) -> None:
    img = np.array(Image.open(PACK / f"{crop}.png").convert("RGBA")).astype(np.float32)
    h, w = img.shape[:2]
    opaque = img[:, :, 3] > 40
    dirt = np.median(img[opaque][:, :3], axis=0)
    dist = np.abs(img[:, :, :3] - dirt).sum(axis=-1)
    plant = opaque & (dist > thresh)

    yy, xx = np.mgrid[0:h, 0:w]

    def save(stage: int, keep: np.ndarray, blend: float, target: np.ndarray) -> None:
        out = img.copy()
        out[plant] = out[plant] * (1 - blend) + np.concatenate([target, [255]])[:4] * blend
        drop = plant & ~keep
        out[:, :, 3] = np.where(drop, 0, out[:, :, 3])
        inpaint(out, drop)
        Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA").save(PACK / f"{crop}_s{stage}.png")

    # s0 幼苗：仅留 20% 小苗（隔 2 行 2 列），色调保持
    save(0, plant & (xx % 4 < 1) & (yy % 2 < 1), 0.0, dirt)
    # s1 生长：棋盘保留 50%，略调淡向土色
    save(1, plant & ((xx + yy) % 2 == 0), 0.3, dirt)
    # s2 茂盛：原图
    Image.open(PACK / f"{crop}.png").convert("RGBA").save(PACK / f"{crop}_s2.png")
    # s3 成熟：染色 + 膨胀加密
    full = dilate(plant) & opaque
    save(3, full, 0.5, np.array(tint, dtype=np.float32))
    print(f"{crop}: plant_px={int(plant.sum())} dirt={dirt.round(0)}")


def main() -> None:
    for crop, cfg in CROPS.items():
        gen(crop, cfg["tint"], cfg["thresh"])


if __name__ == "__main__":
    main()
