class_name Minimap
extends Control
## 小地图：纯色块俯瞰整张网格（地绿/路灰/建筑蓝/民居土黄/农田金黄/大院棕金/树深绿/火灾红），
## 黄框为当前相机视野。每 0.5 秒刷新一次。
## 数据来源：世界状态读 GameState，视野框由 CameraRig 反算地面可视区域（阶段1 3D 版）。

var state: GameState
var camera_rig: CameraRig
var _accum := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(160, 120)
	size = Vector2(160, 120)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= 0.5:
		_accum = 0.0
		queue_redraw()


func _draw() -> void:
	if state == null or camera_rig == null:
		return
	var sx := size.x / GameState.GRID_W
	var sy := size.y / GameState.GRID_H

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.16, 0.2, 0.13))  # 地面

	for cell: Vector2i in state.trees:
		draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), Color(0.2, 0.42, 0.2))

	# 矿脉：铁矿青灰点 / 金矿土黄点（弱于建筑的 2/3 尺寸点）
	for cell: Vector2i in state.ores:
		var iron: bool = state.ores[cell]["type"] == "iron"
		var ocol := Color(0.42, 0.47, 0.55) if iron else Color(0.85, 0.7, 0.3)
		draw_rect(Rect2(cell.x * sx + sx * 0.17, cell.y * sy + sy * 0.17, sx * 0.66, sy * 0.66), ocol)

	for cell: Vector2i in state.buildings:
		if state.buildings[cell] == "road":
			draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), Color(0.55, 0.53, 0.5))

	for cell: Vector2i in state.buildings:
		var btype: String = state.buildings[cell]
		if btype == "road":
			continue
		var col := Color(0.35, 0.5, 0.75)  # 一般建筑：蓝
		if btype == "hut" or btype == "tilehouse":
			col = Color(0.72, 0.6, 0.42)  # 民居：土黄
		elif state.building_defs.get(btype, {}).has("crop"):
			col = Color(0.85, 0.75, 0.3)  # 作物田：金黄
		if state.burning.has(cell):
			col = Color(0.9, 0.25, 0.15)  # 火灾：红
		draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), col)

	for anchor: Vector2i in state.estates:
		var ecol := Color(0.85, 0.7, 0.3) if state.estates[anchor] == 3 else Color(0.68, 0.52, 0.3)
		draw_rect(Rect2(anchor.x * sx, anchor.y * sy, sx * 2, sy * 2), ecol)

	draw_rect(_view_rect(sx, sy), Color(1, 0.95, 0.6, 0.9), false, 1.0)


## 相机可视区域与地面的交点范围（格子坐标），画为小地图上的视野框
func _view_rect(sx: float, sy: float) -> Rect2:
	var r := camera_rig.get_ground_view_rect()
	if r.size == Vector2.ZERO:
		return Rect2()
	var x0 := clampf(r.position.x, 0.0, float(GameState.GRID_W))
	var y0 := clampf(r.position.y, 0.0, float(GameState.GRID_H))
	var x1 := clampf(r.position.x + r.size.x, 0.0, float(GameState.GRID_W))
	var y1 := clampf(r.position.y + r.size.y, 0.0, float(GameState.GRID_H))
	return Rect2(x0 * sx, y0 * sy, (x1 - x0) * sx, (y1 - y0) * sy)
