#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""每建筑专属正交立面贴图生成（B+A 组合方案 A 部分）。

为 13 种非 flat 建筑各生成 1 张带功能特征的正交立面贴图（墙身），
产物 facade/<建筑>_wall.png；宽建筑（2 格）用 256，其余 128。
AI（aiping.cn）优先：单张失败重试 2 次，仍失败回退共享 facade 贴图
（wall_white/wall_wood/wall_gray），manifest 记录 ai / fallback_shared。
已存在的产物跳过（脚本可重入）。

用法: python tools/gen_building_facades.py            # 生成缺失的专属立面
      python tools/gen_building_facades.py --force    # 全部重生成
"""
import base64
import io
import json
import os
import shutil
import sys
import urllib.request

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACADE = os.path.join(ROOT, "assets", "packs", "gongbi", "facade")
MANIFEST = os.path.join(FACADE, "_manifest.json")

STYLE = (
    "flat orthographic architectural facade texture, perfectly straight-on front view, "
    "absolutely no perspective, no depth, no shadows, full frame edge-to-edge pattern, "
    "ancient Chinese Song dynasty village building, traditional gongbi ink painting style, "
    "muted elegant low-saturation colors, hand painted fine brush lines, "
    "the entire picture is this one single building facade wall filling the whole frame, "
    "no text, no watermark, no border, no background, no sky, no ground"
)

# 建筑 -> (prompt 功能特征, 尺寸, 兜底共享贴图)
BUILDINGS = {
    "hut": ("humble peasant house facade, plain whitewashed mud wall with one small wooden lattice window and a simple wooden door, very simple and bare",
            128, "wall_white.png"),
    "tilehouse": ("decent village house facade of a well-off family, grey brick gate wall with a small tiled gatehouse roof over the wooden door, one lattice window",
                  128, "wall_white.png"),
    "mill": ("stone and heavy timber water mill house facade, thick wooden plank lower wall with small grain loft ventilation windows above, sturdy barn-like door",
             256, "wall_wood.png"),
    "grocer": ("grain and oil grocery shop facade, wooden plank shopfront with removable vertical door planks, a low wooden counter window and woven baskets of goods by the door",
               128, "wall_wood.png"),
    "market": ("open bustling market stall facade, wide open front with wooden counters displaying cloth rolls clay jars and dried goods, striped fabric awning hanging above the whole front",
               256, "wall_wood.png"),
    "winery": ("traditional Chinese wine brewery facade, wooden wall with a wide door, big round clay wine jars stacked beside the door and a wooden funnel rack",
               128, "wall_wood.png"),
    "oilpress": ("traditional Chinese oil press workshop facade, heavy dark wooden wall with a small window, a tall square chimney rising at one corner and a wooden beam press frame",
                 128, "wall_wood.png"),
    "loom": ("textile weaving workshop facade, wooden wall with a wide weaving loom window grid, wooden poles with colorful woven cloth hanging to dry beside the door",
             128, "wall_wood.png"),
    "restaurant": ("two-story ancient Chinese tavern facade, wooden upper story with wooden railing balcony, red paper lanterns hanging under the eaves, a long horizontal pole for hanging sign banners under the roof, a wide entrance with wine curtain",
                   256, "wall_white.png"),
    "well": ("traditional Chinese stone water well facade front view, low circular stone block well parapet wall with a small wooden roof frame above and a hanging bucket",
             128, "wall_white.png"),
    "clinic": ("traditional Chinese medicine hall facade, grey brick wooden wall with a vertical wooden signboard plaque beside the door, lattice window revealing herbal medicine cabinet drawers",
               128, "wall_gray.png"),
    "repair": ("traditional Chinese carpenter repair workshop facade, grey brick wooden wall, bamboo scaffolding leaning at one side and stacked timber planks and logs beside the door",
               128, "wall_gray.png"),
    "woodcutter": ("lumberjack log cabin facade, rough wooden plank wall with a small window, neat stacks of chopped firewood piled high beside the door and a chopping stump",
                   128, "wall_wood.png"),
}


def _load_provider() -> dict:
    cfg_path = os.path.join(ROOT, "tools", "ai_provider.json")
    cfg = {"base_url": "https://aiping.cn/api/v1", "key_file": "tools/aiping_api_key.txt",
           "model": "Qwen-Image"}
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    cfg["key"] = open(os.path.join(ROOT, cfg["key_file"]), encoding="utf-8").read().strip()
    return cfg


def gen_ai(prompt: str) -> Image.Image:
    cfg = _load_provider()
    body = {"model": cfg["model"], "prompt": STYLE + ", " + prompt,
            "size": "1024x1024", "n": 1}
    req = urllib.request.Request(cfg["base_url"].rstrip("/") + "/images/generations",
                                 data=json.dumps(body).encode(), headers={
                                     "Authorization": "Bearer " + cfg["key"],
                                     "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=150) as resp:
        data = json.loads(resp.read())
    item = data["data"][0]
    if item.get("b64_json"):
        raw = base64.b64decode(item["b64_json"])
    else:
        with urllib.request.urlopen(item["url"], timeout=60) as r:
            raw = r.read()
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def postprocess_ai(img: Image.Image, size: int) -> Image.Image:
    w, h = img.size
    s = min(w, h)
    img = img.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
    img = img.resize((size, size), Image.LANCZOS).convert("RGB")
    a = np.asarray(img, dtype=np.float32)
    if a.std() < 8.0:
        raise RuntimeError("色彩方差过低(std=%.1f)" % a.std())
    if a.mean() > 248:
        raise RuntimeError("均值过亮(mean=%.1f)" % a.mean())
    return img


def main() -> None:
    force = "--force" in sys.argv
    os.makedirs(FACADE, exist_ok=True)
    manifest = {}
    if os.path.exists(MANIFEST):
        manifest = json.load(open(MANIFEST, encoding="utf-8"))
    cfg = None
    try:
        cfg = _load_provider()
    except Exception as e:
        print("AI 配置不可用，全部回退共享贴图: %s" % e, flush=True)
    for btype, (prompt, size, fallback) in BUILDINGS.items():
        name = "%s_wall.png" % btype
        out = os.path.join(FACADE, name)
        if os.path.exists(out) and not force:
            manifest.setdefault(name, {"method": "ai", "size": [size, size]})
            print("跳过已存在:", name, flush=True)
            continue
        method = None
        if cfg is not None:
            for attempt in range(2):
                try:
                    img = postprocess_ai(gen_ai(prompt), size)
                    method = "ai"
                    break
                except Exception as e:
                    print("%s AI 第%d次失败: %s" % (name, attempt + 1, e), flush=True)
        if method is None:
            shutil.copyfile(os.path.join(FACADE, fallback), out)
            method = "fallback_shared:" + fallback
        else:
            img.save(out)
        manifest[name] = {"method": method, "size": [size, size]}
        print("完成: %-22s %s" % (name, method), flush=True)
        with open(MANIFEST, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("全部完成 ->", FACADE)


if __name__ == "__main__":
    main()
