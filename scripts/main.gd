extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 渲染：45° 斜投影（菱形地砖）+ 建筑立牌（billboard）+ 深度排序遮挡。
## 视角：滚轮缩放（以鼠标为中心）、中键拖拽平移、WASD/方向键平移、Q/E 旋转 90°。
## 核心玩法：法老王式道路+行人系统——
##   建筑需邻接道路激活；民居派出行人沿路随机行走，
##   行人经过的道路格会“服务”相邻民居，无服务的民居停止发展。
## 时间流速：每 2 秒 = 1 个月。
## 素材：程序化生成工笔画风（tools/gen_gongbi_assets.py）。

const GRID_W := 40
const GRID_H := 30
const CELL := 32
const MAP_ORIGIN := Vector2(16, 16)
const MONTH_SECONDS := 2.0

const ZOOM_MIN := 0.4
const ZOOM_MAX := 3.0
const ZOOM_STEP := 1.15
const PAN_SPEED := 600.0  # 世界像素/秒
const HUD_WIDTH := 284.0  # 右侧 HUD 占用宽度（视图中心左移）

# 斜投影基向量：格子 (x,y) -> 世界 (x - y, (x + y) / 2)
const ISO_X := Vector2(1, 0.5)
const ISO_Y := Vector2(-1, 0.5)
# 各旋转方向下的深度排序轴（格子坐标系中“屏幕向下”的方向）
const DEPTH_VECS := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# 行人参数
const WALK_SPEED := 2.5  # 格/秒
const WALKER_STEPS := 20  # 每次出行走的步数
const WALKER_MAX := 60
const SPAWN_INTERVAL := 3.0  # 每个民居的派人间隔（秒）

const GROUND_0: Texture2D = preload("res://assets/gongbi/ground_0.png")
const GROUND_1: Texture2D = preload("res://assets/gongbi/ground_1.png")
const TREE_TEX: Texture2D = preload("res://assets/gongbi/tree.png")
const VILLAGER_TEX: Texture2D = preload("res://assets/gongbi/villager.png")

# ---------- 状态 ----------

var building_defs: Dictionary = {}  # 加载时缓存贴图到每个 def 的 "tex" 字段
var buildings: Dictionary = {}  # Vector2i 坐标 -> 建筑类型(String)
var grass: Dictionary = {}  # Vector2i 坐标 -> 草地块变体索引(0/1)
var trees: Dictionary = {}  # Vector2i 坐标 -> true

var walkers: Array = []  # 每个行人: {pos, cur, nxt, t, left, prev}
var serviced: Dictionary = {}  # 民居格 -> 最近一次被行人服务的月份序号

var population := 0
var pop_capacity := 0  # 由民居数量决定，每次变化时重算
var grain := 100.0
var gold := 100.0
var year := 1
var month := 1
var _months_total := 0  # 累计月份序号（服务时效判定用）

var selected_tool := ""  # 当前选中的建造类型，空串 = 无
var hover_cell := Vector2i(-1, -1)
var message := ""

var _elapsed := 0.0
var _dragging := false  # 中键拖拽平移中
var _spawn_accum := 0.0

# 视角状态（世界坐标 = 斜投影后的平面坐标）
var _rot := 0  # 当前旋转方向 0..3
var _cam_pos := Vector2.ZERO  # 视野中心的世界坐标
var _zoom := Vector2.ONE

# HUD 节点引用（在 _build_hud 中创建）
var _pop_label: Label
var _grain_label: Label
var _gold_label: Label
var _date_label: Label
var _tool_label: Label
var _walker_label: Label
var _message_label: Label
var _tool_buttons := {}


func _ready() -> void:
	_load_building_defs()
	_generate_terrain()
	_build_hud()
	_refresh_capacity()
	_update_hud()
	# 初始视角：地图中心
	_apply_rotation(0)
	var map_center := MAP_ORIGIN + Vector2(GRID_W, GRID_H) * CELL / 2
	_cam_pos = _proj() * map_center


func _load_building_defs() -> void:
	var file := FileAccess.open("res://data/buildings.json", FileAccess.READ)
	assert(file != null, "找不到 data/buildings.json")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(typeof(parsed) == TYPE_DICTIONARY, "buildings.json 格式错误")
	building_defs = parsed
	for type: String in building_defs:
		var def: Dictionary = building_defs[type]
		def["tex"] = load("res://assets/gongbi/" + def["texture"])


