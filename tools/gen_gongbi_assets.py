# -*- coding: utf-8 -*-
"""v2 程序化生成工笔画风游戏贴图：3/4 俯视伪透视 + CELL 48 配套尺寸。
画法核心：盒体投影（前墙亮/侧墙暗/双坡瓦顶/落地影），参考凯撒大帝3/法老王。
锚点约定：所有立牌贴图底影椭圆中心 = (图宽/2, 图高-8)，main.gd 按此算偏移。
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
WALL = (244, 240, 230)         # 粉墙（受光面）
WALL_DARK = (206, 198, 182)    # 背光面
THATCH = (150, 124, 88)        # 茅
WOOD = (122, 86, 58)           # 赭石木
GREEN = (78, 108, 66)          # 石绿
GREEN_DARK = (52, 78, 48)
SOIL = (156, 118, 76)          # 赭石土
SHADOW = (60, 55, 45)          # 落地影


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path)
    print("生成:", name)


def shade(col, f):
    return tuple(max(0, min(255, int(c * f))) for c in col)


def canvas(w, h):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


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


def ground_shadow(img, cx, cy, rx, ry):
    """落地影：椭圆中心 (cx,cy) 即全贴图锚点"""
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=SHADOW + (70,))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(3)))


# ============================================================
# 盒体 3/4 建筑通用 painter
#   宽轴 W 水平向右，深轴 D 指向左上（后），可见面：前墙(亮)/右墙(暗)/双坡瓦顶
#   落地影椭圆中心固定 (Wc/2, Hc-16)，即全贴图锚点（main.gd 偏移公式依赖）
# ============================================================
def add(a, b):
    return (a[0] + b[0], a[1] + b[1])


def paint_roof(d, pt, w_px, h_px, gable, W, D, roof_col, thatch=False):
    """双坡瓦顶（屋脊沿宽轴）：大前坡(亮) + 脊后一条暗色后坡；瓦垄顺坡垂下"""
    over = 7  # 檐口出挑
    efl = (pt(0, 0, h_px)[0] - over * 0.6, pt(0, 0, h_px)[1] + over)
    efr = (pt(1, 0, h_px)[0] + over * 0.6, pt(1, 0, h_px)[1] + over)
    r0 = pt(0, 0.5, h_px + gable)   # 脊左端
    r1 = pt(1, 0.5, h_px + gable)   # 脊右端

    # 后坡：脊线上方一条窄带（纯装饰性，固定宽度，不再用几何进深）
    off = (-w_px * 0.10, -max(9, gable * 0.26))
    d.polygon([r0, r1, (r1[0] + off[0], r1[1] + off[1]), (r0[0] + off[0], r0[1] + off[1])],
              fill=shade(roof_col, 0.72), outline=INK)
    # 前坡（正对观察者，受光最亮）
    d.polygon([efl, efr, r1, r0], fill=roof_col, outline=INK)
    # 瓦垄：脊 → 前檐，顺坡向下的竖线
    n = 6 if w_px > 150 else 5
    for i in range(1, n + 1):
        t = i / (n + 1)
        ax = r0[0] + (r1[0] - r0[0]) * t
        ay = r0[1] + (r1[1] - r0[1]) * t
        d.line([(ax, ay), (efl[0] + (efr[0] - efl[0]) * t, efl[1])],
               fill=shade(roof_col, 0.7) + (200,), width=2)
    if thatch:  # 茅草纹：斜向碎线
        for _ in range(26):
            t = rng.random()
            s = rng.random()
            p0 = (efl[0] + (r1[0] - efl[0]) * s * 0.5 + (efr[0] - efl[0]) * t * 0.5,
                  efl[1] + (r1[1] - efl[1]) * s * 0.5 + (efr[1] - efl[1]) * t * 0.5)
            d.line([p0, (p0[0] + 4, p0[1] + 6)], fill=(120, 98, 66, 150), width=2)
    # 正脊
    d.line([r0, r1], fill=INK, width=3)
    return ((r0[0] + r1[0]) / 2, (r0[1] + r1[1]) / 2)   # 脊中点（重檐锚点）


def door_and_windows(d, pt, h_px, door="c", win=True, two_story=False):
    """门/窗画在前墙上；door: c 居中 / l 左 / r 右 / None 背面（双窗）"""
    fbl, fbr = pt(0, 0), pt(1, 0)
    w_px = fbr[0] - fbl[0]
    base_y = fbl[1]
    dw, dh = max(18, int(w_px * 0.16)), max(26, int(h_px * 0.36))
    ww, wh = max(12, int(w_px * 0.09)), max(12, int(h_px * 0.20))

    def fx(t):
        return fbl[0] + w_px * t

    def win_at(wx, wy):
        d.rectangle([wx, wy - wh, wx + ww, wy], fill=(210, 200, 180), outline=INK)
        d.line([(wx + ww // 2, wy - wh), (wx + ww // 2, wy)], fill=INK)
        d.line([(wx, wy - wh // 2), (wx + ww, wy - wh // 2)], fill=INK)

    if door is None:  # 背面：两窗
        win_at(fx(0.16), base_y - 6)
        win_at(fx(0.64), base_y - 6)
        return
    dx = {"c": 0.44, "l": 0.14, "r": 0.60}[door]
    d.rectangle([fx(dx), base_y - dh, fx(dx) + dw, base_y], fill=WOOD, outline=INK)
    d.line([(fx(dx) + dw // 2, base_y - dh), (fx(dx) + dw // 2, base_y)], fill=INK)
    if two_story:
        win_at(fx(0.14), base_y - h_px * 0.60)
        win_at(fx(0.66), base_y - h_px * 0.60)
    elif win:
        wx = 0.64 if door in ("c", "l") else 0.14
        win_at(fx(wx), base_y - 6)


def chimney(d, pt, h_px, u=0.86, v=0.9, col=(150, 96, 78)):
    """屋角小烟囱（冒烟建筑），返回烟口画布坐标"""
    x, y = pt(u, v, h_px + 6)
    d.rectangle([x - 6, y - 26, x + 6, y], fill=col, outline=INK)
    d.rectangle([x - 8, y - 30, x + 8, y - 24], fill=shade(col, 0.8), outline=INK)
    return (x, y - 30)


def compose_building(w_px=130, h_px=76, gable=46, two_story=False,
                     wall=WALL, roof_col=ROOF, thatch=False, door="c",
                     props=None, size=(192, 192), out=96, flip=False,
                     win=True):
    """1 格立牌建筑完整绘制，输出 size[0]/2 x size[1]/2"""
    Wc, Hc = size
    img = canvas(Wc, Hc)
    dr = ImageDraw.Draw(img)
    ground_shadow(img, Wc / 2, Hc - 16, w_px * 0.62, 24)
    # 盒体轴：宽轴水平，深轴指向左上；贴图右移为深度留左侧空间
    Wv = (w_px, 0)
    Dv = (-w_px * 0.28, -w_px * 0.21)
    P = (Wc / 2 - w_px / 2 + w_px * 0.14, Hc - 24)

    def pt(u, v, z=0.0):
        return (P[0] + Wv[0] * u + Dv[0] * v, P[1] + Wv[1] * u + Dv[1] * v - z)

    fl, fr = pt(0, 0), pt(1, 0)
    ftl, ftr = pt(0, 0, h_px), pt(1, 0, h_px)
    br, btr = pt(1, 1), pt(1, 1, h_px)
    dr.polygon([fr, br, btr, ftr], fill=WALL_DARK, outline=INK)   # 右墙暗面
    dr.polygon([fl, fr, ftr, ftl], fill=wall, outline=INK)        # 前墙亮面
    # 木质墙板纹理（伐木屋类由 wall 色区分，此处略）
    if two_story:  # 二层：前墙加腰檐
        mid = pt(0, 0, h_px * 0.55)
        mid2 = pt(1, 0, h_px * 0.55)
        dr.line([mid, mid2], fill=INK + (160,), width=2)
    paint_roof(dr, pt, w_px, h_px, gable, Wv, Dv, roof_col, thatch)
    door_and_windows(dr, pt, h_px, door, win=win, two_story=two_story)
    smoke_spout = None
    if props:
        smoke_spout = props(dr, pt, h_px)
    if flip:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    img = img.resize((out, out), Image.LANCZOS)
    return img, smoke_spout


# ---------- 各建筑类型点缀（props: 在盒体上画识别物，返回烟囱烟口或 None） ----------

def props_none(dr, pt, h):
    return None


def props_jar_flag(color=(146, 74, 56)):
    def f(dr, pt, h):
        fbl = pt(0, 0)
        w_px = pt(1, 0)[0] - fbl[0]
        jx = fbl[0] + w_px * 0.78
        jy = fbl[1]
        dr.ellipse([jx, jy - 20, jx + 22, jy], fill=color, outline=INK)      # 酒坛
        dr.ellipse([jx + 6, jy - 26, jx + 16, jy - 16], fill=shade(color, 1.2), outline=INK)
        fx = fbl[0] + w_px * 0.06
        dr.line([(fx, jy), (fx, jy - h - 34)], fill=INK, width=3)             # 酒旗
        dr.polygon([(fx, jy - h - 34), (fx + 26, jy - h - 30), (fx + 26, jy - h - 12), (fx, jy - h - 16)],
                   fill=(172, 62, 52), outline=INK)
        return chimney(dr, pt, h)
    return f


def props_oilpress(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    px = fbl[0] + w_px * 0.80
    py = fbl[1]
    dr.line([(px, py), (px, py - h * 0.62)], fill=INK, width=4)               # 榨油架
    dr.line([(px, py - h * 0.62), (px + 20, py - h * 0.62)], fill=INK, width=4)
    dr.line([(px + 20, py - h * 0.62), (px + 20, py - h * 0.38)], fill=INK, width=3)
    dr.ellipse([px + 10, py - h * 0.30, px + 26, py - h * 0.06], fill=(120, 96, 54), outline=INK)
    return chimney(dr, pt, h, u=0.12)


def props_loom(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    rx = fbl[0] + w_px * 0.74
    ry = fbl[1]
    dr.line([(rx, ry), (rx, ry - h * 0.7)], fill=INK, width=3)                # 布架
    dr.line([(rx + 22, ry), (rx + 22, ry - h * 0.7)], fill=INK, width=3)
    dr.rectangle([rx + 2, ry - h * 0.66, rx + 10, ry - h * 0.2], fill=(172, 62, 52), outline=INK)
    dr.rectangle([rx + 12, ry - h * 0.66, rx + 20, ry - h * 0.2], fill=(96, 108, 122), outline=INK)
    return None


def props_stall(sacks=True):
    def f(dr, pt, h):
        fbl = pt(0, 0)
        w_px = pt(1, 0)[0] - fbl[0]
        ax = fbl[0] + w_px * 0.10
        ay = fbl[1]
        dr.line([(ax, ay), (ax, ay - h * 0.5)], fill=INK, width=3)            # 摊篷
        dr.line([(ax + 30, ay), (ax + 30, ay - h * 0.5)], fill=INK, width=3)
        dr.polygon([(ax - 4, ay - h * 0.5), (ax + 34, ay - h * 0.5),
                    (ax + 30, ay - h * 0.5 - 14), (ax, ay - h * 0.5 - 14)],
                   fill=(238, 232, 220), outline=INK)
        for sx in range(int(ax), int(ax + 30), 7):
            dr.line([(sx, ay - h * 0.5 - 14), (sx - 2, ay - h * 0.5)], fill=(146, 94, 62), width=3)
        if sacks:
            dr.ellipse([ax - 12, ay - 16, ax + 4, ay], fill=(214, 196, 160), outline=INK)
            dr.ellipse([ax - 2, ay - 12, ax + 14, ay], fill=(196, 170, 128), outline=INK)
        return None
    return f


def props_restaurant(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    lx = fbl[0] + w_px * 0.06
    ly = fbl[1]
    dr.line([(lx, ly), (lx, ly - 18)], fill=INK, width=2)                     # 灯笼
    dr.ellipse([lx - 7, ly - 18, lx + 7, ly - 4], fill=(196, 84, 60), outline=INK)
    fx = fbl[0] + w_px * 0.5
    fy = pt(0.5, 0, h)[1]
    dr.line([(fx, fy + 8), (fx, fy - 26)], fill=INK, width=2)                 # 屋顶酒旗
    dr.polygon([(fx, fy - 26), (fx + 30, fy - 22), (fx + 30, fy - 6), (fx, fy - 10)],
               fill=(172, 62, 52), outline=INK)
    return chimney(dr, pt, h, u=0.88)


def props_lantern(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    lx = fbl[0] + w_px * 0.10
    ly = fbl[1]
    dr.line([(lx, ly), (lx, ly - 20)], fill=INK, width=2)
    dr.ellipse([lx - 7, ly - 20, lx + 7, ly - 4], fill=(196, 84, 60), outline=INK)
    return None


def props_woodpile(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    px = fbl[0] + w_px * 0.76
    py = fbl[1]
    for i, ly in enumerate((py - 6, py - 16, py - 26)):                        # 柴堆
        dr.rounded_rectangle([px, ly - 8, px + 26, ly], 3, fill=(150, 116, 78), outline=INK)
        dr.ellipse([px + 18, ly - 8, px + 26, ly], fill=(196, 164, 116), outline=INK)
    return None


def props_well(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    cx = fbl[0] + w_px * 0.30
    cy = fbl[1]
    dr.ellipse([cx - 20, cy - 14, cx + 20, cy + 2], fill=(170, 164, 150), outline=INK)  # 井台
    dr.ellipse([cx - 13, cy - 10, cx + 13, cy - 2], fill=(40, 44, 52), outline=INK)
    dr.line([(cx - 16, cy - 12), (cx - 16, cy - h * 0.75)], fill=WOOD, width=4)          # 轱辘架
    dr.line([(cx + 16, cy - 12), (cx + 16, cy - h * 0.75)], fill=WOOD, width=4)
    dr.line([(cx - 20, cy - h * 0.75), (cx + 20, cy - h * 0.75)], fill=WOOD, width=4)
    dr.line([(cx, cy - h * 0.75), (cx, cy - 22)], fill=INK, width=2)
    dr.rectangle([cx - 5, cy - 22, cx + 5, cy - 12], fill=(150, 116, 78), outline=INK)   # 水桶
    return None


def props_clinic(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    fx = fbl[0] + w_px * 0.08
    fy = fbl[1]
    dr.line([(fx, fy), (fx, fy - h - 30)], fill=INK, width=3)                 # 药幌杆
    dr.polygon([(fx, fy - h - 30), (fx + 22, fy - h - 26), (fx + 22, fy - h - 6), (fx, fy - h - 10)],
               fill=(238, 232, 220), outline=INK)
    dr.line([(fx + 6, fy - h - 22), (fx + 16, fy - h - 20)], fill=(172, 62, 52), width=4)
    dr.line([(fx + 6, fy - h - 14), (fx + 16, fy - h - 12)], fill=(172, 62, 52), width=4)
    return None


def props_repair(dr, pt, h):
    fbl = pt(0, 0)
    w_px = pt(1, 0)[0] - fbl[0]
    rx = fbl[0] + w_px * 0.72
    ry = fbl[1]
    dr.line([(rx, ry), (rx, ry - h * 0.55)], fill=INK, width=3)               # 工具架
    dr.line([(rx + 24, ry), (rx + 24, ry - h * 0.55)], fill=INK, width=3)
    dr.line([(rx - 2, ry - h * 0.55), (rx + 26, ry - h * 0.55)], fill=INK, width=3)
    dr.line([(rx + 5, ry - h * 0.55), (rx + 3, ry - h * 0.2)], fill=WOOD, width=3)       # 锯
    dr.line([(rx + 14, ry - h * 0.55), (rx + 16, ry - h * 0.18)], fill=INK, width=3)     # 锤
    dr.rectangle([rx + 12, ry - h * 0.24, rx + 20, ry - h * 0.14], fill=(120, 128, 138), outline=INK)
    return None


# ---------- 1 格立牌建筑生成（d0 正门 / d1 门右 / d2 背 / d3 门左 = d1 镜像） ----------

def emit_building(base, spec):
    for i, door in enumerate(["c", "r", None, "l"]):
        img, _ = compose_building(door=(None if door is None else ("r" if door == "r" else "c")),
                                  flip=(door == "l"), **spec)
        save(img, f"{base}_d{i}.png")


SPECS = {
    "hut": dict(thatch=True, roof_col=THATCH, h_px=70, gable=38),
    "house": dict(two_story=True, h_px=88, gable=48),
    "mill": dict(h_px=80, gable=48, props=props_jar_flag()),
    "market": dict(props=props_stall(sacks=False)),
    "grocer": dict(props=props_stall(sacks=True)),
    "winery": dict(props=props_jar_flag(color=(120, 96, 54))),
    "oilpress": dict(thatch=True, roof_col=THATCH, props=props_oilpress),
    "loom": dict(props=props_loom),
    "woodcutter": dict(thatch=True, roof_col=THATCH, wall=(196, 158, 116), props=props_woodpile),
    "restaurant": dict(two_story=True, h_px=92, gable=46, props=props_restaurant),
    "clinic": dict(props=props_clinic),
    "repair": dict(props=props_repair),
}

for base, spec in SPECS.items():
    emit_building(base, spec)

# 水井（无方向单张）
well_img, _ = compose_building(wall=WALL, props=props_well)
save(well_img, "well.png")


# ---------- 大宅（2x2，144x120，锚点影中心=(144,112)） ----------

def paint_estate(tier):
    Wc, Hc = 288, 240
    w_px, h_px, gable = 200, 92, 62
    img = canvas(Wc, Hc)
    dr = ImageDraw.Draw(img)
    ground_shadow(img, Wc / 2, Hc - 16, w_px * 0.60, 26)
    Wv = (w_px, 0)
    Dv = (-w_px * 0.28, -w_px * 0.21)
    P = (Wc / 2 - w_px / 2 + w_px * 0.14, Hc - 24)

    def pt(u, v, z=0.0):
        return (P[0] + Wv[0] * u + Dv[0] * v, P[1] + Wv[1] * u + Dv[1] * v - z)

    fl, fr = pt(0, 0), pt(1, 0)
    ftl, ftr = pt(0, 0, h_px), pt(1, 0, h_px)
    br, btr = pt(1, 1), pt(1, 1, h_px)
    dr.polygon([fr, br, btr, ftr], fill=WALL_DARK, outline=INK)
    dr.polygon([fl, fr, ftr, ftl], fill=WALL, outline=INK)
    # 前围墙（矮墙，带门洞）
    wy = pt(0, 0)[1]
    wall_h = 26
    gx0, gx1 = pt(0.42, 0)[0], pt(0.58, 0)[0]
    dr.rectangle([fl[0], wy - wall_h, gx0, wy], fill=WALL_DARK, outline=INK)
    dr.rectangle([gx1, wy - wall_h, fr[0], wy], fill=WALL_DARK, outline=INK)
    dr.line([(fl[0], wy - wall_h), (fr[0], wy - wall_h)], fill=ROOF_DARK, width=4)
    # 门楼小顶
    dr.polygon([(gx0 - 6, wy - wall_h), (gx1 + 6, wy - wall_h),
                (gx1 + 2, wy - wall_h - 16), (gx0 + 2, wy - wall_h - 16)], fill=ROOF, outline=INK)
    apex = paint_roof(dr, pt, w_px, h_px, gable, Wv, Dv, ROOF)
    if tier == 3:  # 重檐：正脊上方再加一层小顶
        a = apex
        dr.polygon([(a[0] - 34, a[1] + 14), (a[0] + 34, a[1] + 14),
                    (a[0] + 22, a[1] - 14), (a[0] - 22, a[1] - 14)], fill=ROOF_DARK, outline=INK)
        dr.line([(a[0] - 22, a[1] - 14), (a[0] + 22, a[1] - 14)], fill=INK, width=3)
        for t in (-20, -8, 6, 18):
            dr.line([(a[0] + t, a[1] + 12), (a[0] + int(t * 0.6), a[1] - 12)],
                    fill=shade(ROOF_DARK, 0.7) + (200,), width=2)
        # 门前花木
        for tx in (fl[0] + 8, fr[0] - 24):
            dr.ellipse([tx, wy - 18, tx + 16, wy - 2], fill=GREEN + (220,), outline=INK)
    # 正房门窗（前墙在围墙后上方）
    door_and_windows(dr, pt, h_px, "c", two_story=False)
    img = img.resize((144, 120), Image.LANCZOS)
    return img


for tier in (2, 3):
    for i, flip in enumerate([False, True, False, True]):
        img = paint_estate(tier)
        if flip:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)
        save(img, f"estate{tier}_d{i}.png")


# ---------- 地面 / 道路 / 作物田（48x48） ----------

for v in range(2):
    g = paper(48, tone=rng.randint(-4, 4))
    d = ImageDraw.Draw(g, "RGBA")
    for _ in range(30):
        x, y = rng.randint(1, 46), rng.randint(1, 46)
        d.line([(x, y), (x + rng.randint(-1, 1), y - 3)], fill=GREEN_DARK + (rng.randint(60, 120),), width=1)
    for _ in range(10):
        x, y = rng.randint(2, 44), rng.randint(2, 44)
        d.ellipse([x, y, x + rng.randint(2, 5), y + rng.randint(1, 3)], fill=GREEN + (rng.randint(30, 60),))
    save(g.convert("RGBA"), f"ground_{v}.png")


def paint_road_tile(conns):
    size = 48
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    c = size // 2
    w0, w1 = 15, 33
    if not conns:
        md.ellipse([13, 13, 35, 35], fill=255)
    else:
        for conn in conns:
            if conn == "e":
                md.rectangle([c, w0, size, w1], fill=255)
            elif conn == "w":
                md.rectangle([0, w0, c, w1], fill=255)
            elif conn == "s":
                md.rectangle([w0, c, w1, size], fill=255)
            elif conn == "n":
                md.rectangle([w0, 0, w1, c], fill=255)
        if len(conns) == 1:
            md.ellipse([12, 12, 36, 36], fill=255)
    edge_mask = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(3)))
    img = canvas(size, size)
    dirt = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dirt.paste(Image.new("RGBA", (size, size), (188, 168, 134, 255)), (0, 0), mask)
    dd = ImageDraw.Draw(dirt)
    for _ in range(26):
        x, y = rng.randint(2, 45), rng.randint(2, 45)
        if mask.getpixel((x, y)):
            dd.point([(x, y)], fill=(120, 102, 78, rng.randint(90, 160)))
            if rng.random() < 0.4:
                dd.point([(x + 1, y)], fill=(214, 196, 160, 140))
    img = Image.alpha_composite(img, dirt)
    edge = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    edge.paste(Image.new("RGBA", (size, size), (120, 102, 78, 200)), (0, 0), edge_mask)
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


def paint_field(kind):
    size = 48
    img = paper(size)
    d = ImageDraw.Draw(img, "RGBA")
    d.rectangle([0, 0, size - 1, size - 1], fill=SOIL + (110,))
    for y in range(3, size, 6):
        d.line([(0, y), (size - 1, y)], fill=(96, 70, 44, 80), width=1)
    for y in range(6, size, 6):
        d.line([(0, y), (size - 1, y)], fill=(206, 170, 118, 60), width=1)
    img = img.filter(ImageFilter.GaussianBlur(0.5))
    d = ImageDraw.Draw(img, "RGBA")
    if kind == "farm":  # 水稻：绿秧成行
        for y in range(4, size, 6):
            for x in range(2, size, 4):
                d.line([(x, y), (x, y - 3)], fill=GREEN + (230,), width=1)
                d.point([(x - 1, y - 2)], fill=GREEN_DARK + (220,))
    elif kind == "wheat":
        for _ in range(52):
            x, y = rng.randint(2, size - 3), rng.randint(2, size - 3)
            d.line([(x, y), (x + rng.randint(-1, 1), y - 4)], fill=(214, 178, 90, 230), width=1)
            d.point([(x, y - 4)], fill=(236, 206, 128, 240))
    elif kind == "cotton":
        for _ in range(28):
            x, y = rng.randint(3, size - 4), rng.randint(3, size - 4)
            d.line([(x, y), (x, y - 3)], fill=GREEN_DARK + (220,), width=1)
            d.ellipse([x - 3, y - 7, x + 3, y - 1], fill=(238, 236, 226, 235), outline=INK)
    elif kind == "soy":
        for _ in range(40):
            x, y = rng.randint(2, size - 3), rng.randint(2, size - 3)
            d.line([(x, y), (x, y - 3)], fill=GREEN + (220,), width=1)
            d.point([(x - 1, y - 1)], fill=(206, 198, 110, 240))
            d.point([(x + 1, y)], fill=(188, 182, 96, 220))
    elif kind == "grape":
        for _ in range(22):
            x, y = rng.randint(3, size - 4), rng.randint(3, size - 4)
            d.line([(x, y), (x, y - 4)], fill=GREEN_DARK + (230,), width=1)
            d.ellipse([x - 1, y - 3, x + 4, y + 1], fill=(96, 62, 108, 235), outline=INK)
    return img.convert("RGBA")


for kind in ("farm", "wheat", "cotton", "soy", "grape"):
    save(paint_field(kind), f"{kind}.png")


# ---------- 树（60x84）与行人（18x30） ----------

def cluster(d, cx, cy, rx, ry):
    pts = [(cx + int(rx * math.cos(a)), cy + int(ry * math.sin(a)))
           for a in [j * math.pi / 10 for j in range(20)]]
    d.polygon(pts, fill=GREEN + (235,))
    d.line(pts + [pts[0]], fill=INK, width=1)
    for _ in range(6):
        a = rng.uniform(0, math.pi * 2)
        x = cx + int(rx * 0.6 * math.cos(a))
        y = cy + int(ry * 0.6 * math.sin(a))
        d.line([(x, y), (x + 3, y - 2)], fill=GREEN_DARK + (220,), width=1)


t = canvas(60, 84)
d = ImageDraw.Draw(t)
ground_shadow(t, 30, 80, 22, 6)
d.line([(30, 80), (28, 62), (31, 50), (28, 38)], fill=INK, width=4)
d.line([(29, 64), (18, 52)], fill=INK, width=3)
d.line([(30, 58), (42, 46)], fill=INK, width=3)
cluster(d, 30, 16, 19, 9)
cluster(d, 30, 27, 22, 9)
cluster(d, 15, 32, 10, 6)
cluster(d, 45, 31, 10, 6)
save(t, "tree.png")

v = canvas(18, 30)
d = ImageDraw.Draw(v)
ROBE = (96, 106, 126)
d.polygon([(9, 9), (4, 13), (3, 27), (15, 27), (14, 13)], fill=ROBE, outline=INK)
d.line([(9, 13), (9, 26)], fill=INK + (120,), width=1)
d.ellipse([4, 0, 14, 10], fill=(224, 192, 158), outline=INK)
d.polygon([(4, 1), (14, 1), (12, 4), (6, 4)], fill=INK)
d.line([(6, 27), (6, 29)], fill=INK)
d.line([(12, 27), (12, 29)], fill=INK)
save(v, "villager.png")


# ---------- 尺寸校验 ----------
SPEC = {"ground_0.png": (48, 48), "ground_1.png": (48, 48), "tree.png": (60, 84),
        "villager.png": (18, 30), "well.png": (96, 96),
        "farm.png": (48, 48), "wheat.png": (48, 48), "cotton.png": (48, 48),
        "soy.png": (48, 48), "grape.png": (48, 48)}
for i in range(4):
    for base in ("hut", "house", "mill", "market", "grocer", "winery", "oilpress",
                 "loom", "woodcutter", "restaurant", "clinic", "repair"):
        SPEC[f"{base}_d{i}.png"] = (96, 96)
    for tier in (2, 3):
        SPEC[f"estate{tier}_d{i}.png"] = (144, 120)
for name in ROAD_VARIANTS:
    SPEC[f"road_{name}.png"] = (48, 48)

bad = []
for fname, want in SPEC.items():
    p = os.path.join(OUT, fname)
    if not os.path.exists(p):
        bad.append(f"{fname} 缺失")
        continue
    got = Image.open(p).size
    if got != want:
        bad.append(f"{fname} = {got} 应为 {want}")
if bad:
    for b in bad:
        print("尺寸错误:", b)
    raise SystemExit(1)
print(f"SIZE CHECK OK ({len(SPEC)} 个文件)")
print("全部完成 ->", os.path.abspath(OUT))
