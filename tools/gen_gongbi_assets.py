# -*- coding: utf-8 -*-
"""程序化生成工笔画风游戏贴图（宣纸底 + 宋式民居 + 农田 + 松树）。
输出到项目 assets/gongbi/ 目录。风格要点：
- 宣纸：米黄底 + 细微颗粒 + 偶尔墨点
- 工笔：墨线勾边 + 矿物颜料平涂（花青、赭石、藤黄、石绿）
运行：python tools/gen_gongbi_assets.py
"""
import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "gongbi")
os.makedirs(OUT, exist_ok=True)
rng = random.Random(20240101)

PAPER = (233, 224, 198)        # 宣纸米黄
INK = (58, 52, 46)             # 墨线
ROOF = (96, 108, 122)          # 花青瓦
ROOF_DARK = (70, 80, 94)
WALL = (244, 240, 230)         # 粉墙
WOOD = (122, 86, 58)           # 赭石木
GREEN = (78, 108, 66)          # 石绿
GREEN_DARK = (52, 78, 48)
SOIL = (156, 118, 76)          # 赭石土


def paper(size, tone=0):
    """宣纸底：米黄 + 颗粒噪点 + 偶尔飞白墨点"""
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
    """水墨晕染：柔和半透明色块"""
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


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path)
    print("生成:", path)


# ---------- 草地（两种变体） ----------
for v in range(2):
    g = paper(32, tone=rng.randint(-4, 4))
    wash(g, GREEN, 48, 8, 7, 16)       # 石绿晕染 = 草色
    wash(g, (120, 140, 90), 26, 5, 4, 10)
    d = ImageDraw.Draw(g, "RGBA")
    # 草叶短笔触
    for _ in range(16):
        x, y = rng.randint(1, 30), rng.randint(1, 30)
        d.line([(x, y), (x + rng.randint(-1, 1), y - 2)],
               fill=GREEN_DARK + (rng.randint(60, 120),), width=1)
    save(g, f"ground_{v}.png")


# ---------- 农田 ----------
f = paper(32)
d = ImageDraw.Draw(f, "RGBA")
d.rectangle([0, 0, 31, 31], fill=SOIL + (90,))          # 土色底
for y in range(2, 32, 4):                                # 犁沟横纹
    d.line([(0, y), (31, y)], fill=(96, 70, 44, 70), width=1)
for y in range(4, 32, 4):                                # 沟间高光
    d.line([(0, y), (31, y)], fill=(206, 170, 118, 50), width=1)
f = f.filter(ImageFilter.GaussianBlur(0.4))
d = ImageDraw.Draw(f, "RGBA")
for _ in range(22):                                      # 禾苗成行
    x, y = rng.randint(1, 30), rng.randint(1, 30)
    d.line([(x, y), (x, y - 2)], fill=GREEN_DARK + (220,), width=1)
    d.point([(x - 1, y - 1)], fill=GREEN + (200,))
save(f, "farm.png")


# ---------- 民居（64 画布，宋式：灰瓦大屋顶 + 粉墙 + 隔扇门窗） ----------
S = 64
h = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(h)

# 地基阴影
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse([8, 50, 56, 60], fill=(60, 55, 45, 70))
shadow = shadow.filter(ImageFilter.GaussianBlur(3))
h = Image.alpha_composite(h, shadow)
d = ImageDraw.Draw(h)

# 墙体（粉墙）
d.rectangle([14, 34, 50, 52], fill=WALL)
d.rectangle([14, 34, 50, 52], outline=INK, width=1)

# 正脊与坡屋面（庑殿式大屋顶，出檐）
roof = [(6, 34), (20, 20), (44, 20), (58, 34)]  # 屋面梯形
d.polygon(roof, fill=ROOF)
d.line(roof + [roof[0]], fill=INK, width=1)
# 正脊
d.line([(20, 20), (44, 20)], fill=INK, width=2)
d.line([(21, 18), (43, 18)], fill=ROOF_DARK, width=1)
# 瓦垄（纵向弧线暗示）
for x in range(12, 54, 4):
    top_y = 20 + abs(x - 32) * 14 // 26
    d.line([(x, top_y + 1), (x - 2 if x < 32 else x + 2, 33)],
           fill=ROOF_DARK + (160,), width=1)
# 檐口线
d.line([(6, 34), (58, 34)], fill=INK, width=1)

# 门（居中，赭石，门钉两点）
d.rectangle([28, 40, 36, 52], fill=WOOD, outline=INK)
d.line([(32, 40), (32, 52)], fill=INK)
d.point([(30, 45), (34, 45)], fill=(220, 190, 120))

# 两侧窗（直棂窗）
for wx in (18, 42):
    d.rectangle([wx, 41, wx + 4, 47], fill=(210, 200, 180), outline=INK)
    d.line([(wx + 2, 41), (wx + 2, 47)], fill=INK)
    d.line([(wx, 44), (wx + 4, 44)], fill=INK)

save(h.resize((32, 32), Image.LANCZOS), "house.png")


# ---------- 松树（40x56，透明底，工笔画松） ----------
W, H = 40, 56
t = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(t)

