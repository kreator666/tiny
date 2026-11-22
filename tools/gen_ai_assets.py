# -*- coding: utf-8 -*-
"""用 aiping.cn 文生图模型生成像素等距视角游戏素材（带侧墙，凯撒3风格）。

用法：
  python tools/gen_ai_assets.py            # 生成全部素材，直接替换 gongbi 包
  python tools/gen_ai_assets.py hut        # 只重新生成指定项（调试用）
  python tools/gen_ai_assets.py --test hut # 试生成一张到临时目录，不入库

要点：
- 提示词必须全英文：本网关会劫持中文提示词返回无关 canned 图
- 目标包 gongbi：只覆盖建筑/大院/树/行人/水井，地面/道路/农田保留程序化版本
- 白底生成 -> 角点泛洪抠背景 -> 裁边 -> 底部对齐缩放
API Key 存放在 tools/aiping_api_key.txt（已被 .gitignore 忽略，勿提交）
"""
import base64
import io
import json
import os
import sys
import urllib.request

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_FILE = os.path.join(ROOT, "tools", "aiping_api_key.txt")

# 目标包与尺寸（CELL=48：1 格建筑 96x96，2x2 大宅 144x120）
PACK = "gongbi"
SIZE_1X1 = (96, 96)
SIZE_ESTATE = (144, 120)
SIZE_TREE = (60, 84)
SIZE_VILLAGER = (18, 30)


def _load_provider():
    """读取 tools/ai_provider.json：{"base_url":..., "key_file":..., "model":...}"""
    cfg_path = os.path.join(ROOT, "tools", "ai_provider.json")
    cfg = {"base_url": "https://aiping.cn/api/v1", "key_file": "tools/aiping_api_key.txt", "model": "Qwen-Image"}
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg.update(json.load(f))
    cfg["key"] = open(os.path.join(ROOT, cfg["key_file"]), encoding="utf-8").read().strip()
    return cfg


PROVIDER = _load_provider()

STYLE = (
    "pixel art isometric game sprite, classic 2D city-builder game style, "
    "ancient Chinese architecture, crisp clean pixels, rich warm colors, "
    "exactly one single building and nothing else in the picture, complete view, centered, "
    "the building floats on pure white background, absolutely no ground, no dirt patch, no grass, "
    "no shadow, no text, no letters, no watermark"
)

# 四方向贴图：d0(正面)/d1(侧视)/d2(背面) 生成，d3 由 d1 水平翻转派生
DIR_PROMPTS = {
    0: "front view facing the viewer, main door centered",
    1: "three-quarter view showing the front wall and the right side wall, main door on the right part of the facade",
    2: "back three-quarter view, no door, windows only",
}

BUILDINGS_1X1 = {
    "hut": "humble peasant hut with rough golden straw thatch roof, whitewashed mud walls, plain wooden door and a small lattice window, very simple and small",
    "house": "grey brick village house with dark blue-grey tiled gable roof, wooden door and wooden lattice windows, modest but sturdy",
    "mill": "small stone water mill house with dark blue-grey tiled roof and a large wooden water wheel attached to its right side",
    "grocer": "grain and oil grocery shop with dark blue-grey tiled roof, striped fabric awning over the front, burlap sacks of rice and flour piled in front, wooden counter",
    "market": "bustling market stall with striped fabric awning on wooden poles, hanging dried goods, cloth rolls and clay wine jars displayed, red banner flag",
    "winery": "traditional Chinese wine brewery with dark tiled roof, big round clay wine jars stacked beside the front wall, red banner flag with a wine symbol",
    "oilpress": "traditional Chinese oil press workshop with thatched roof, heavy wooden beam press frame beside it, clay oil jars and stacked sesame sacks",
    "loom": "textile weaving workshop with dark tiled roof, a wooden loom frame in front, bolts of colorful cloth hanging on a wooden rack",
    "woodcutter": "lumberjack wooden cabin with rough straw thatch roof, neat piles of chopped logs and timber planks stacked beside it, a chopping stump with an axe",
    "restaurant": "two-story Chinese tavern with dark blue-grey tiled roofs, red paper lanterns hanging under the eaves, a red banner flag with a wine cup symbol, wooden balcony",
    "clinic": "traditional Chinese medicine hall with grey brick walls and dark tiled roof, hanging wooden signboard, bundles of dried herbs under the eaves, ceramic medicine jars by the door",
    "repair": "traditional Chinese carpenter repair workshop with grey brick walls and dark tiled roof, stacks of wooden planks and timber logs beside it, wooden sawhorse and tool rack in front",
    # 矿产线：矿场井架矿车 / 兵器坊刀枪架火炉 / 炼金坊丹炉烟囱
    "mine": "mining pit with a heavy timber headframe derrick tower, large pulley wheel on top, a small wooden ore cart full of dark grey iron rocks beside the shaft, wooden support beams and ropes",
    "weaponry": "ancient Chinese weapons workshop, open wooden shed with racks of spears halberds and pole weapons standing in rows, a glowing forge furnace at one side, weapon racks and a quench barrel",
    "goldworks": "ancient Chinese alchemy workshop with a round clay alchemy furnace with domed top, a tall thin brick chimney rising high beside it, brass crucible vessels, wisps of smoke",
}

