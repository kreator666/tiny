#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""3D 建筑低模参数生成（B+A 组合方案）：造型参数 + 体型(mesh_size) 的唯一数据源。

- 校验并把 mesh_size 回写进 data/buildings.json（[宽,高,深]，单位：格；flat 建筑也写但不用网格）
- 把造型参数表写入 data/building_meshes.json，供渲染层覆盖工厂内置默认值：
    roof_style: gable 双坡 / hip 四坡(歇山近似) / pyramid 攒尖 / thick_thatch 厚檐方锥 / flat 平顶
    body_frac:  墙身占(总高-基座)的比例
    tex_roof/tex_wall/tex_base: facade/ 下的正交立面贴图（共享 6 张 + 每建筑专属 *_wall.png）
    attachments: 功能附件（awning 布篷 / banner_pole 幌杆 / jars 坛堆 / chimney 烟囱 /
                 woodpile 柴堆 / plaque 牌匾 / well_ring 石栏圈 / rack 晾布杆）

运行时装配在 scripts/building_mesh_factory.gd（ArrayMesh 3 surface + 附件纳入同网格）。
用法: python tools/gen_3d_buildings.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILDINGS = ROOT / "data" / "buildings.json"
OUT = ROOT / "data" / "building_meshes.json"

F = "facade/"

# 体型差异化：mesh_size [宽, 高, 深]（格）；市集大开间矮顶、酒楼两层高、民居小巧、磨坊进深大
MESH_SIZE = {
    "hut": [1.0, 1.1, 1.0], "tilehouse": [1.0, 1.4, 1.1], "mill": [2.2, 2.4, 2.2],
    "grocer": [1.2, 1.5, 1.2], "market": [2.2, 1.4, 1.6], "winery": [1.5, 1.9, 1.5],
    "oilpress": [1.5, 1.9, 1.5], "loom": [1.5, 1.6, 1.3], "restaurant": [1.6, 2.4, 1.4],
    "well": [0.9, 1.1, 0.9], "clinic": [1.2, 1.6, 1.2], "repair": [1.3, 1.5, 1.3],
    "woodcutter": [1.5, 1.5, 1.5],
    # 矿产线：矿场（井架塔）/ 兵器坊（开敞棚+兵器架）/ 炼金坊（丹炉+高烟囱）
    "mine": [1.4, 1.5, 1.4], "weaponry": [1.5, 1.5, 1.4], "goldworks": [1.5, 1.6, 1.5],
    # flat（贴地 tile，不写网格，尺寸仅存档备用）
    "farm": [1, 0.35, 1], "wheat": [1, 0.35, 1], "cotton": [1, 0.35, 1],
    "soy": [1, 0.35, 1], "grape": [1, 0.35, 1], "road": [1, 0.05, 1],
}