func _generate_terrain() -> void:
	# 固定种子，保证每次新档地形一致（可换成 randi 每次随机）
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240101
	for x in GRID_W:
		for y in GRID_H:
			var cell := Vector2i(x, y)
			grass[cell] = rng.randi_range(0, 1)
			if rng.randf() < 0.05:
				trees[cell] = true


# ---------- 视角 ----------

func _proj() -> Transform2D:
	## 当前旋转方向下的斜投影矩阵（格子像素坐标 -> 世界坐标）
	return Transform2D(_rot * PI / 2, Vector2.ZERO) * Transform2D(ISO_X, ISO_Y, Vector2.ZERO)


func _apply_rotation(rot: int) -> void:
	_rot = posmod(rot, 4)
	transform = _proj()  # Main 自身变换 = 投影矩阵，子节点/绘制全部受其影响
	queue_redraw()


func _rotate_view(step: int) -> void:
	var old := _proj()
	_apply_rotation(_rot + step)
	# 视野中心跟着旋转，保证屏幕中心点不动
	_cam_pos = _proj() * old.affine_inverse() * _cam_pos


func _view_center() -> Vector2:
	var size := get_viewport_rect().size
	return Vector2((size.x - HUD_WIDTH) / 2, size.y / 2)


func _update_view() -> void:
	## 世界坐标 -> 屏幕坐标：缩放后平移（由 viewport 承载，CanvasLayer HUD 不受影响）
	var c := _view_center()
	get_viewport().canvas_transform = Transform2D(
		Vector2(_zoom.x, 0), Vector2(0, _zoom.y), _zoom * (-_cam_pos) + c)


func _zoom_at_mouse(factor: float) -> void:
	var new_zoom := (_zoom * factor).clampf(ZOOM_MIN, ZOOM_MAX)
	if new_zoom.is_equal_approx(_zoom):
		return
	var m := get_viewport().get_mouse_position()
	# 鼠标下的世界点缩放前后保持不动
	var world := (m - _view_center()) / _zoom.x + _cam_pos
	_cam_pos = world - (world - _cam_pos) * (_zoom.x / new_zoom.x)
	_zoom = new_zoom
	queue_redraw()


# ---------- 道路与行人 ----------

func _is_road(cell: Vector2i) -> bool:
	return buildings.get(cell, "") == "road"


func _road_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir: Vector2i in DIRS:
		var nb := cell + dir
		if _is_road(nb):
			result.append(nb)
	return result


func _has_adjacent_road(cell: Vector2i) -> bool:
	return not _road_neighbors(cell).is_empty()


func _spawn_walkers() -> void:
	for cell: Vector2i in buildings:
		if buildings[cell] != "house" or population <= 0:
			continue
		if walkers.size() >= WALKER_MAX:
			return
		if not _has_adjacent_road(cell):
			continue
		var roads := _road_neighbors(cell)
		var start: Vector2i = roads[randi() % roads.size()]
		var next := _choose_next_road(start, cell)
		if next == Vector2i(-1, -1):
			continue
		walkers.append({
			"pos": Vector2(start),
			"cur": start,
			"nxt": next,
			"prev": cell,
			"t": 0.0,
			"left": WALKER_STEPS,
		})
		_service_around(start)


func _choose_next_road(cur: Vector2i, prev: Vector2i) -> Vector2i:
	var options: Array[Vector2i] = []
	for nb: Vector2i in _road_neighbors(cur):
		if nb != prev:
			options.append(nb)
	if options.is_empty():
		options = _road_neighbors(cur)  # 死胡同：原路返回
	if options.is_empty():
		return Vector2i(-1, -1)
	return options[randi() % options.size()]


func _service_around(road_cell: Vector2i) -> void:
	## 行人到达道路格，服务相邻民居
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if buildings.get(nb, "") == "house":
			serviced[nb] = _months_total


