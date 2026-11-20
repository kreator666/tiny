class_name CameraRig
extends Node3D
## 3D 轨道相机（阶段1）：Camera3D 挂在 rig 下，围绕地面目标点做球坐标轨道。
## 交互映射延续 2D 手感：
##   WASD/方向键、中键拖拽 -> 沿相机朝向的地面投影方向平移目标点
##   滚轮 -> 缩放（保持鼠标所指地面点不动，等价原 zoom_at_mouse）
##   Q/E -> 90° 步进水平旋转（延续立牌四方向贴图索引）
##   右键拖拽 -> 微调水平角/俯仰角（俯仰限制 30°~60°，防止立牌露馅）
## 世界约定：1 格 = 1 个 3D 单位；格子 (x,y) 中心 = 世界 (x+0.5, 0, y+0.5)。

const ZOOM_MIN := 0.4
const ZOOM_MAX := 3.0
const ZOOM_STEP := 1.15
const PAN_SPEED := 12.5  # 地面单位/秒（= 2D 的 600 像素/秒 ÷ 48 像素/格，默认缩放时）
const PITCH_MIN := deg_to_rad(30.0)
const PITCH_MAX := deg_to_rad(60.0)
const PITCH_DEFAULT := deg_to_rad(45.0)
const FOV := 45.0
## 默认缩放（_zoom=1）下的相机距离：按俯仰 45°、视场 45° 能使 40x30 地图（对角约 50 格）完整入镜
const DIST_AT_ZOOM1 := 47.0

var camera: Camera3D

var target := Vector3(20.0, 0.0, 15.0)  # 轨道目标点（地面）
var _zoom := 1.0
var _yaw := 0.0  # 水平角：0 = 相机在目标南侧（+z）望向北
var _pitch := PITCH_DEFAULT
var _dist := DIST_AT_ZOOM1
var _dragging := false  # 中键平移拖拽
var _orbiting := false  # 右键微调视角拖拽


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = FOV
	camera.near = 0.1
	camera.far = 400.0
	add_child(camera)
	_update_camera()


# ---------- 视角 ----------

## 贴图四方向索引（替代 2D 的 _rot）：水平角按最近 90° 取整
func get_view_dir_index() -> int:
	return posmod(int(round(_yaw / (PI / 2.0))), 4)


func rotate_view(step: int) -> void:
	## Q/E 旋转 90°（瞬时步进，同 2D）
	_yaw += step * PI / 2.0
	_update_camera()


func zoom_at_mouse(factor: float) -> void:
	zoom_at_pos(_mouse_pos(), factor)


func zoom_at_pos(screen_pos: Vector2, factor: float) -> void:
	## 向指定屏幕点缩放：推导保持该点射线所指地面点 G 在缩放前后重合
	##   新目标点 T' = T + (d-d')·u + t·(1-d'/d)·m
	##   （u = 相机朝向单位向量，m = 该点射线单位向量，t = 缩放前相机到 G 的射线距离）
	var new_zoom := clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, _zoom):
		return
	var new_dist := DIST_AT_ZOOM1 / new_zoom
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)
	if absf(rd.y) < 1e-6:
		return
	var t := -ro.y / rd.y
	if t <= 0.0:
		return  # 指向天空/地平线，按普通缩放处理
	var g := ro + rd * t
	var u := (camera.global_position - target).normalized()
	var tg := (g - camera.global_position).dot(rd)
	target += (dist() - new_dist) * u + tg * (1.0 - new_dist / dist()) * rd
	_zoom = new_zoom
	_dist = new_dist
	_update_camera()


func dist() -> float:
	return _dist


func pan_by(relative: Vector2) -> void:
	## 中键拖拽平移：屏幕像素增量按当前地面可视高度换算成地面位移
	var px_per_unit := _ground_px_per_unit()
	var fwd := _ground_forward()
	var right := _ground_right()
	# 与 2D 一致：世界跟随鼠标（相机反向移动）
	target -= (right * relative.x - fwd * relative.y) / px_per_unit
	_update_camera()


