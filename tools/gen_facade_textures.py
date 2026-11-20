#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""正交立面贴图生成（方案2）：为 3D 盒体建筑生成全不透明、无透视的立面贴图集。

产物 128x128 到 assets/packs/gongbi/facade/（一张贴图完整铺一个立面，UV 0~1，不平铺）：
  roof_tile.png   青灰瓦屋顶（密排瓦垄）      roof_thatch.png 茅草屋顶
  wall_white.png  白墙+深色木构架/窗格（宋风） wall_wood.png   木板墙
  wall_gray.png   灰砖墙                      base_stone.png  青石/砖基座

双路径：优先 aiping.cn AI 文生图（tools/ai_provider.json 配置，prompt 全英文、
强调 orthographic/no perspective/seamless/gongbi）；AI 失败或色彩直方图不合格
（近单色/近白底）回退 PIL 程序化绘制（低饱和色 + 细线勾边近似工笔）。
每张图的生成方式记录到 facade/_manifest.json。

用法: python tools/gen_facade_textures.py            # 全部（AI 优先，失败自动回退）
      python tools/gen_facade_textures.py --procedural  # 强制程序化（调试用）
"""
import base64
import io
import json
import os
import random
import sys
import urllib.request

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "packs", "gongbi", "facade")
SIZE = 128

STYLE = (
    "flat orthographic architectural texture map, perfectly straight-on front view, "
    "absolutely no perspective, no depth, no shadows, full frame edge-to-edge pattern, "
    "seamless tileable, ancient Chinese Song dynasty architecture material, "
    "traditional gongbi ink painting style, muted elegant low-saturation colors, "
    "hand painted fine brush lines, no text, no watermark, no border, no background"
)

PROMPTS = {
    "roof_tile.png": "roof surface covered with dense rows of overlapping blue-grey curved clay roof tiles, rounded tile ridges clearly visible running vertically",
    "roof_thatch.png": "roof surface made of layered golden straw thatch, dense horizontal straw rows with fine fiber strokes",
    "wall_white.png": "whitewashed plaster wall mostly white with dark brown wooden timber frame beams and one small wooden lattice window, Song dynasty style",
    "wall_wood.png": "vertical wooden plank wall, warm brown timber planks with visible wood grain and thin dark seams",
    "wall_gray.png": "grey brick wall, regular horizontal brick courses with thin mortar joints",
    "base_stone.png": "grey stone block foundation wall, irregular stone masonry blocks with mortar joints",
}


# ---------- AI 路径（沿用 tools/gen_ai_assets.py 的网关约定） ----------

def _load_provider() -> dict:
    cfg_path = os.path.join(ROOT, "tools", "ai_provider.json")
    cfg = {"base_url": "https://aiping.cn/api/v1", "key_file": "tools/aiping_api_key.txt",
           "model": "Qwen-Image"}
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    key_path = os.path.join(ROOT, cfg["key_file"])
    if not os.path.exists(key_path):
        raise RuntimeError("缺少 API key: " + key_path)
    cfg["key"] = open(key_path, encoding="utf-8").read().strip()
    return cfg


def gen_ai(name: str) -> Image.Image:
    cfg = _load_provider()
    body = {"model": cfg["model"], "prompt": STYLE + ", " + PROMPTS[name],
            "size": "1024x1024", "n": 1}
    req = urllib.request.Request(cfg["base_url"].rstrip("/") + "/images/generations",
                                 data=json.dumps(body).encode(), headers={
                                     "Authorization": "Bearer " + cfg["key"],
                                     "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    item = data["data"][0]
    if item.get("b64_json"):
        raw = base64.b64decode(item["b64_json"])
    else:
        with urllib.request.urlopen(item["url"], timeout=60) as r:
            raw = r.read()
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def postprocess_ai(img: Image.Image) -> Image.Image:
    """中心裁方 -> 128 -> 转全不透明 RGB。返回前做色彩直方图检查。"""
    w, h = img.size
    s = min(w, h)
    img = img.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
    img = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    a = np.asarray(img, dtype=np.float32)
    if a.std() < 8.0:            # 近单色（AI 偷懒/纯色底）视为失败
        raise RuntimeError("色彩方差过低(std=%.1f)，疑似纯色图" % a.std())
    if a.mean() > 248:           # 近白底视为失败
        raise RuntimeError("均值过亮(mean=%.1f)，疑似白底图" % a.mean())
    return img


# ---------- 程序化路径（PIL 绘制，工笔近似：低饱和 + 细线勾边） ----------

def _np_to_img(arr: np.ndarray) -> Image.Image:
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def _outline(draw: ImageDraw.ImageDraw, pts, color=(60, 52, 46), w=1):
    draw.line(list(pts) + [pts[0]], fill=color, width=w, joint="curve")


def proc_roof_tile() -> Image.Image:
    arr = np.zeros((SIZE, SIZE, 3), np.float32)
    base = np.array((104, 114, 128), np.float32)   # 青灰
    rng = np.random.default_rng(7)
    row_h, per = 14, 16
    for y in range(SIZE):
        band = (y % row_h) / row_h
        shade = 1.0 + 0.10 * np.sin(band * np.pi) - 0.18 * (band ** 3)
        arr[y, :] = base * shade
    img = _np_to_img(arr)
    d = ImageDraw.Draw(img)
    for r in range(SIZE // row_h + 1):
        y = r * row_h
        d.line([(0, y), (SIZE, y)], fill=(56, 62, 74), width=2)          # 垄底勾边
        off = (r % 2) * per // 2
        for x in range(off - per, SIZE + per, per):
            d.arc([x, y - 6, x + per, y + row_h], 0, 180, fill=(72, 80, 94), width=1)
    return img


def proc_roof_thatch() -> Image.Image:
    rng = np.random.default_rng(11)
    arr = np.zeros((SIZE, SIZE, 3), np.float32)
    base = np.array((188, 150, 82), np.float32)    # 麦秆金
    row_h = 10
    noise = rng.normal(0, 14, (SIZE, SIZE, 1))
    for y in range(SIZE):
        band = (y % row_h) / row_h
        shade = 1.0 + 0.12 * np.sin(band * np.pi) - 0.22 * (band ** 3)
        arr[y, :] = base * shade
    arr += noise
    img = _np_to_img(arr)
    d = ImageDraw.Draw(img)
    for r in range(SIZE // row_h + 1):
        y = r * row_h
        d.line([(0, y), (SIZE, y)], fill=(120, 92, 48), width=2)
        for x in range(0, SIZE, 4):                                           # 草丝细线
            d.line([(x, y), (x + rng.integers(-2, 2), y + row_h)], fill=(150, 116, 62), width=1)
    return img


def proc_wall_white() -> Image:
    img = Image.new("RGB", (SIZE, SIZE), (238, 232, 220))                     # 白墙
    d = ImageDraw.Draw(img)
    wood, dark = (96, 74, 58), (58, 46, 38)
    for i in range(6):                                                        # 外圈木构架
        d.rectangle([i, i, SIZE - 1 - i, SIZE - 1 - i], outline=wood if i < 2 else dark)
    d.line([(0, SIZE // 2), (SIZE, SIZE // 2)], fill=wood, width=5)           # 横梁
    d.line([(SIZE // 2, 0), (SIZE // 2, SIZE)], fill=wood, width=5)           # 中柱
    win = [SIZE // 2 + 12, 18, SIZE - 18, SIZE // 2 - 14]                     # 窗格（右上）
    d.rectangle(win, fill=(226, 218, 202), outline=dark, width=3)
    for i in range(1, 3):
        x = win[0] + (win[2] - win[0]) * i // 3
        y = win[1] + (win[3] - win[1]) * i // 3
        d.line([(x, win[1]), (x, win[3])], fill=wood, width=2)
        d.line([(win[0], y), (win[2], y)], fill=wood, width=2)
    return img


def proc_wall_wood() -> Image:
    rng = np.random.default_rng(23)
    img = Image.new("RGB", (SIZE, SIZE), (124, 90, 58))
    d = ImageDraw.Draw(img)
    pw = 16
    for i, x in enumerate(range(0, SIZE, pw)):
        tone = int(rng.integers(-12, 12))
        d.rectangle([x, 0, x + pw - 1, SIZE], fill=(124 + tone, 90 + tone, 58 + tone // 2))
        for _ in range(5):                                                     # 木纹
            gx = x + int(rng.integers(2, pw - 2))
            d.line([(gx, 0), (gx + int(rng.integers(-3, 3)), SIZE)],
                   fill=(96 + tone, 68 + tone, 42), width=1)
        d.line([(x, 0), (x, SIZE)], fill=(70, 50, 34), width=2)               # 板缝勾边
    return img


def _brick(base, mortar, bw, bh, jitter, seed) -> Image:
    rng = np.random.default_rng(seed)
    img = Image.new("RGB", (SIZE, SIZE), mortar)
    d = ImageDraw.Draw(img)
    y = 0
    row = 0
    while y < SIZE:
        x = -(bw // 2) if row % 2 else 0
        while x < SIZE:
            tone = int(rng.integers(-jitter, jitter))
            d.rectangle([x + 1, y + 1, x + bw - 1, y + bh - 1],
                        fill=tuple(int(c + tone) for c in base))
            x += bw
        y += bh
        row += 1
    return img


def proc_wall_gray() -> Image:
    return _brick((112, 112, 108), (86, 86, 82), 32, 14, 10, 31)


def proc_base_stone() -> Image:
    img = _brick((136, 136, 130), (98, 98, 94), 26, 18, 14, 47)
    rng = np.random.default_rng(47)
    d = ImageDraw.Draw(img)
    for _ in range(400):                                                      # 石面斑驳
        x, y = int(rng.integers(0, SIZE)), int(rng.integers(0, SIZE))
        tone = int(rng.integers(-20, 20))
        d.point([(x, y)], fill=(136 + tone, 136 + tone, 130 + tone))
    return img


PROCEDURAL = {
    "roof_tile.png": proc_roof_tile,
    "roof_thatch.png": proc_roof_thatch,
    "wall_white.png": proc_wall_white,
    "wall_wood.png": proc_wall_wood,
    "wall_gray.png": proc_wall_gray,
    "base_stone.png": proc_base_stone,
}


def check_opaque(img: Image.Image) -> None:
    if img.mode != "RGB":
        raise RuntimeError("非全不透明: mode=%s" % img.mode)
    a = np.asarray(img, dtype=np.float32)
    if a.std() < 6.0:
        raise RuntimeError("色彩方差过低(std=%.1f)" % a.std())


def main() -> None:
    force_proc = "--procedural" in sys.argv
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {}
    for name in PROMPTS:
        out = os.path.join(OUT_DIR, name)
        method = None
        if not force_proc:
            try:
                img = postprocess_ai(gen_ai(name))
                method = "ai"
            except Exception as e:
                print("%s AI 失败，回退程序化: %s" % (name, e), flush=True)
        if method is None:
            img = PROCEDURAL[name]()
            check_opaque(img)
            method = "procedural"
        img.save(out)
        manifest[name] = {"method": method, "size": list(img.size)}
        print("完成: %-16s %s" % (name, method), flush=True)
    with open(os.path.join(OUT_DIR, "_manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("全部完成 ->", OUT_DIR)


if __name__ == "__main__":
    main()