# 造型参数：屋顶样式 / 墙身占比 / 立面贴图分派 / 功能附件
PARAMS = {
    "hut": {"roof_style": "gable", "body_frac": 0.50,
            "tex_roof": F+"roof_thatch.png", "tex_wall": F+"hut_wall.png", "tex_base": F+"base_stone.png",
            "attachments": []},
    "tilehouse": {"roof_style": "gable", "body_frac": 0.55,
                  "tex_roof": F+"roof_tile.png", "tex_wall": F+"tilehouse_wall.png", "tex_base": F+"base_stone.png",
                  "attachments": []},
    "mill": {"roof_style": "gable", "body_frac": 0.55,
             "tex_roof": F+"roof_tile.png", "tex_wall": F+"mill_wall.png", "tex_base": F+"base_stone.png",
             "attachments": []},
    "grocer": {"roof_style": "gable", "body_frac": 0.55,
               "tex_roof": F+"roof_tile.png", "tex_wall": F+"grocer_wall.png", "tex_base": F+"base_stone.png",
               "attachments": ["awning"]},
    "market": {"roof_style": "hip", "body_frac": 0.65,
               "tex_roof": F+"roof_tile.png", "tex_wall": F+"market_wall.png", "tex_base": F+"base_stone.png",
               "attachments": ["awning"]},
    "winery": {"roof_style": "gable", "body_frac": 0.55,
               "tex_roof": F+"roof_tile.png", "tex_wall": F+"winery_wall.png", "tex_base": F+"base_stone.png",
               "attachments": ["jars"]},
    "oilpress": {"roof_style": "thick_thatch", "body_frac": 0.50,
                 "tex_roof": F+"roof_thatch.png", "tex_wall": F+"oilpress_wall.png", "tex_base": F+"base_stone.png",
                 "attachments": ["chimney"]},
    "loom": {"roof_style": "flat", "body_frac": 0.85,
             "tex_roof": F+"roof_tile.png", "tex_wall": F+"loom_wall.png", "tex_base": F+"base_stone.png",
             "attachments": ["rack"]},
    "restaurant": {"roof_style": "gable", "body_frac": 0.70,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"restaurant_wall.png", "tex_base": F+"base_stone.png",
                   "attachments": ["banner_pole"]},
    "well": {"roof_style": "pyramid", "body_frac": 0.45,
             "tex_roof": F+"roof_tile.png", "tex_wall": F+"well_wall.png", "tex_base": F+"base_stone.png",
             "attachments": ["well_ring"]},
    "clinic": {"roof_style": "gable", "body_frac": 0.55,
               "tex_roof": F+"roof_tile.png", "tex_wall": F+"clinic_wall.png", "tex_base": F+"base_stone.png",
               "attachments": ["plaque"]},
    "repair": {"roof_style": "flat", "body_frac": 0.85,
               "tex_roof": F+"roof_tile.png", "tex_wall": F+"repair_wall.png", "tex_base": F+"base_stone.png",
               "attachments": ["woodpile"]},
    "woodcutter": {"roof_style": "thick_thatch", "body_frac": 0.55,
                   "tex_roof": F+"roof_thatch.png", "tex_wall": F+"woodcutter_wall.png", "tex_base": F+"base_stone.png",
                   "attachments": ["woodpile"]},
    "mine": {"roof_style": "gable", "body_frac": 0.5,
             "tex_roof": F+"roof_tile.png", "tex_wall": F+"mine_wall.png", "tex_base": F+"base_stone.png",
             "attachments": []},
    "weaponry": {"roof_style": "flat", "body_frac": 0.8,
                 "tex_roof": F+"roof_tile.png", "tex_wall": F+"weaponry_wall.png", "tex_base": F+"base_stone.png",
                 "attachments": []},
    "goldworks": {"roof_style": "gable", "body_frac": 0.5,
                  "tex_roof": F+"roof_tile.png", "tex_wall": F+"goldworks_wall.png", "tex_base": F+"base_stone.png",
                  "attachments": []},
}

