# -*- coding: utf-8 -*-
"""用 302.ai (gpt-image-1) 生成工笔风游戏素材包。

用法：
  python tools/gen_ai_assets.py <包名>            # 生成全部素材
  python tools/gen_ai_assets.py <包名> estate3_d0 # 只生成指定素材（调试用）
  python tools/gen_ai_assets.py --test            # 试生成一张到临时目录，不入库

生成结果：透明背景 -> 裁边 -> 缩放到规格尺寸 -> 存入 assets/packs/<包名>/
API Key 存放在 tools/302_api_key.txt（已被 .gitignore 忽略，勿提交）
"""
import base64
import io
import json
import os
import sys
import urllib.request

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_FILE = os.path.join(ROOT, "tools", "302_api_key.txt")


def _load_provider():
    """读取 tools/ai_provider.json：{"base_url":..., "key_file":..., "model":...}"""
    cfg_path = os.path.join(ROOT, "tools", "ai_provider.json")
    cfg = {"base_url": "https://api.302.ai/v1", "key_file": "tools/302_api_key.txt", "model": "gpt-image-1"}
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    cfg["key"] = open(os.path.join(ROOT, cfg["key_file"]), encoding="utf-8").read().strip()
    return cfg


PROVIDER = _load_provider()

STYLE = (
    "Chinese gongbi painting style game sprite, Song dynasty architecture, "
    "hand-painted mineral pigment texture, ink outlines, dark blue-grey tiled roofs, "
    "warm grey brick walls, clean silhouette, single building, full view, centered, "
    "isolated on plain background"
)

# 素材清单。四方向建筑只生成 d0(正面)/d1(侧视)/d2(背面)，d3 由 d1 水平翻转派生。
DIR_PROMPTS = {
    0: "front view, main door centered",
    1: "three-quarter view, main door on the right side of the facade",
    2: "back view, no door, windows only",
}

BUILDINGS_1X1 = {
    "hut": "humble poor peasant hut with rough yellow straw thatch roof, mud brick walls and a plain wooden door, very simple and small",
    "house": "grey brick village house with blue-grey tiled roof, wooden door and lattice window",
    "mill": "small water mill house with tiled roof and a wooden water wheel attached on the right side",
    "market": "traditional Chinese market stall with striped fabric awning on wooden poles and a red banner flag",
    "clinic": "small traditional Chinese medicine hall, grey brick walls with blue-grey tiled roof, hanging wooden signboard with a green cross emblem, bundles of dried herbs drying under the eaves, a ceramic medicine jar by the wooden door",
    "repair": "small traditional Chinese carpenter workshop, grey brick walls with blue-grey tiled roof, stacks of wooden planks and timber logs beside it, a wooden sawhorse and tool rack in front, sawdust on the ground",
}

ESTATES = {
    "estate2": ("grand Chinese courtyard mansion compound, main hall with wide blue-grey tiled roof, grey brick walls, "
                "front courtyard wall with centered wooden gate and small tiled gatehouse"),
    "estate3": ("luxurious Chinese mansion compound with double-eaved main hall, side wings, grey brick walls, "
                "front courtyard wall with centered wooden gate and ornate tiled gatehouse, garden trees"),
}

ESTATE_SIZE = (96, 80)

STYLE_SINGLE = (
    "Chinese gongbi painting style, hand-painted mineral pigment texture, ink outlines, "
    "video game asset, isolated on plain background"
)

# 单贴图素材：文件名 -> (提示词, 目标尺寸)
SINGLES = {
    "farm.png": ("top-down view of a small rectangular vegetable farm field, neat rows of green crops on dark brown tilled soil, no buildings", (32, 32)),
    "tree.png": ("a single Chinese pine tree with lush green layered cloud-like foliage and visible trunk, no buildings", (40, 56)),
    "villager.png": ("a tiny ancient Chinese villager person wearing a grey robe and straw hat, walking pose, full body, no buildings", (16, 24)),
    "well.png": ("a traditional Chinese stone water well with a wooden roof frame and a hanging wooden bucket, grey stone blocks, no buildings", (32, 32)),
    "ground_0.png": ("seamless tileable ground texture, subtle rice-paper beige with faint grass wash, traditional Chinese painting background, completely empty, no objects, top-down", (32, 32)),
    "ground_1.png": ("seamless tileable ground texture, subtle rice-paper light green grass wash, traditional Chinese painting background, completely empty, no objects, top-down", (32, 32)),
}


def gen(prompt: str) -> Image.Image:
    body = {
        "model": PROVIDER["model"],
        "prompt": prompt,
        "size": "1024x1024",
        "transparent_background": True,  # Seedream/即梦支持；gpt-image-1 用 background 参数
    }
    if PROVIDER["model"].startswith("gpt-image"):
        body.pop("transparent_background")
        body["background"] = "transparent"
        body["response_format"] = "b64_json"
    req = urllib.request.Request(PROVIDER["base_url"].rstrip("/") + "/images/generations",
                                 data=json.dumps(body).encode(), headers={
                                     "Authorization": "Bearer " + PROVIDER["key"],
                                     "Content-Type": "application/json",
                                 })
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    item = data["data"][0]
    if "b64_json" in item and item["b64_json"]:
        raw = base64.b64decode(item["b64_json"])
    else:
        with urllib.request.urlopen(item["url"], timeout=120) as r:
            raw = r.read()
    return Image.open(io.BytesIO(raw)).convert("RGBA")


