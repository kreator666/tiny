#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""3D 建筑低模参数生成（阶段2，路线 B 运行时程序生成的配套工具）。

本环境无 trimesh/pygltflib 等 GLB 导出依赖，故 3D 建筑采用**运行时程序生成**：
WorldRenderer3D 通过 BuildingMeshFactory 用 ArrayMesh 拼"盒体+坡屋顶+基座"，
侧面 UV 采样原 billboard 贴图区带（见 building_mesh_factory.gd 的 UV_ROOF/UV_BODY/UV_BASE）。

本脚本职责：
1. 校验 data/buildings.json 每种建筑都有 mesh_size（[宽, 高, 深]，单位：格）；
2. 把造型参数表（屋顶形式/墙身占比/立面贴图分派 tex_roof/tex_wall/tex_base）写到 data/building_meshes.json，
   供渲染层覆盖工厂内置默认值（缺省不生成该文件也能跑）。

用法: python tools/gen_3d_buildings.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILDINGS = ROOT / "data" / "buildings.json"
OUT = ROOT / "data" / "building_meshes.json"

# 造型参数：roof=gable 双坡屋顶棱柱 / flat 平顶压檐；body_frac=墙身占(总高-基座)的比例
F = "facade/"
PARAMS = {
    "hut":        {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_thatch.png", "tex_wall": F+"wall_white.png", "tex_base": F+"base_stone.png"},
    "tilehouse":  {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_white.png", "tex_base": F+"base_stone.png"},
    "mill":       {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
    "grocer":     {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_white.png", "tex_base": F+"base_stone.png"},
    "market":     {"roof": "gable", "body_frac": 0.60,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
    "winery":     {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
    "oilpress":   {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_thatch.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
    "loom":       {"roof": "flat",  "body_frac": 0.85,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
    "restaurant": {"roof": "gable", "body_frac": 0.60,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_white.png", "tex_base": F+"base_stone.png"},
    "well":       {"roof": "gable", "body_frac": 0.50,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_white.png", "tex_base": F+"base_stone.png"},
    "clinic":     {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_gray.png", "tex_base": F+"base_stone.png"},
    "repair":     {"roof": "flat",  "body_frac": 0.85,
                   "tex_roof": F+"roof_tile.png", "tex_wall": F+"wall_gray.png", "tex_base": F+"base_stone.png"},
    "woodcutter": {"roof": "gable", "body_frac": 0.55,
                   "tex_roof": F+"roof_thatch.png", "tex_wall": F+"wall_wood.png", "tex_base": F+"base_stone.png"},
}


def main() -> None:
    defs = json.loads(BUILDINGS.read_text(encoding="utf-8"))
    missing = [k for k, d in defs.items() if "mesh_size" not in d]
    if missing:
        raise SystemExit(f"以下建筑缺少 mesh_size: {missing}")
    # 非 flat 建筑都应有造型参数；flat(贴地 tile) 不需要网格
    non_flat = [k for k, d in defs.items() if not d.get("flat")]
    no_param = [k for k in non_flat if k not in PARAMS]
    if no_param:
        raise SystemExit(f"以下非 flat 建筑缺少造型参数: {no_param}")
    OUT.write_text(
        json.dumps(PARAMS, ensure_ascii=False, indent="\t") + "\n", encoding="utf-8")
    print(f"OK: {len(defs)} 种建筑 mesh_size 齐备，造型参数已写入 {OUT.name}"
          f"（{len(PARAMS)} 种非 flat 建筑）")


if __name__ == "__main__":
    main()