ESTATES = {
    "estate2": ("grand Chinese courtyard mansion compound, main hall with wide dark blue-grey tiled roof and grey brick walls, "
                "front courtyard wall with centered wooden gate and small tiled gatehouse, two stone lions by the gate"),
    "estate3": ("luxurious Chinese mansion compound with double-eaved main hall and side wings, grey brick walls, "
                "front courtyard wall with centered ornate wooden gate and tiled gatehouse, two stone lions by the gate, small garden trees inside the yard"),
}

STYLE_SINGLE = STYLE  # 树/行人同一风格

# 单贴图素材：文件名 -> (提示词, 目标尺寸)
SINGLES = {
    "tree.png": ("one single lush Chinese pine tree with layered cloud-like green foliage and a visible brown trunk, the tree only, no pavilion, no building, no structure", SIZE_TREE),
    "villager.png": ("one single ancient Chinese farmer walking, a human figure with head, two arms and two legs clearly visible, wearing a grey robe and a straw hat, full body from head to toe, side view, person only, no house, no building, no structure", SIZE_VILLAGER),
    "well.png": ("a traditional Chinese stone water well built of grey stone blocks with a small wooden roof frame and a hanging wooden bucket on a rope, dark tiled little roof", SIZE_1X1),
}


def gen(prompt: str) -> Image.Image:
    body = {
        "model": PROVIDER["model"],
        "prompt": prompt,
        "size": "1024x1024",
        "n": 1,
    }
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
    """无透明通道时按边缘背景色泛洪填充抠背景（只清外圈，内部同色保留）。
    背景色取边框像素中出现最多的两种颜色（兼容模型同时给白色和深色角的情况）。"""
    from collections import deque
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()

    border = []
    for x in range(w):
        border.append(px[x, 0][:3])
        border.append(px[x, h - 1][:3])
    for y in range(h):
        border.append(px[0, y][:3])
        border.append(px[w - 1, y][:3])
    bins: dict = {}
    for r, g, b in border:
        key = (r // 24, g // 24, b // 24)
        if key not in bins:
            bins[key] = [0, (r, g, b)]
        bins[key][0] += 1
    top = sorted(bins.values(), key=lambda v: -v[0])[:2]
    bgcols = [v[1] for v in top]

    def near_bg(p) -> bool:
        return any(abs(p[0] - cr) + abs(p[1] - cg) + abs(p[2] - cb) <= 42 for cr, cg, cb in bgcols)

    q = deque()
    seen = bytearray(w * h)
    for x in range(w):
        for y in (0, h - 1):
            if near_bg(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if near_bg(px[x, y]) and not seen[y * w + x]:
                seen[y * w + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx] and near_bg(px[nx, ny]):
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
    """抠背景 -> 裁边 -> 等比缩放到目标框内（底部对齐=立牌落脚点）"""
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
    out.paste(img, ((tw - img.width) // 2, th - img.height))
    return out


def main():
    args = sys.argv[1:]
    if args and args[0] == "--test":
        name = args[1] if len(args) > 1 else "hut"
        body = BUILDINGS_1X1.get(name) or ESTATES.get(name) or (SINGLES[name + ".png"][0] if name + ".png" in SINGLES else None)
        size = SIZE_ESTATE if name.startswith("estate") else (SINGLES.get(name + ".png", (None, SIZE_1X1))[1])
        if body is None:
            print("未知素材:", name)
            return
        print("生成测试:", name)
        img = postprocess(gen(STYLE + ", " + body + ", " + DIR_PROMPTS[0]), size)
        out = os.path.join(os.environ.get("TEMP", "."), "ai_test_%s.png" % name)
        img.save(out)
        print("已保存:", out)
        return
    only = set(args)
    outdir = os.path.join(ROOT, "assets", "packs", PACK)
    os.makedirs(outdir, exist_ok=True)

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
                img = postprocess(gen(STYLE + ", " + body + ", " + DIR_PROMPTS[d]), SIZE_1X1)
            except Exception as e:
                print("  失败: %s（保留旧图）" % e, flush=True)
                continue
            save_img(img, name)
        d1 = os.path.join(outdir, "%s_d1.png" % base)
        d3 = os.path.join(outdir, "%s_d3.png" % base)
        if os.path.exists(d1):
            Image.open(d1).transpose(Image.FLIP_LEFT_RIGHT).save(d3)
            print("  派生:", os.path.basename(d3), flush=True)
    # 大院：同上
    for base, body in ESTATES.items():
        if only and base not in only:
            continue
        for d in (0, 1, 2):
            name = "%s_d%d.png" % (base, d)
            print("生成:", name, flush=True)
            try:
                img = postprocess(gen(STYLE + ", " + body + ", " + DIR_PROMPTS[d]), SIZE_ESTATE)
            except Exception as e:
                print("  失败: %s（保留旧图）" % e, flush=True)
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
            print("  失败: %s（保留旧图）" % e, flush=True)
            continue
        save_img(img, name)
    print("全部完成 ->", outdir)


if __name__ == "__main__":
    main()