def _remove_opaque_bg(img: Image.Image) -> Image.Image:
    """无透明通道时按边缘纸色泛洪填充抠背景（容忍度收紧，防漏进食内部）。"""
    from collections import deque
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()

    # 角点纸色（多取几个角点取中位，防角上有墨点）
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    corners.sort(key=lambda p: p[0] + p[1] + p[2])
    cr, cg, cb = corners[len(corners) // 2][:3]

    def near_paper(p) -> bool:
        return abs(p[0] - cr) + abs(p[1] - cg) + abs(p[2] - cb) <= 36

    q = deque()
    seen = bytearray(w * h)
    for x in range(w):
        for y in (0, h - 1):
            if near_paper(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if near_paper(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and near_paper(px[nx, ny]):
                seen[ny * w + nx] = 1
                q.append((nx, ny))
    for y in range(h):
        base = y * w
        for x in range(w):
            if seen[base + x]:
                r, g, b, a = px[x, y]
                px[x, y] = (r, g, b, 0)
    # 背景边缘羽化：已透明像素邻接的不透明像素半透明，去锯齿
    edge = []
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0:
                continue
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                    edge.append((x, y))
                    break
    for x, y in edge:
        r, g, b, a = px[x, y]
        px[x, y] = (r, g, b, 110)
    return img


def postprocess(img: Image.Image, size) -> Image.Image:
    """抠背景 -> 裁边 -> 等比缩放到目标框内"""
    has_alpha = img.mode == "RGBA" and min(p[3] for p in img.getdata()) < 250
    if not has_alpha:
        img = _remove_opaque_bg(img)
    bbox = img.getbbox()
    if bbox:
        img = img.crop(bbox)
    tw, th = size
    scale = min(tw / img.width, th / img.height)
    img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.LANCZOS)
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.paste(img, ((tw - img.width) // 2, th - img.height))  # 底部对齐（立牌落脚点）
    return out


def main():
    args = sys.argv[1:]
    if args and args[0] == "--test":
        name = args[1] if len(args) > 1 else "estate3_d0"
        prompt, size = SINGLES[name] if name in SINGLES else (ESTATES[name[:-3]][0] if name.startswith("estate") else BUILDINGS_1X1[name[:-3]], ESTATE_SIZE if name.startswith("estate") else (32, 32))
        print("生成测试:", name)
        img = postprocess(gen(STYLE + ", " + prompt + ", " + DIR_PROMPTS[0]), size)
        out = os.path.join(os.environ.get("TEMP", "."), "ai_test_%s.png" % name.replace(".png", ""))
        img.save(out)
        print("已保存:", out)
        return
    pack = args[0] if args else "gongbi_ai"
    only = set(args[1:])  # 只重新生成指定项，如: hut farm.png singles
    outdir = os.path.join(ROOT, "assets", "packs", pack)
    os.makedirs(outdir, exist_ok=True)
    manifest = {"name": pack, "title": "302.AI 生成素材包", "desc": "gpt-image-1 生成，工笔画风"}
    if not only:
        with open(os.path.join(outdir, "pack.json"), "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)

    def save_img(img: Image.Image, name: str):
        img.save(os.path.join(outdir, name))
        print("  完成:", name, flush=True)

    # 1 格建筑：d0/d1/d2 生成，d3 翻转派生
    for base, body in BUILDINGS_1X1.items():
        if only and base not in only:
            continue
        for d in (0, 1, 2):
            name = "%s_d%d.png" % (base, d)
            print("生成:", name, flush=True)
            try:
                img = postprocess(gen(STYLE + ", " + body + ", " + DIR_PROMPTS[d]), (32, 32))
            except Exception as e:
                print("  失败: %s（回退默认包）" % e, flush=True)
                continue
            save_img(img, name)
        d1 = os.path.join(outdir, "%s_d1.png" % base)
        d3 = os.path.join(outdir, "%s_d3.png" % base)
        if os.path.exists(d1):
            Image.open(d1).transpose(Image.FLIP_LEFT_RIGHT).save(d3)
            print("  派生:", os.path.basename(d3), flush=True)
    # 大院：同上，96x80
    for base, body in ESTATES.items():
        if only and base not in only:
            continue
        for d in (0, 1, 2):
            name = "%s_d%d.png" % (base, d)
            print("生成:", name, flush=True)
            try:
                img = postprocess(gen(STYLE + ", " + body + ", " + DIR_PROMPTS[d]), ESTATE_SIZE)
            except Exception as e:
                print("  失败: %s（回退默认包）" % e, flush=True)
                continue
            save_img(img, name)
        d1 = os.path.join(outdir, "%s_d1.png" % base)
        d3 = os.path.join(outdir, "%s_d3.png" % base)
        if os.path.exists(d1):
            Image.open(d1).transpose(Image.FLIP_LEFT_RIGHT).save(d3)
            print("  派生:", os.path.basename(d3), flush=True)
    # 单贴图
    for name, (body, size) in SINGLES.items():
        if only and name not in only and "singles" not in only:
            continue
        print("生成:", name, flush=True)
        try:
            img = postprocess(gen(STYLE_SINGLE + ", " + body), size)
        except Exception as e:
            print("  失败: %s（回退默认包）" % e, flush=True)
            continue
        save_img(img, name)
    print("全部完成 ->", outdir)


if __name__ == "__main__":
    main()