# 按原画轮廓定制的部件蓝图（blueprint）：5~15 个部件拼出 billboard 原画结构，
# 解决"所有建筑都是盒体+坡顶、与原画看不出是同一种东西"的问题。
# 坐标约定：offset=[x, y底, z] —— x/z 为部件水平中心，y 为部件底面高；单位：格，
# 原点 = footprint 中心地面；front = +z（面向 d0 视角）。
# shape: box 盒体 / prism 双坡棱柱(屋脊沿X) / pyramid 四坡攒尖 / cylinder 竖直圆柱 /
#        ramp 楔形(后高前低，布篷/棚顶/料堆) / plane 竖直薄片(布幔/门/布匹)
# size: box/prism/pyramid/ramp 为 [x,y,z]；cylinder 为 [直径,高,任意]；plane 为 [宽,高,0]
# tex: "base"/"wall"/"roof" = 该建筑对应 facade 贴图；"facade/xxx.png" = 具体贴图名；null = 取色纯色
BLUEPRINT = {
    # 茅屋：低矮墙身 + 大四坡草顶（原画屋顶占剪影 6 成）
    "hut": [
        {"shape": "box", "size": [1.0, 0.06, 1.0], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.78, 0.42, 0.72], "offset": [0, 0.06, 0.02], "tex": "wall"},
        {"shape": "pyramid", "size": [1.0, 0.55, 0.95], "offset": [0, 0.48, 0], "tex": "roof"},
    ],
    # 瓦房：白墙 + 双坡瓦顶
    "tilehouse": [
        {"shape": "box", "size": [1.0, 0.08, 1.1], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.82, 0.88, 0.9], "offset": [0, 0.08, 0], "tex": "wall"},
        {"shape": "prism", "size": [1.0, 0.4, 1.06], "offset": [0, 0.96, 0], "tex": "roof"},
    ],
    # 磨坊：大进深正房 + 高坡顶 + 侧向门屋平台（水车为渲染层附加物，勿重复；
    # 轮轴件 tag=wheel_axle：渲染层据此推导水车轮心/朝向，挂在 +x 侧面、轮缘底部近地面）
    "mill": [
        {"shape": "box", "size": [2.2, 0.1, 2.2], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.8, 1.25, 1.9], "offset": [0, 0.1, -0.12], "tex": "wall"},
        {"shape": "prism", "size": [2.0, 0.5, 2.1], "offset": [0, 1.35, -0.05], "tex": "roof"},
        {"shape": "box", "size": [0.75, 0.65, 0.75], "offset": [0.6, 0.1, 0.6], "tex": "wall"},
        {"shape": "prism", "size": [0.9, 0.3, 0.95], "offset": [0.6, 0.75, 0.6], "tex": "roof"},
        {"shape": "box", "size": [1.4, 0.12, 0.6], "offset": [0, 0.02, 0.8], "tex": "base"},
        {"shape": "box", "size": [0.3, 0.08, 0.08], "offset": [0.95, 0.7, 0.35], "tex": None,
         "tag": "wheel_axle"},
    ],
    # 杂货铺：民居 + 斜挑布篷 + 门前柜台货箱
    "grocer": [
        {"shape": "box", "size": [1.2, 0.08, 1.2], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.92, 0.8, 0.9], "offset": [0, 0.08, -0.05], "tex": "wall"},
        {"shape": "prism", "size": [1.15, 0.32, 1.1], "offset": [0, 0.88, -0.05], "tex": "roof"},
        {"shape": "ramp", "size": [0.95, 0.25, 0.5], "offset": [0, 0.55, 0.32], "tex": None},
        {"shape": "box", "size": [0.7, 0.35, 0.28], "offset": [0, 0.08, 0.45], "tex": "wall"},
        {"shape": "box", "size": [0.35, 0.3, 0.35], "offset": [-0.4, 0.08, 0.25], "tex": None},
    ],
    # 市集：开敞摊棚 —— 后矮板+披檐、前高杆布篷、货案、挂旗杆（旗面是渲染层附加物）
    "market": [
        {"shape": "box", "size": [2.2, 0.08, 1.6], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [2.0, 0.62, 0.4], "offset": [0, 0.08, -0.5], "tex": "wall"},
        {"shape": "prism", "size": [2.1, 0.22, 0.7], "offset": [0, 0.7, -0.42], "tex": "roof"},
        {"shape": "plane", "size": [1.9, 0.45, 0], "offset": [0, 0.42, -0.28], "tex": None},
        {"shape": "box", "size": [0.05, 0.85, 0.05], "offset": [-0.8, 0.08, 0.45], "tex": None},
        {"shape": "box", "size": [0.05, 0.85, 0.05], "offset": [0.8, 0.08, 0.45], "tex": None},
        {"shape": "ramp", "size": [1.9, 0.18, 0.85], "offset": [0, 0.88, 0.3], "tex": None},
        {"shape": "box", "size": [1.7, 0.32, 0.45], "offset": [0, 0.08, 0.4], "tex": "wall"},
        {"shape": "box", "size": [0.05, 1.3, 0.05], "offset": [-0.5, 0.08, 0.55], "tex": None},
    ],
    # 酒坊：正房 + 门侧三酒坛
    "winery": [
        {"shape": "box", "size": [1.5, 0.08, 1.5], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.15, 1.1, 1.15], "offset": [0, 0.08, -0.08], "tex": "wall"},
        {"shape": "prism", "size": [1.4, 0.45, 1.35], "offset": [0, 1.18, -0.07], "tex": "roof"},
        {"shape": "cylinder", "size": [0.28, 0.34, 0.28], "offset": [0.42, 0.08, 0.5], "tex": None},
        {"shape": "cylinder", "size": [0.22, 0.27, 0.22], "offset": [0.62, 0.08, 0.45], "tex": None},
        {"shape": "cylinder", "size": [0.18, 0.22, 0.18], "offset": [0.53, 0.42, 0.48], "tex": None},
    ],
    # 油坊：厚顶正房 + 屋顶烟囱 + 门前榨油架（立柱+横梁+油楔）
    "oilpress": [
        {"shape": "box", "size": [1.5, 0.08, 1.5], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.15, 0.95, 1.1], "offset": [-0.05, 0.08, -0.05], "tex": "wall"},
        {"shape": "prism", "size": [1.35, 0.42, 1.3], "offset": [-0.05, 1.03, -0.05], "tex": "roof"},
        {"shape": "box", "size": [0.16, 0.55, 0.16], "offset": [0.45, 1.2, -0.35], "tex": None},
        {"shape": "box", "size": [0.07, 0.75, 0.07], "offset": [0.5, 0.08, 0.5], "tex": None},
        {"shape": "box", "size": [0.07, 0.07, 0.55], "offset": [0.5, 0.78, 0.3], "tex": None},
        {"shape": "ramp", "size": [0.3, 0.35, 0.35], "offset": [0.5, 0.08, 0.42], "tex": None},
    ],
    # 织布坊：平顶工坊 + 左侧晾布杆与两条布片
    "loom": [
        {"shape": "box", "size": [1.5, 0.08, 1.3], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.1, 0.85, 1.0], "offset": [0.12, 0.08, -0.05], "tex": "wall"},
        {"shape": "box", "size": [1.3, 0.08, 1.2], "offset": [0.05, 0.93, -0.05], "tex": "roof"},
        {"shape": "box", "size": [0.05, 0.8, 0.05], "offset": [-0.55, 0.08, 0.25], "tex": None},
        {"shape": "box", "size": [0.05, 0.8, 0.05], "offset": [-0.55, 0.08, -0.25], "tex": None},
        {"shape": "box", "size": [0.05, 0.05, 0.9], "offset": [-0.55, 0.88, 0], "tex": None},
        {"shape": "plane", "size": [0.4, 0.55, 0], "offset": [-0.55, 0.32, 0.15], "tex": None},
        {"shape": "plane", "size": [0.4, 0.45, 0], "offset": [-0.55, 0.38, -0.22], "tex": None},
    ],
    # 酒楼：两层楼阁（上层面窄于下层）+ 中层披檐 + 檐前幌杆（幌布是渲染层附加物）
    "restaurant": [
        {"shape": "box", "size": [1.6, 0.08, 1.4], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.45, 0.8, 1.25], "offset": [0, 0.08, 0], "tex": "wall"},
        {"shape": "prism", "size": [1.6, 0.16, 1.4], "offset": [0, 0.88, 0], "tex": "roof"},
        {"shape": "box", "size": [1.05, 0.6, 0.9], "offset": [0, 1.04, 0], "tex": "wall"},
        {"shape": "prism", "size": [1.25, 0.4, 1.05], "offset": [0, 1.64, 0], "tex": "roof"},
        {"shape": "box", "size": [0.5, 0.045, 0.045], "offset": [-0.55, 1.14, 0.62], "tex": None},
    ],
    # 水井：石栏圆井圈 + 双立柱 + 辘轳横杆 + 攒尖小顶棚，无墙身
    # 辘轳横杆 tag=well_axle：渲染层据此定位打水吊桶的绳/桶挂点
    "well": [
        {"shape": "box", "size": [0.9, 0.06, 0.9], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "cylinder", "size": [0.56, 0.2, 0.56], "offset": [0, 0.06, 0], "tex": "base"},
        {"shape": "box", "size": [0.06, 0.6, 0.06], "offset": [-0.26, 0.26, 0], "tex": None},
        {"shape": "box", "size": [0.06, 0.6, 0.06], "offset": [0.26, 0.26, 0], "tex": None},
        {"shape": "box", "size": [0.5, 0.05, 0.05], "offset": [0, 0.68, 0], "tex": None,
         "tag": "well_axle"},
        {"shape": "pyramid", "size": [0.8, 0.3, 0.8], "offset": [0, 0.86, 0], "tex": "roof"},
    ],
    # 医馆：正房 + 门楣牌匾 + 门脸
    "clinic": [
        {"shape": "box", "size": [1.2, 0.08, 1.2], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.0, 0.9, 1.0], "offset": [0, 0.08, 0], "tex": "wall"},
        {"shape": "prism", "size": [1.2, 0.35, 1.15], "offset": [0, 0.98, 0], "tex": "roof"},
        {"shape": "box", "size": [0.42, 0.2, 0.06], "offset": [0, 0.78, 0.53], "tex": None},
        {"shape": "plane", "size": [0.3, 0.5, 0], "offset": [0, 0.08, 0.505], "tex": None},
    ],
    # 维修站：平顶工房 + 右侧工棚（柱+斜顶）+ 左侧木料堆
    "repair": [
        {"shape": "box", "size": [1.3, 0.08, 1.3], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.95, 0.75, 0.95], "offset": [-0.1, 0.08, -0.08], "tex": "wall"},
        {"shape": "box", "size": [1.1, 0.07, 1.1], "offset": [-0.1, 0.83, -0.08], "tex": "roof"},
        {"shape": "box", "size": [0.06, 0.7, 0.06], "offset": [0.42, 0.08, 0.42], "tex": None},
        {"shape": "box", "size": [0.06, 0.7, 0.06], "offset": [0.42, 0.08, -0.28], "tex": None},
        {"shape": "ramp", "size": [0.45, 0.12, 0.85], "offset": [0.4, 0.78, 0.08], "tex": None},
        {"shape": "ramp", "size": [0.55, 0.3, 0.45], "offset": [-0.35, 0.08, 0.38], "tex": None},
        {"shape": "ramp", "size": [0.45, 0.24, 0.4], "offset": [-0.38, 0.08, -0.2], "tex": None},
    ],
    # 矿场：井口石台 + 四柱井架塔 + 顶梁小披顶 + 矿车（铁矿石堆）
    "mine": [
        {"shape": "box", "size": [1.4, 0.08, 1.4], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.5, 0.14, 0.5], "offset": [0, 0.08, 0], "tex": "wall"},
        {"shape": "box", "size": [0.06, 0.85, 0.06], "offset": [-0.18, 0.22, -0.18], "tex": None},
        {"shape": "box", "size": [0.06, 0.85, 0.06], "offset": [0.18, 0.22, -0.18], "tex": None},
        {"shape": "box", "size": [0.06, 0.85, 0.06], "offset": [-0.18, 0.22, 0.18], "tex": None},
        {"shape": "box", "size": [0.06, 0.85, 0.06], "offset": [0.18, 0.22, 0.18], "tex": None},
        {"shape": "box", "size": [0.46, 0.06, 0.06], "offset": [0, 0.98, 0], "tex": None},
        {"shape": "box", "size": [0.06, 0.06, 0.46], "offset": [0, 0.86, 0], "tex": None},
        {"shape": "prism", "size": [0.5, 0.14, 0.5], "offset": [0, 1.04, 0], "tex": "roof"},
        {"shape": "box", "size": [0.34, 0.2, 0.24], "offset": [0.42, 0.08, 0.38], "tex": None},
        {"shape": "box", "size": [0.28, 0.09, 0.18], "offset": [0.42, 0.28, 0.38], "tex": None},
    ],
    # 兵器坊：开敞工棚（四柱+斜顶）+ 兵器架（双柱横杆+三杆兵器）+ 火炉（冒烟）
    "weaponry": [
        {"shape": "box", "size": [1.5, 0.08, 1.4], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.06, 0.8, 0.06], "offset": [-0.55, 0.08, -0.4], "tex": None},
        {"shape": "box", "size": [0.06, 0.8, 0.06], "offset": [0.55, 0.08, -0.4], "tex": None},
        {"shape": "box", "size": [0.06, 0.8, 0.06], "offset": [-0.55, 0.08, 0.4], "tex": None},
        {"shape": "box", "size": [0.06, 0.8, 0.06], "offset": [0.55, 0.08, 0.4], "tex": None},
        {"shape": "ramp", "size": [1.3, 0.14, 1.0], "offset": [0, 0.84, 0], "tex": "roof"},
        {"shape": "box", "size": [0.05, 0.7, 0.05], "offset": [-0.38, 0.08, 0.28], "tex": None},
        {"shape": "box", "size": [0.05, 0.7, 0.05], "offset": [0.08, 0.08, 0.28], "tex": None},
        {"shape": "box", "size": [0.75, 0.05, 0.05], "offset": [-0.15, 0.74, 0.28], "tex": None},
        {"shape": "box", "size": [0.03, 0.78, 0.03], "offset": [-0.32, 0.08, 0.28], "tex": None},
        {"shape": "box", "size": [0.03, 0.72, 0.03], "offset": [-0.15, 0.08, 0.28], "tex": None},
        {"shape": "box", "size": [0.03, 0.82, 0.03], "offset": [0.02, 0.08, 0.28], "tex": None},
        {"shape": "box", "size": [0.3, 0.35, 0.3], "offset": [0.45, 0.08, -0.3], "tex": "wall",
         "tag": "smoke"},
    ],
    # 炼金坊：石台 + 圆顶丹炉（炉体+炉肩+炉顶）+ 高烟囱（冒烟）+ 金鼎
    "goldworks": [
        {"shape": "box", "size": [1.5, 0.08, 1.5], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [0.9, 0.1, 0.9], "offset": [0, 0.02, 0], "tex": "base"},
        {"shape": "cylinder", "size": [0.7, 0.6, 0.7], "offset": [0, 0.12, 0], "tex": "wall"},
        {"shape": "cylinder", "size": [0.5, 0.2, 0.5], "offset": [0, 0.72, 0], "tex": "wall"},
        {"shape": "pyramid", "size": [0.55, 0.22, 0.55], "offset": [0, 0.92, 0], "tex": "roof"},
        {"shape": "box", "size": [0.16, 1.1, 0.16], "offset": [0.45, 0.08, -0.3], "tex": None,
         "tag": "smoke"},
        {"shape": "cylinder", "size": [0.2, 0.18, 0.2], "offset": [-0.4, 0.08, 0.35], "tex": None},
    ],
    # 伐木屋：偏右正房 + 四坡草顶 + 左侧柴堆 + 门前木墩
    "woodcutter": [
        {"shape": "box", "size": [1.5, 0.08, 1.5], "offset": [0, 0, 0], "tex": "base"},
        {"shape": "box", "size": [1.0, 0.8, 0.95], "offset": [0.18, 0.08, -0.08], "tex": "wall"},
        {"shape": "pyramid", "size": [1.45, 0.5, 1.4], "offset": [0, 0.88, -0.05], "tex": "roof"},
        {"shape": "ramp", "size": [0.6, 0.35, 0.5], "offset": [-0.42, 0.08, 0.3], "tex": None},
        {"shape": "ramp", "size": [0.5, 0.28, 0.42], "offset": [-0.45, 0.08, -0.2], "tex": None},
        {"shape": "cylinder", "size": [0.24, 0.22, 0.24], "offset": [0.35, 0.08, 0.5], "tex": None},
    ],
}