func _update_walkers(delta: float) -> void:
	for i in range(walkers.size() - 1, -1, -1):
		var w: Dictionary = walkers[i]
		w.t += delta * WALK_SPEED
		if w.t >= 1.0:
			w.cur = w.nxt
			w.t = 0.0
			w.left -= 1
			_service_around(w.cur)
			var next: Vector2i = _choose_next_road(w.cur, w.prev)
			w.prev = w.cur
			if next == Vector2i(-1, -1) or w.left <= 0:
				walkers.remove_at(i)
				continue
			w.nxt = next
		w.pos = Vector2(w.cur).lerp(Vector2(w.nxt), minf(w.t, 1.0))


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				_on_tool_selected("")
			KEY_Q:
				_rotate_view(1)
			KEY_E:
				_rotate_view(-1)
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_at_mouse(1.0 / ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_at_mouse(ZOOM_STEP)
			MOUSE_BUTTON_MIDDLE:
				_dragging = event.pressed
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_on_tool_selected("")
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_try_place(_screen_to_cell(get_global_mouse_position()))
	elif event is InputEventMouseMotion:
		if _dragging:
			_cam_pos -= event.relative / _zoom.x
		hover_cell = _screen_to_cell(get_global_mouse_position())
		queue_redraw()


func _screen_to_cell(pos: Vector2) -> Vector2i:
	## pos 为格子像素坐标（Main 局部坐标）：原点平移后按格子取整
	var local := pos - MAP_ORIGIN
	return Vector2i((local / CELL).floor())


func _try_place(cell: Vector2i) -> void:
	if selected_tool.is_empty():
		return
	if not _in_bounds(cell):
		_show_message("这里不能建造")
		return
	if trees.has(cell):
		_show_message("这里有树木，暂不可建造")
		return
	if buildings.has(cell):
		_show_message("这里已有建筑")
		return
	var def: Dictionary = building_defs[selected_tool]
	if gold < int(def["cost_gold"]):
		_show_message("金钱不足")
		return
	gold -= int(def["cost_gold"])
	buildings[cell] = selected_tool
	_refresh_capacity()
	_show_message("建造了 %s" % def["name"])
	_update_hud()
	queue_redraw()


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < GRID_W and cell.y < GRID_H


# ---------- 时间推演 ----------

func _process(delta: float) -> void:
	_update_view()

	_elapsed += delta
	if _elapsed >= MONTH_SECONDS:
		_elapsed = 0.0
		_advance_month()

	# 行人生成与移动
	_spawn_accum += delta
	if _spawn_accum >= SPAWN_INTERVAL:
		_spawn_accum = 0.0
		_spawn_walkers()
	if not walkers.is_empty():
		_update_walkers(delta)
		_walker_label.text = "行人：%d" % walkers.size()
		queue_redraw()

	# 方向键 / WASD 平移
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
		_cam_pos += dir.normalized() * PAN_SPEED * delta / _zoom.x
		queue_redraw()


func _advance_month() -> void:
	_months_total += 1

	# 农田产出（需邻接道路，粮食才运得出去）
	var farm_count := 0
	for cell: Vector2i in buildings:
		if buildings[cell] == "farm" and _has_adjacent_road(cell):
			farm_count += 1
	grain += farm_count * int(building_defs["farm"]["grain_per_month"])

	# 民居有效容量 = 容量 x 近期有行人往来的民居比例
	var house_cells: Array[Vector2i] = []
	for cell: Vector2i in buildings:
		if buildings[cell] == "house":
			house_cells.append(cell)
	var serviced_count := 0
	for cell: Vector2i in house_cells:
		if _months_total - int(serviced.get(cell, -999)) <= 1:
			serviced_count += 1
	var eff_capacity := 0
	if not house_cells.is_empty():
		var ratio := float(serviced_count) / house_cells.size()
		eff_capacity = int(round(pop_capacity * ratio))
		if ratio < 0.5 and population > 0:
			_show_message("部分民居缺乏行人往来，发展停滞")

	# 人口消耗粮食
	var consumption: int = int(ceil(population * 0.5))
	if grain >= consumption:
		grain -= consumption
		# 有饭吃：人口向有效容量缓慢增长
		if population < eff_capacity:
			population = mini(eff_capacity, population + maxi(1, eff_capacity / 20))
	elif population > 0:
		grain = 0.0
		# 饥荒：人口衰减
		population = maxi(0, population - maxi(1, population / 10))
		_show_message("饥荒！人口下降")

	# 无人行走的民居会逐渐流失人口
	if not house_cells.is_empty() and eff_capacity < pop_capacity and population > eff_capacity:
		population = maxi(eff_capacity, population - maxi(1, population / 20))

	# 税收
	gold += population * 0.2

	# 月份推进
	month += 1
	if month > 12:
		month = 1
		year += 1

	_update_hud()
	queue_redraw()


func _refresh_capacity() -> void:
	var houses := 0
	for type: String in buildings.values():
		if type == "house":
			houses += 1
	pop_capacity = houses * int(building_defs["house"]["pop_capacity"])


# ---------- 存档 ----------

func _on_save_pressed() -> void:
	var list := []
	for cell: Vector2i in buildings:
		list.append({"x": cell.x, "y": cell.y, "type": buildings[cell]})
	var tree_list := []
	for cell: Vector2i in trees:
		tree_list.append({"x": cell.x, "y": cell.y})
	var state := {
		"population": population,
		"grain": grain,
		"gold": gold,
		"year": year,
		"month": month,
		"months_total": _months_total,
		"buildings": list,
		"trees": tree_list,
	}
	var err := SaveManager.save_game(state)
	_show_message("保存成功" if err == OK else "保存失败")


func _on_load_pressed() -> void:
	var state := SaveManager.load_game()
	if state.is_empty():
		_show_message("没有找到存档")
		return
	population = int(state["population"])
	grain = float(state["grain"])
	gold = float(state["gold"])
	year = int(state["year"])
	month = int(state["month"])
	_months_total = int(state.get("months_total", (year - 1) * 12 + month))
	buildings.clear()
	trees.clear()
	serviced.clear()
	walkers.clear()
	for entry: Dictionary in state["buildings"]:
		buildings[Vector2i(int(entry["x"]), int(entry["y"]))] = String(entry["type"])
	for entry: Dictionary in state.get("trees", []):
		trees[Vector2i(int(entry["x"]), int(entry["y"]))] = true
	_refresh_capacity()
	_update_hud()
	queue_redraw()
	_show_message("读取成功")


func _on_reset_pressed() -> void:
	buildings.clear()
	walkers.clear()
	serviced.clear()
	_months_total = 0
	population = 0
	grain = 100.0
	gold = 100.0
	year = 1
	month = 1
	_refresh_capacity()
	_update_hud()
	queue_redraw()
	_show_message("已开新档")


# ---------- HUD ----------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	add_child(layer)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.position = Vector2(-284, -320)
	panel.custom_minimum_size = Vector2(268, 640)
	layer.add_child(panel)

	var box := VBoxContainer.new()
	panel.add_child(box)

	_date_label = Label.new()
	box.add_child(_date_label)
	_pop_label = Label.new()
	box.add_child(_pop_label)
	_grain_label = Label.new()
	box.add_child(_grain_label)
	_gold_label = Label.new()
	box.add_child(_gold_label)
	_walker_label = Label.new()
	box.add_child(_walker_label)
	_tool_label = Label.new()
	box.add_child(_tool_label)

	var sep := HSeparator.new()
	box.add_child(sep)

	# 建造按钮：根据 buildings.json 自动生成（toggle 模式以显示选中状态）
	for type: String in building_defs:
		var def: Dictionary = building_defs[type]
		var btn := Button.new()
		btn.text = "建造%s（%d 金）" % [def["name"], int(def["cost_gold"])]
		btn.tooltip_text = def["desc"]
		btn.toggle_mode = true
		btn.pressed.connect(_on_tool_selected.bind(type))
		box.add_child(btn)
		_tool_buttons[type] = btn

	var cancel_btn := Button.new()
	cancel_btn.text = "取消建造"
	cancel_btn.pressed.connect(_on_tool_selected.bind(""))
	box.add_child(cancel_btn)

	var sep2 := HSeparator.new()
	box.add_child(sep2)

	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(_on_save_pressed)
	box.add_child(save_btn)

	var load_btn := Button.new()
	load_btn.text = "读取"
	load_btn.pressed.connect(_on_load_pressed)
	box.add_child(load_btn)

	var reset_btn := Button.new()
	reset_btn.text = "开新档"
	reset_btn.pressed.connect(_on_reset_pressed)
	box.add_child(reset_btn)

	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_message_label)

	var help_label := Label.new()
	help_label.text = "滚轮缩放 | 中键/WASD平移 | Q/E旋转"
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help_label)