func pan_wasd(delta: float) -> void:
	## WASD/方向键平移（由 Main._process 在原有时序点调用）
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		dir.x += 1
	if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W):
		dir.y -= 1
	if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S):
		dir.y += 1
	if dir != Vector2.ZERO:
		var fwd := _ground_forward()
		var right := _ground_right()
		target += (-dir.y * fwd + dir.x * right) * PAN_SPEED * delta / _zoom
		_update_camera()


func orbit_adjust(relative: Vector2) -> void:
	## 右键拖拽微调视角
	_yaw -= relative.x * 0.005
	_pitch = clampf(_pitch + relative.y * 0.005, PITCH_MIN, PITCH_MAX)
	_update_camera()


func set_dragging(v: bool) -> void:
	_dragging = v


func is_dragging() -> bool:
	return _dragging


func set_orbiting(v: bool) -> void:
	_orbiting = v


func is_orbiting() -> bool:
	return _orbiting


# ---------- 拾取 ----------

func ground_at_mouse() -> Vector3:
	## 鼠标射线与 y=0 地面的交点（无交点返回目标点）
	return ground_at(_mouse_pos())


func ground_at(screen_pos: Vector2) -> Vector3:
	## 指定屏幕点的射线与 y=0 地面的交点（无交点返回目标点）
	var ro := camera.project_ray_origin(screen_pos)
	var rd := camera.project_ray_normal(screen_pos)
	if absf(rd.y) < 1e-6:
		return target
	var t := -ro.y / rd.y
	if t <= 0.0:
		return target
	return ro + rd * t


## 指定屏幕点的地面点 2D 像素坐标（MAP_ORIGIN + 格坐标*CELL，喂给 GameState.screen_to_cell）
func grid_pos_at(screen_pos: Vector2) -> Vector2:
	var g := ground_at(screen_pos)
	return GameState.MAP_ORIGIN + Vector2(g.x, g.z) * GameState.CELL


## 鼠标所指地面点的 2D 像素坐标（MAP_ORIGIN + 格坐标*CELL，喂给 GameState.screen_to_cell）
func mouse_grid_pos() -> Vector2:
	return grid_pos_at(_mouse_pos())


## 相机可视区域与地面的四顶点交点（格子坐标系），供小地图画视野框
func get_ground_view_rect() -> Rect2:
	var vp := camera.get_viewport().get_visible_rect().size
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for ndc: Vector2 in corners:
		var sp := (ndc + Vector2.ONE) / 2.0 * vp  # NDC -> 屏幕像素
		var ro := camera.project_ray_origin(sp)
		var rd := camera.project_ray_normal(sp)
		if absf(rd.y) < 1e-6:
			continue
		var t := -ro.y / rd.y
		if t <= 0.0:
			continue
		var g := ro + rd * t
		min_x = minf(min_x, g.x)
		min_z = minf(min_z, g.z)
		max_x = maxf(max_x, g.x)
		max_z = maxf(max_z, g.z)
	if min_x > max_x:
		return Rect2()
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z)


func _mouse_pos() -> Vector2:
	return camera.get_viewport().get_mouse_position()


# ---------- 内部 ----------

func _ground_forward() -> Vector3:
	## 相机朝向在地面上的投影单位向量（屏幕"向上"对应的远离相机方向）
	var fwd := -camera.global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized() if fwd.length() > 1e-6 else Vector3(0, 0, -1)


func _ground_right() -> Vector3:
	var right := camera.global_transform.basis.x
	right.y = 0.0
	return right.normalized() if right.length() > 1e-6 else Vector3(1, 0, 0)


func _ground_px_per_unit() -> float:
	## 目标点处地面在屏幕垂直方向上的像素/单位换算
	var vp_h := camera.get_viewport().get_visible_rect().size.y
	var ground_h := 2.0 * _dist * tan(deg_to_rad(FOV) / 2.0) / sin(_pitch)
	return vp_h / ground_h


func _update_camera() -> void:
	var offset := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw)) * _dist
	camera.position = target + offset
	camera.look_at(target, Vector3.UP)
