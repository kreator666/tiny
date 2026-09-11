# -*- coding: utf-8 -*-
"""程序化生成工笔画风游戏贴图（宣纸底 + 宋式建筑，含四方向变体）。
输出到项目 assets/gongbi/ 目录。风格要点：
- 宣纸：米黄底 + 细微颗粒 + 偶尔墨点
- 工笔：墨线勾边 + 矿物颜料平涂（花青、赭石、藤黄、石绿）
- 方向约定：d0=正门(南) d1=门在右(东) d2=背面(北) d3=门在左(西)
运行：python tools/gen_gongbi_assets.py
"""
import math
import os
import random
from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "packs", "gongbi")
os.makedirs(OUT, exist_ok=True)
rng = random.Random(20240101)

PAPER = (233, 224, 198)        # 宣纸米黄
INK = (58, 52, 46)             # 墨线
ROOF = (96, 108, 122)          # 花青瓦
ROOF_DARK = (70, 80, 94)
WALL = (244, 240, 230)         # 粉墙
THATCH = (150, 124, 88)        # 茅
WOOD = (122, 86, 58)           # 赭石木
GREEN = (78, 108, 66)          # 石绿
GREEN_DARK = (52, 78, 48)
SOIL = (156, 118, 76)          # 赭石土


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path)
    print("生成:", name)


def canvas(w, h, shadow_box=None):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if shadow_box:
        sh = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(sh).ellipse(shadow_box, fill=(60, 55, 45, 70))
        img = Image.alpha_composite(img, sh.filter(ImageFilter.GaussianBlur(3)))
    return img