func _on_tool_selected(type: String) -> void:
	selected_tool = type
	for tool: String in _tool_buttons:
		_tool_buttons[tool].set_pressed_no_signal(tool == type)
	var building_name: String = building_defs[type]["name"] if not type.is_empty() else "无"
	if _tool_label:
		_tool_label.text = "当前工具：%s（右键/Esc 取消）" % building_name
	_show_message("已选择：%s" % building_name)


func _update_hud() -> void:
	_date_label.text = "第 %d 年 %d 月" % [year, month]
	_pop_label.text = "人口：%d / %d" % [population, pop_capacity]
	_grain_label.text = "粮食：%d" % int(grain)
	_gold_label.text = "金钱：%d" % int(gold)
	_walker_label.text = "行人：%d" % walkers.size()


func _show_message(text: String) -> void:
	message = text
	if _message_label:
		_message_label.text = text


# ---------- 绘制 ----------

func _draw() -> void:
	# 地图外底色：覆盖整个可视区域（屏幕空间，不受投影影响）
	var world_size := get_viewport_rect().size / _zoom.x
	var top_left := _cam_pos - world_size / 2
	draw_set_transform_matrix(Transform2D(Vector2(_zoom.x, 0), Vector2(0, _zoom.y), Vector2.ZERO))
	draw_rect(Rect2(top_left, world_size), Color(0.13, 0.12, 0.10))
	draw_set_transform_matrix(Transform2D())

	# 地面层：草地 + 贴地建筑（道路、农田）
	for cell: Vector2i in grass:
		var ground := GROUND_0 if grass[cell] == 0 else GROUND_1
		draw_texture(ground, MAP_ORIGIN + Vector2(cell) * CELL)
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		if bool(building_defs[btype].get("flat", false)):
			draw_texture(building_defs[btype]["tex"], MAP_ORIGIN + Vector2(cell) * CELL)

	# 道路连接线（相邻道路之间画上车辙连线）
	for cell: Vector2i in buildings:
		if buildings[cell] != "road":
			continue
		for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			if _is_road(cell + dir):
				var p1 := MAP_ORIGIN + Vector2(cell) * CELL + Vector2(CELL, CELL) / 2
				var p2 := MAP_ORIGIN + Vector2(cell + dir) * CELL + Vector2(CELL, CELL) / 2
				draw_line(p1, p2, Color(0.42, 0.36, 0.28), 3.0)

	# 立牌层：民居/松树/行人，按深度排序实现遮挡
	var dv: Vector2 = DEPTH_VECS[_rot]
	var items := []
	for cell: Vector2i in trees:
		items.append([Vector2(cell).dot(dv), cell, "tree"])
	for cell: Vector2i in buildings:
		if not bool(building_defs[buildings[cell]].get("flat", false)):
			items.append([Vector2(cell).dot(dv), cell, buildings[cell]])
	for w: Dictionary in walkers:
		items.append([w.pos.dot(dv), null, "walker", w])
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	for item: Array in items:
		if item[2] == "walker":
			var w: Dictionary = item[3]
			var wbase: Vector2 = _proj() * (MAP_ORIGIN + w.pos * CELL + Vector2(CELL, CELL) / 2)
			draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, wbase))
			draw_texture(VILLAGER_TEX, Vector2(-6, -18))
			draw_set_transform_matrix(Transform2D())
			continue
		var cell: Vector2i = item[1]
		# 格子底边中心的世界坐标作为立牌落脚点
		var base: Vector2 = _proj() * (MAP_ORIGIN + Vector2(cell) * CELL + Vector2(CELL / 2, CELL))
		draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, base))
		if item[2] == "tree":
			draw_texture(TREE_TEX, Vector2(-20, -54))
		else:
			draw_texture(building_defs[item[2]]["tex"], Vector2(-16, -30))
	draw_set_transform_matrix(Transform2D())

	# 悬停预览：菱形高亮 + 半透明影子
	if _in_bounds(hover_cell) and not selected_tool.is_empty():
		var valid := not buildings.has(hover_cell) and not trees.has(hover_cell)
		var p0 := MAP_ORIGIN + Vector2(hover_cell) * CELL
		var corners := [p0, p0 + Vector2(CELL, 0), p0 + Vector2(CELL, CELL), p0 + Vector2(0, CELL)]
		var tint := Color(0.4, 0.9, 0.4, 0.25) if valid else Color(0.9, 0.3, 0.3, 0.35)
		draw_colored_polygon(corners, tint)
		draw_polyline(corners + [corners[0]], Color(0.4, 0.9, 0.4) if valid else Color(0.9, 0.3, 0.3), 1.5)
		if valid:
			var ghost_def: Dictionary = building_defs[selected_tool]
			if bool(ghost_def.get("flat", false)):
				draw_texture(ghost_def["tex"], p0, Color(1, 1, 1, 0.6))
			else:
				var gbase: Vector2 = _proj() * (p0 + Vector2(CELL / 2, CELL))
				draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, gbase))
				draw_texture(ghost_def["tex"], Vector2(-16, -30), Color(1, 1, 1, 0.6))
				draw_set_transform_matrix(Transform2D())