# 干（屈曲墨线）
trunk = [(20, 54), (19, 44), (21, 36), (19, 28)]
d.line(trunk, fill=INK, width=3)
d.line([(20, 44), (12, 36)], fill=INK, width=2)   # 左枝
d.line([(20, 40), (28, 32)], fill=INK, width=2)   # 右枝

# 松针（石绿平涂层叠团簇，压扁椭圆显工笔意）
def cluster(cx, cy, rx, ry):
    pts = [(cx + int(rx * math.cos(a)), cy + int(ry * math.sin(a)))
           for a in [i * math.pi / 10 for i in range(20)]]
    d.polygon(pts, fill=GREEN + (235,))
    d.line(pts + [pts[0]], fill=INK, width=1)
    # 簇内针叶短笔
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


# ---------- 道路（土路贴地，被斜投影压成菱形） ----------
r = paper(32)
d = ImageDraw.Draw(r, "RGBA")
d.rectangle([0, 8, 31, 24], fill=(172, 152, 120, 120))   # 路面
for y in (8, 24):                                         # 路缘墨线
    d.line([(0, y), (31, y)], fill=INK + (70,), width=1)
for _ in range(12):                                       # 车辙碎石
    x, y = rng.randint(0, 31), rng.randint(9, 23)
    d.point([(x, y)], fill=(120, 102, 78, 160))
r = r.filter(ImageFilter.GaussianBlur(0.4))
save(r, "road.png")


# ---------- 行人（12x20 宋人装束立牌，透明底） ----------
VW, VH = 12, 20
v = Image.new("RGBA", (VW, VH), (0, 0, 0, 0))
d = ImageDraw.Draw(v)
ROBE = (96, 106, 126)   # 花青袍
# 袍身（梯形）
d.polygon([(6, 6), (3, 9), (2, 18), (10, 18), (9, 9)], fill=ROBE, outline=INK)
# 衣纹
d.line([(6, 9), (6, 17)], fill=INK + (120,), width=1)
# 头
d.ellipse([3, 0, 9, 6], fill=(224, 192, 158), outline=INK)
# 幞头（宋帽）
d.polygon([(3, 1), (9, 1), (8, 3), (4, 3)], fill=INK)
# 足
d.line([(4, 18), (4, 19)], fill=INK)
d.line([(8, 18), (8, 19)], fill=INK)
save(v, "villager.png")


# ---------- 磨坊（64 画布 -> 32：土墙茅顶 + 大水车） ----------
S = 64
m = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(m)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse([6, 48, 58, 58], fill=(60, 55, 45, 70))
m = Image.alpha_composite(m, shadow.filter(ImageFilter.GaussianBlur(3)))
d = ImageDraw.Draw(m)
d.rectangle([12, 30, 50, 50], fill=(238, 230, 210), outline=INK)      # 土墙
d.polygon([(4, 30), (20, 15), (42, 15), (58, 30)], fill=(136, 112, 82))  # 茅顶
d.line([(4, 30), (20, 15), (42, 15), (58, 30), (4, 30)], fill=INK)
d.line([(20, 15), (42, 15)], fill=INK, width=2)                       # 脊
d.rectangle([28, 38, 36, 50], fill=WOOD, outline=INK)                 # 门
# 水车
cx, cy, r = 49, 42, 11
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(150, 120, 90), outline=INK, width=2)
d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=INK)
for a in range(0, 360, 45):
    x2 = cx + int(r * 0.85 * math.cos(math.radians(a)))
    y2 = cy + int(r * 0.85 * math.sin(math.radians(a)))
    d.line([(cx, cy), (x2, y2)], fill=INK, width=1)
save(m.resize((32, 32), Image.LANCZOS), "mill.png")


# ---------- 市集（64 画布 -> 32：摊位 + 条纹布棚 + 酒旗） ----------
k = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(k)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse([6, 48, 58, 58], fill=(60, 55, 45, 70))
k = Image.alpha_composite(k, shadow.filter(ImageFilter.GaussianBlur(3)))
d = ImageDraw.Draw(k)
# 立柱
for px in (14, 46):
    d.line([(px, 24), (px, 44)], fill=INK, width=3)
# 布棚（条纹）
d.polygon([(8, 24), (52, 24), (48, 16), (12, 16)], fill=(238, 232, 220))
for sx in range(10, 52, 7):
    d.line([(sx, 16), (sx - 2, 24)], fill=(146, 94, 62), width=3)
d.line([(8, 24), (52, 24)], fill=INK, width=1)
# 柜台
d.rectangle([12, 40, 50, 47], fill=(168, 128, 88), outline=INK)
d.line([(12, 43), (50, 43)], fill=INK + (120,))
# 酒旗
d.line([(56, 46), (56, 12)], fill=INK, width=2)
d.polygon([(56, 12), (63, 14), (63, 30), (56, 28)], fill=(172, 62, 52))
d.line([(57, 18), (62, 19)], fill=(238, 232, 220))
d.line([(57, 23), (62, 24)], fill=(238, 232, 220))
save(k.resize((32, 32), Image.LANCZOS), "market.png")

print("全部完成 ->", os.path.abspath(OUT))