SHAPES = {"box", "prism", "pyramid", "cylinder", "ramp", "plane"}

# 冒烟建筑（同 2D 版名单：磨坊/酒坊/油坊有烟囱，民居与酒楼为厨房炊烟）。
# 出烟锚点不再用 2D 画布像素表，改为从 blueprint 推导：
#   有烟囱件（顶部最高的 box/cylinder 件突出屋顶）-> 取该件顶面中心；
#   无烟囱 -> 取最高屋顶件（prism 屋脊/pyramid 攒尖）顶面中心。
SMOKE_TYPES = ["mill", "winery", "hut", "tilehouse", "oilpress", "restaurant",
               "weaponry", "goldworks"]
ROOF_SHAPES = {"prism", "pyramid"}


def _smoke_anchor(btype: str) -> list:
    parts = BLUEPRINT[btype]
    # 显式 tag="smoke" 的件优先（如兵器坊火炉/炼金坊烟囱，低于棚顶但烟从这里出）；
    # 否则取最高件顶面中心（烟囱件 / 屋顶脊线）
    tagged = [p for p in parts if p.get("tag") == "smoke"]
    top_part = tagged[0] if tagged else max(parts, key=lambda p: p["offset"][1] + p["size"][1])
    top = top_part["offset"][1] + top_part["size"][1]
    return [top_part["offset"][0], top, top_part["offset"][2]]