def paper(size, tone=0):
    img = Image.new("RGB", (size, size),
                    (PAPER[0] + tone, PAPER[1] + tone, PAPER[2] + tone))
    px = img.load()
    for y in range(size):
        for x in range(size):
            n = rng.randint(-6, 6)
            r, g, b = px[x, y]
            px[x, y] = (r + n, g + n, b + n - rng.randint(0, 3))
    d = ImageDraw.Draw(img, "RGBA")
    for _ in range(size // 8):
        x, y = rng.randint(0, size - 1), rng.randint(0, size - 1)
        d.ellipse([x, y, x + 1, y + 1], fill=INK + (rng.randint(8, 22),))
    return img


def wash(img, color, alpha, count, rmin, rmax):
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    w, h = img.size
    for _ in range(count):
        x, y = rng.randint(0, w), rng.randint(0, h)
        r = rng.randint(rmin, rmax)
        d.ellipse([x - r, y - r // 2, x + r, y + r // 2],
                  fill=color + (rng.randint(alpha // 2, alpha),))
    overlay = overlay.filter(ImageFilter.GaussianBlur(3))
    img.paste(Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB"),
              (0, 0))


# ---------- 地面 ----------
for v in range(2):
    g = paper(32, tone=rng.randint(-4, 4))
    wash(g, GREEN, 48, 8, 7, 16)
    wash(g, (120, 140, 90), 26, 5, 4, 10)
    d = ImageDraw.Draw(g, "RGBA")
    for _ in range(16):
        x, y = rng.randint(1, 30), rng.randint(1, 30)
        d.line([(x, y), (x + rng.randint(-1, 1), y - 2)],
               fill=GREEN_DARK + (rng.randint(60, 120),), width=1)
    save(g, f"ground_{v}.png")

f = paper(32)
d = ImageDraw.Draw(f, "RGBA")
d.rectangle([0, 0, 31, 31], fill=SOIL + (90,))
for y in range(2, 32, 4):
    d.line([(0, y), (31, y)], fill=(96, 70, 44, 70), width=1)
for y in range(4, 32, 4):
    d.line([(0, y), (31, y)], fill=(206, 170, 118, 50), width=1)
f = f.filter(ImageFilter.GaussianBlur(0.4))
d = ImageDraw.Draw(f, "RGBA")
for _ in range(22):
    x, y = rng.randint(1, 30), rng.randint(1, 30)
    d.line([(x, y), (x, y - 2)], fill=GREEN_DARK + (220,), width=1)
    d.point([(x - 1, y - 1)], fill=GREEN + (200,))
save(f, "farm.png")

r = paper(32)
d = ImageDraw.Draw(r, "RGBA")
d.rectangle([0, 8, 31, 24], fill=(172, 152, 120, 120))
for y in (8, 24):
    d.line([(0, y), (31, y)], fill=INK + (70,), width=1)
for _ in range(12):
    x, y = rng.randint(0, 31), rng.randint(9, 23)
    d.point([(x, y)], fill=(120, 102, 78, 160))
r = r.filter(ImageFilter.GaussianBlur(0.4))
save(r, "road.png")


# ---------- 立牌建筑通用绘制 ----------
# door 位置: "c"正中 "r"右 "l"左 None=背面
def paint_house(door, thatch=False):
    S = 64
    img = canvas(S, S, [8, 50, 56, 60])
    d = ImageDraw.Draw(img)
    roof_col = THATCH if thatch else ROOF
    d.rectangle([14, 34, 50, 52], fill=WALL if not thatch else (238, 230, 210))
    d.rectangle([14, 34, 50, 52], outline=INK)
    d.polygon([(6, 34), (20, 20), (44, 20), (58, 34)], fill=roof_col)
    d.line([(6, 34), (20, 20), (44, 20), (58, 34), (6, 34)], fill=INK)
    d.line([(20, 20), (44, 20)], fill=INK, width=2)
    for x in range(12, 54, 4):
        top_y = 20 + abs(x - 32) * 14 // 26
        d.line([(x, top_y + 1), (x - 2 if x < 32 else x + 2, 33)],
               fill=ROOF_DARK + (160,), width=1)
    d.line([(6, 34), (58, 34)], fill=INK)
    if thatch:
        for x in range(10, 56, 5):
            d.line([(x, 26), (x - 3 if x < 32 else x + 3, 33)],
                   fill=(120, 98, 66, 140), width=1)

    def win(wx):
        d.rectangle([wx, 41, wx + 4, 47], fill=(210, 200, 180), outline=INK)
        d.line([(wx + 2, 41), (wx + 2, 47)], fill=INK)
        d.line([(wx, 44), (wx + 4, 44)], fill=INK)

    if door is None:  # 背面：双窗
        win(19)
        win(41)
    else:
        dx = {"c": 28, "l": 16, "r": 40}[door]
        d.rectangle([dx, 40, dx + 8, 52], fill=WOOD, outline=INK)
        d.line([(dx + 4, 40), (dx + 4, 52)], fill=INK)
        d.point([(dx + 2, 45), (dx + 6, 45)], fill=(220, 190, 120))
        win(41 if door == "l" else 17)
    return img.resize((32, 32), Image.LANCZOS)


def paint_mill(door, wheel_side):
    S = 64
    img = canvas(S, S, [6, 48, 58, 58])
    d = ImageDraw.Draw(img)
    d.rectangle([12, 30, 50, 50], fill=(238, 230, 210), outline=INK)
    d.polygon([(4, 30), (20, 15), (42, 15), (58, 30)], fill=(136, 112, 82))
    d.line([(4, 30), (20, 15), (42, 15), (58, 30), (4, 30)], fill=INK)
    d.line([(20, 15), (42, 15)], fill=INK, width=2)
    if door is not None:
        dx = {"c": 28, "l": 16, "r": 36}[door]
        d.rectangle([dx, 38, dx + 8, 50], fill=WOOD, outline=INK)
    else:
        d.rectangle([18, 38, 26, 46], fill=(210, 200, 180), outline=INK)
        d.line([(22, 38), (22, 46)], fill=INK)
    if wheel_side is not None:  # 水车
        cx = 52 if wheel_side == "r" else 12
        cy, rr = 42, 11
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(150, 120, 90),
                  outline=INK, width=2)
        d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=INK)
        for a in range(0, 360, 45):
            x2 = cx + int(rr * 0.85 * math.cos(math.radians(a)))
            y2 = cy + int(rr * 0.85 * math.sin(math.radians(a)))
            d.line([(cx, cy), (x2, y2)], fill=INK, width=1)
    return img.resize((32, 32), Image.LANCZOS)


def paint_market(door, flag_side):
    S = 64
    img = canvas(S, S, [6, 48, 58, 58])
    d = ImageDraw.Draw(img)
    for px in (14, 46):
        d.line([(px, 24), (px, 44)], fill=INK, width=3)
    d.polygon([(8, 24), (52, 24), (48, 16), (12, 16)], fill=(238, 232, 220))
    for sx in range(10, 52, 7):
        d.line([(sx, 16), (sx - 2, 24)], fill=(146, 94, 62), width=3)
    d.line([(8, 24), (52, 24)], fill=INK)
    d.rectangle([12, 40, 50, 47], fill=(168, 128, 88), outline=INK)
    d.line([(12, 43), (50, 43)], fill=INK + (120,))
    if door is None:  # 背面
        d.rectangle([24, 26, 36, 33], fill=(210, 200, 180), outline=INK)
    if flag_side is not None:
        fx = 56 if flag_side == "r" else 8
        d.line([(fx, 46), (fx, 12)], fill=INK, width=2)
        bx0, bx1 = (fx, fx + 7) if flag_side == "r" else (fx - 7, fx)
        d.polygon([(bx0, 12), (bx1, 14), (bx1, 28), (bx0, 26)], fill=(172, 62, 52))
        d.line([(min(bx0, bx1) + 1, 18), (max(bx0, bx1) - 1, 19)],
               fill=(238, 232, 220))
        d.line([(min(bx0, bx1) + 1, 23), (max(bx0, bx1) - 1, 24)],
               fill=(238, 232, 220))
    return img.resize((32, 32), Image.LANCZOS)


def paint_woodcutter(door, pile_side):
    S = 64
    img = canvas(S, S, [8, 50, 56, 60])
    d = ImageDraw.Draw(img)
    # 原木小屋：赭石木板墙 + 茅顶
    d.rectangle([14, 34, 50, 52], fill=(172, 132, 92), outline=INK)
    for y in range(38, 52, 4):
        d.line([(15, y), (49, y)], fill=(120, 88, 58, 150), width=1)
    d.polygon([(6, 34), (20, 20), (44, 20), (58, 34)], fill=THATCH)
    d.line([(6, 34), (20, 20), (44, 20), (58, 34), (6, 34)], fill=INK)
    d.line([(20, 20), (44, 20)], fill=INK, width=2)
    for x in range(12, 54, 4):
        top_y = 20 + abs(x - 32) * 14 // 26
        d.line([(x, top_y + 1), (x - 2 if x < 32 else x + 2, 33)],
               fill=(120, 98, 66, 160), width=1)
    if door is None:  # 背面：小窗
        d.rectangle([28, 40, 36, 47], fill=(210, 200, 180), outline=INK)
        d.line([(32, 40), (32, 47)], fill=INK)
    else:
        dx = {"c": 28, "l": 16, "r": 34}[door]
        d.rectangle([dx, 40, dx + 8, 52], fill=(96, 66, 42), outline=INK)
    # 柴堆：三根叠放的原木
    if pile_side is not None:
        px = 10 if pile_side == "l" else 44
        for i, ly in enumerate((46, 42, 38)):
            d.rounded_rectangle([px, ly, px + 10, ly + 4], 2,
                                fill=(150, 116, 78), outline=INK)
            d.ellipse([px + 7, ly, px + 11, ly + 4], fill=(196, 164, 116), outline=INK)
            d.ellipse([px + 8, ly + 1, px + 10, ly + 3], outline=(120, 88, 58))
        # 斜靠的斧头
        ax = 22 if pile_side == "l" else 42
        d.line([(ax, 52), (ax + 6, 36)], fill=INK, width=2)
        d.polygon([(ax + 4, 34), (ax + 11, 36), (ax + 9, 42), (ax + 3, 40)],
                  fill=(120, 128, 138), outline=INK)
    return img.resize((32, 32), Image.LANCZOS)


# 门朝向: d0正 d1右 d2背 d3左
DOORS = ["c", "r", None, "l"]
for i, door in enumerate(DOORS):
    save(paint_house(door, thatch=True), f"hut_d{i}.png")
    save(paint_house(door), f"house_d{i}.png")
    save(paint_mill(door if door != "c" else "c", None if door is None else ("r" if i % 2 == 0 else "l")), f"mill_d{i}.png")
    save(paint_market(door, None if door is None else ("r" if i % 2 == 0 else "l")), f"market_d{i}.png")
    save(paint_woodcutter(door, None if door is None else ("r" if i % 2 == 0 else "l")), f"woodcutter_d{i}.png")


# ---------- 方向路块（32x32 贴地，conns 为屏幕方向 nesw 子集） ----------
def paint_road_tile(conns):
    mask = Image.new("L", (32, 32), 0)
    md = ImageDraw.Draw(mask)
    c = 16
    if not conns:
        md.ellipse([9, 9, 23, 23], fill=255)
    else:
        for conn in conns:
            if conn == "e":
                md.rectangle([c, 10, 32, 22], fill=255)
            elif conn == "w":
                md.rectangle([0, 10, c, 22], fill=255)
            elif conn == "s":
                md.rectangle([10, c, 22, 32], fill=255)
            elif conn == "n":
                md.rectangle([10, 0, 22, c], fill=255)
        if len(conns) == 1:  # 断头：中心圆角
            md.ellipse([8, 8, 24, 24], fill=255)
    edge_mask = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(3)))

    img = canvas(32, 32)
    dirt = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    dirt.paste(Image.new("RGBA", (32, 32), (188, 168, 134, 255)), (0, 0), mask)
    # 肌理：碎石墨点
    dd = ImageDraw.Draw(dirt)
    for _ in range(14):
        x, y = rng.randint(2, 29), rng.randint(2, 29)
        if mask.getpixel((x, y)):
            dd.point([(x, y)], fill=(120, 102, 78, rng.randint(90, 160)))
            if rng.random() < 0.4:
                dd.point([(x + 1, y)], fill=(214, 196, 160, 140))
    img = Image.alpha_composite(img, dirt)
    edge = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    edge.paste(Image.new("RGBA", (32, 32), (120, 102, 78, 200)), (0, 0), edge_mask)
    return Image.alpha_composite(img, edge)


ROAD_VARIANTS = {
    "o": [], "n": ["n"], "e": ["e"], "s": ["s"], "w": ["w"],
    "ne": ["n", "e"], "ns": ["n", "s"], "nw": ["n", "w"],
    "es": ["e", "s"], "ew": ["e", "w"], "sw": ["s", "w"],
    "nes": ["n", "e", "s"], "new": ["n", "e", "w"], "nsw": ["n", "s", "w"],
    "esw": ["e", "s", "w"], "nesw": ["n", "e", "s", "w"],
}
for name, conns in ROAD_VARIANTS.items():
    save(paint_road_tile(conns), f"road_{name}.png")


# ---------- 大院（96x80，占 2x2 格，gate: c/r/l/None） ----------
BRICK = (170, 164, 150)   # 青砖
BRICK_DK = (152, 146, 132)


def gable_roof(d, x0, ytop, x1, ybot, col=ROOF):
    """梯形瓦屋顶 + 瓦垄墨线"""
    pts = [(x0, ybot), (x0 + (x1 - x0) * 0.22, ytop), (x1 - (x1 - x0) * 0.22, ytop), (x1, ybot)]
    d.polygon(pts, fill=col)
    d.line(pts + [pts[0]], fill=INK)
    d.line([pts[1], pts[2]], fill=INK, width=2)  # 正脊
    for x in range(x0 + 3, x1 - 2, 4):
        t = abs(x - (x0 + x1) / 2) / ((x1 - x0) / 2)
        ys = ytop + t * (ybot - ytop)
        d.line([(x, ys + 1), (x, ybot)], fill=ROOF_DARK + (150,), width=1)


def paint_estate(tier, gate):
    W, H = 96, 80
    img = canvas(W, H, [8, 64, 88, 74])
    d = ImageDraw.Draw(img)
    big = tier == 3
    back = gate is None
    gx = 41 if gate == "c" else 66  # 门洞左缘（r 用 66，l 镜像后等效）

    if big:  # 门前花木（先画，墙会遮住根部）
        for tx in (4, 82):
            d.ellipse([tx, 50, tx + 10, 62], fill=GREEN + (220,), outline=INK)

    # 两厢（先画，被正房压住内缘）
    gable_roof(d, 0, 30, 34, 42, ROOF_DARK)
    gable_roof(d, 62, 30, 96, 42, ROOF_DARK)
    for wx in (8, 62):  # 厢房墙
        d.rectangle([wx, 42, wx + 28, 58], fill=BRICK, outline=INK)
        d.rectangle([wx + 10, 46, wx + 18, 54], fill=(210, 200, 180), outline=INK)
        d.line([(wx + 14, 46), (wx + 14, 54)], fill=INK)

    # 正房：大屋顶占上半部 + 青砖墙
    gable_roof(d, 16, 10 if big else 14, 80, 34, ROOF)
    if big:  # 重檐
        gable_roof(d, 30, 2, 66, 12, ROOF_DARK)
    d.rectangle([24, 34, 72, 58], fill=BRICK, outline=INK)
    for x in range(28, 70, 8):  # 砖缝
        d.line([(x, 36), (x, 56)], fill=BRICK_DK + (110,), width=1)
    if back:
        for wx in (32, 56):
            d.rectangle([wx, 42, wx + 8, 50], fill=(210, 200, 180), outline=INK)
            d.line([(wx + 4, 42), (wx + 4, 50)], fill=INK)
    else:
        d.rectangle([42, 44, 54, 58], fill=WOOD, outline=INK)  # 正房门
        d.line([(48, 44), (48, 58)], fill=INK)
        for wx in (29, 60):
            d.rectangle([wx, 44, wx + 7, 51], fill=(210, 200, 180), outline=INK)

    # 前围墙（矮，压底）+ 瓦檐压顶
    d.rectangle([2, 58, 94, 72], fill=BRICK_DK, outline=INK)
    d.line([(2, 58), (94, 58)], fill=ROOF_DARK, width=3)
    for x in range(10, 94, 8):
        d.line([(x, 62), (x, 70)], fill=INK + (70,), width=1)
    if back:
        for wx in (20, 68):
            d.rectangle([wx, 62, wx + 8, 70], fill=(210, 200, 180), outline=INK)
    else:
        d.rectangle([gx, 58, gx + 14, 72], fill=(60, 50, 40), outline=INK)  # 门洞
        d.line([(gx + 7, 58), (gx + 7, 72)], fill=INK)
        gable_roof(d, gx - 3, 46, gx + 17, 58, ROOF)  # 门楼小顶

    if gate == "l":
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return img


GATES = ["c", "r", None, "l"]
for i, gate in enumerate(GATES):
    save(paint_estate(2, gate), f"estate2_d{i}.png")
    save(paint_estate(3, gate), f"estate3_d{i}.png")


# ---------- 树与行人 ----------
W, H = 40, 56
t = canvas(W, H)
d = ImageDraw.Draw(t)
d.line([(20, 54), (19, 44), (21, 36), (19, 28)], fill=INK, width=3)
d.line([(20, 44), (12, 36)], fill=INK, width=2)
d.line([(20, 40), (28, 32)], fill=INK, width=2)


def cluster(cx, cy, rx, ry):
    pts = [(cx + int(rx * math.cos(a)), cy + int(ry * math.sin(a)))
           for a in [j * math.pi / 10 for j in range(20)]]
    d.polygon(pts, fill=GREEN + (235,))
    d.line(pts + [pts[0]], fill=INK, width=1)
    for _ in range(6):
        a = rng.uniform(0, math.pi * 2)
        x = cx + int(rx * 0.6 * math.cos(a))
        y = cy + int(ry * 0.6 * math.sin(a))
        d.line([(x, y), (x + 2, y - 1)], fill=GREEN_DARK + (220,), width=1)


cluster(20, 12, 13, 6)
cluster(20, 19, 15, 6)
cluster(10, 22, 7, 4)
cluster(30, 21, 7, 4)
save(t, "tree.png")

VW, VH = 12, 20
v = canvas(VW, VH)
d = ImageDraw.Draw(v)
ROBE = (96, 106, 126)
d.polygon([(6, 6), (3, 9), (2, 18), (10, 18), (9, 9)], fill=ROBE, outline=INK)
d.line([(6, 9), (6, 17)], fill=INK + (120,), width=1)
d.ellipse([3, 0, 9, 6], fill=(224, 192, 158), outline=INK)
d.polygon([(3, 1), (9, 1), (8, 3), (4, 3)], fill=INK)
d.line([(4, 18), (4, 19)], fill=INK)
d.line([(8, 18), (8, 19)], fill=INK)
save(v, "villager.png")

print("全部完成 ->", os.path.abspath(OUT))
