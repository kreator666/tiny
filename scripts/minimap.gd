class_name Minimap
extends Control
## 小地图：纯色块俯瞰整张网格（地绿/路灰/建筑蓝/民居土黄/农田金黄/大院棕金/树深绿/火灾红），
## 黄框为当前相机视野。每 0.5 秒刷新一次。

var main: Main
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
	if main == null:
		return
	var sx := size.x / Main.GRID_W
	var sy := size.y / Main.GRID_H

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.16, 0.2, 0.13))  # 地面

	for cell: Vector2i in main.trees:
		draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), Color(0.2, 0.42, 0.2))

	for cell: Vector2i in main.buildings:
		if main.buildings[cell] == "road":
			draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), Color(0.55, 0.53, 0.5))

	for cell: Vector2i in main.buildings:
		var btype: String = main.buildings[cell]
		if btype == "road":
			continue
		var col := Color(0.35, 0.5, 0.75)  # 一般建筑：蓝
		if btype == "hut" or btype == "tilehouse":
			col = Color(0.72, 0.6, 0.42)  # 民居：土黄
		elif float(main.building_defs.get(btype, {}).get("grain_per_month", 0.0)) > 0.0:
			col = Color(0.85, 0.75, 0.3)  # 农田：金黄
		if main.burning.has(cell):
			col = Color(0.9, 0.25, 0.15)  # 火灾：红
		draw_rect(Rect2(cell.x * sx, cell.y * sy, sx, sy), col)

	for anchor: Vector2i in main.estates:
		var ecol := Color(0.85, 0.7, 0.3) if main.estates[anchor] == 3 else Color(0.68, 0.52, 0.3)
		draw_rect(Rect2(anchor.x * sx, anchor.y * sy, sx * 2, sy * 2), ecol)

	draw_rect(_view_rect(sx, sy), Color(1, 0.95, 0.6, 0.9), false, 1.0)


## 相机视野对应的格子范围（世界坐标逆投影回格子）
func _view_rect(sx: float, sy: float) -> Rect2:
	var vp := main.get_viewport_rect().size
	var half := vp / (2.0 * main._zoom.x)
	var inv := main._proj().affine_inverse()
	var tl: Vector2 = inv * (main._cam_pos - half)
	var br: Vector2 = inv * (main._cam_pos + half)
	var c0 := (tl - Main.MAP_ORIGIN) / Main.CELL
	var c1 := (br - Main.MAP_ORIGIN) / Main.CELL
	var x0 := clampf(minf(c0.x, c1.x), 0.0, float(Main.GRID_W))
	var y0 := clampf(minf(c0.y, c1.y), 0.0, float(Main.GRID_H))
	var x1 := clampf(maxf(c0.x, c1.x), 0.0, float(Main.GRID_W))
	var y1 := clampf(maxf(c0.y, c1.y), 0.0, float(Main.GRID_H))
	return Rect2(x0 * sx, y0 * sy, (x1 - x0) * sx, (y1 - y0) * sy)