def _validate_blueprints() -> None:
    for btype, parts in BLUEPRINT.items():
        w, _h, d = MESH_SIZE[btype]
        for i, p in enumerate(parts):
            if p["shape"] not in SHAPES:
                raise SystemExit(f"{btype}[{i}] 未知 shape: {p['shape']}")
            sx, sy, sz = p["size"]
            x, y, z = p["offset"]
            if abs(x) + sx / 2 > w / 2 + 1e-6 or abs(z) + sz / 2 > d / 2 + 1e-6:
                raise SystemExit(f"{btype}[{i}] 部件越出 footprint: {p}")
            if y < -1e-6 or y + sy < -1e-6:
                raise SystemExit(f"{btype}[{i}] 部件悬空/入地: {p}")
        if not 3 <= len(parts) <= 15:
            raise SystemExit(f"{btype} 部件数 {len(parts)} 超出 3~15 范围")
    # 磨坊水车：恰一个 wheel_axle 件（渲染层推导轮心/轮轴朝向用）
    axles = [p for p in BLUEPRINT["mill"] if p.get("tag") == "wheel_axle"]
    if len(axles) != 1:
        raise SystemExit(f"mill 必须恰有 1 个 wheel_axle 件，实际 {len(axles)}")
    # 冒烟 tag：若存在必须唯一（锚点推导优先用件）
    for btype, parts in BLUEPRINT.items():
        tagged = [p for p in parts if p.get("tag") == "smoke"]
        if len(tagged) > 1:
            raise SystemExit(f"{btype} smoke 件必须至多 1 个，实际 {len(tagged)}")
    # 水井打水：恰一个 well_axle 件（渲染层定位吊桶绳/桶挂点用）
    well_axles = [p for p in BLUEPRINT["well"] if p.get("tag") == "well_axle"]
    if len(well_axles) != 1:
        raise SystemExit(f"well 必须恰有 1 个 well_axle 件，实际 {len(well_axles)}")
    # 冒烟锚点可推导：有 smoke 件直接用；否则最高件须为屋顶形或突出屋顶的墙/柱形
    for btype in SMOKE_TYPES:
        tagged = [p for p in BLUEPRINT[btype] if p.get("tag") == "smoke"]
        if tagged:
            continue
        top_part = max(BLUEPRINT[btype], key=lambda p: p["offset"][1] + p["size"][1])
        if top_part["shape"] not in ROOF_SHAPES and top_part["shape"] not in {"box", "cylinder"}:
            raise SystemExit(f"{btype} 冒烟锚点无法从最高件推导: {top_part}")


def main() -> None:
    defs = json.loads(BUILDINGS.read_text(encoding="utf-8"))
    missing = [k for k in defs if k not in MESH_SIZE]
    if missing:
        raise SystemExit(f"以下建筑缺少 mesh_size 参数: {missing}")
    changed = False
    for k, d in defs.items():
        if d.get("mesh_size") != MESH_SIZE[k]:
            d["mesh_size"] = MESH_SIZE[k]
            changed = True
    if changed:
        BUILDINGS.write_text(json.dumps(defs, ensure_ascii=False, indent="\t") + "\n",
                             encoding="utf-8")
    non_flat = [k for k, d in defs.items() if not d.get("flat")]
    no_param = [k for k in non_flat if k not in PARAMS]
    if no_param:
        raise SystemExit(f"以下非 flat 建筑缺少造型参数: {no_param}")
    _validate_blueprints()
    out = {}
    for k, v in PARAMS.items():
        entry = dict(v, blueprint=BLUEPRINT[k])
        if k in SMOKE_TYPES:
            entry["smoke_anchor"] = _smoke_anchor(k)  # blueprint 推导的出烟点（建筑本地坐标）
        out[k] = entry
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print(f"OK: {len(defs)} 种建筑 mesh_size 已回写 building_meshes.json"
          f"（{len(PARAMS)} 种非 flat：屋顶变体/体型/专属贴图/附件/blueprint 部件蓝图"
          f"，{len(SMOKE_TYPES)} 种冒烟锚点，磨坊轮轴件）")


if __name__ == "__main__":
    main()
