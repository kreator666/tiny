extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 渲染：45° 斜投影（菱形地砖）+ 建筑立牌（billboard）+ 深度排序遮挡。
##       立牌建筑带四方向贴图，随视角旋转切换；贴地 tile 随投影自动转向。
## 视角：滚轮缩放（以鼠标为中心）、中键拖拽平移、WASD/方向键平移、Q/E 旋转 90°。
## 核心玩法：
##   生产链：农田 -> 粮食 -> 磨坊 -> 面粉 -> 市集 -> 食品 -> 民居。
##   住房演进：茅屋(1格,4人) -> 瓦房(1格,8人) -> 宅院(2x2,32人) -> 豪华大宅(2x2,48人)。
##     条件：持续有行人服务 + 无饥荒；瓦房凑齐 2x2 空地自动合并为宅院。
##   建筑需邻接道路激活；行人（居民/挑夫）沿路随机行走并服务相邻民居。
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
const HUD_WIDTH := 284.0

# 斜投影基向量：格子 (x,y) -> 世界 (x - y, (x + y) / 2)
const ISO_X := Vector2(1, 0.5)
const ISO_Y := Vector2(-1, 0.5)
const DEPTH_VECS := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]

const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# 行人参数
const WALK_SPEED := 2.5  # 格/秒
const WALKER_STEPS := 20
const WALKER_MAX := 80
const SPAWN_INTERVAL := 3.0

# 住房演进参数
const EVOLVE_HUT := 3  # 茅屋->瓦房所需达标月数
const EVOLVE_MERGE := 3  # 瓦房->宅院所需达标月数
const EVOLVE_ESTATE := 6  # 宅院->豪华大宅所需达标月数
const ESTATE_CAP := {2: 32, 3: 48}
const HUT_CAP := 4
const TILEHOUSE_CAP := 8

# 贴图运行时加载（素材包切换见 AssetLib；严禁在 _draw 中 load）
var ground_tex: Array = []  # [ground_0, ground_1]
var tree_tex: Texture2D
var villager_tex: Texture2D
var road_tex: Dictionary = {}  # 方向键 -> Texture2D，键同 ROAD_KEYS
var estate_tex: Dictionary = {}  # 等级 2/3 -> [d0..d3]

const ROAD_KEYS: Array = ["o", "n", "e", "s", "w", "ne", "ns", "nw", "es", "ew", "sw", "nes", "new", "nsw", "esw", "nesw"]


func _load_pack_textures() -> void:
	AssetLib.init()
	ground_tex = [AssetLib.tex("ground_0.png"), AssetLib.tex("ground_1.png")]
	tree_tex = AssetLib.tex("tree.png")
	villager_tex = AssetLib.tex("villager.png")
	for k: String in ROAD_KEYS:
		road_tex[k] = AssetLib.tex("road_%s.png" % k)
	estate_tex = {2: [], 3: []}
	for tier in [2, 3]:
		for i in 4:
			estate_tex[tier].append(AssetLib.tex("estate%d_d%d.png" % [tier, i]))

# ---------- 状态 ----------

var building_defs: Dictionary = {}
var buildings: Dictionary = {}  # Vector2i -> 类型（1 格建筑，含 hut/tilehouse/farm/mill/market/road）
var estates: Dictionary = {}  # 2x2 大院锚点 Vector2i -> 等级(2 宅院 / 3 豪华大宅)
var grass: Dictionary = {}
var trees: Dictionary = {}

var walkers: Array = []  # {pos, cur, nxt, t, left, prev, kind} kind: 0居民 1挑夫
var serviced: Dictionary = {}  # 居所(民居格或大院锚点) -> 最近服务月份序号
var evolve_prog: Dictionary = {}  # 居所 -> 连续达标月数

var population := 0
var pop_capacity := 0
var grain := 100.0
var flour := 0.0
var food := 20.0
var gold := 10000.0
var year := 1
var month := 1
var _months_total := 0

var selected_tool := ""
var hover_cell := Vector2i(-1, -1)
var message := ""

var _elapsed := 0.0
var _dragging := false
var _spawn_accum := 0.0

var _rot := 0
var _cam_pos := Vector2.ZERO
var _zoom := Vector2.ONE

var _pop_label: Label
var _grain_label: Label
var _flour_label: Label
var _food_label: Label
var _gold_label: Label
var _date_label: Label
var _tool_label: Label
var _walker_label: Label
var _message_label: Label
var _tool_buttons := {}


func _ready() -> void:
	_load_pack_textures()
	_load_building_defs()
	_generate_terrain()
	_build_hud()
	_refresh_capacity()
	_update_hud()
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
		if bool(def.get("dir", false)):
			# 四方向贴图：texture 为基名，加载 _d0.._d3
			def["tex_dirs"] = []
			for i in 4:
				def["tex_dirs"].append(AssetLib.tex("%s_d%d.png" % [def["texture"], i]))
		else:
			def["tex"] = AssetLib.tex(def["texture"])


func _building_tex(btype: String) -> Texture2D:
	var def: Dictionary = building_defs[btype]
	if def.has("tex_dirs"):
		return def["tex_dirs"][_rot]
	return def["tex"]


# 道路方向块：按格子四邻连接选贴图（贴图轴=格子轴，随投影整体旋转，天然一致）
func _road_tex(cell: Vector2i) -> Texture2D:
	var mask := ""
	if _is_road(cell + Vector2i(1, 0)):
		mask += "e"
	if _is_road(cell + Vector2i(-1, 0)):
		mask += "w"
	if _is_road(cell + Vector2i(0, 1)):
		mask += "s"
	if _is_road(cell + Vector2i(0, -1)):
		mask += "n"
	var key := ""
	for c in "nesw":
		if c in mask:
			key += c
	if key.is_empty():
		key = "o"  # 孤立路块
	return road_tex[key]


func _generate_terrain() -> void:
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
	return Transform2D(_rot * PI / 2, Vector2.ZERO) * Transform2D(ISO_X, ISO_Y, Vector2.ZERO)


func _apply_rotation(rot: int) -> void:
	_rot = posmod(rot, 4)
	transform = _proj()
	queue_redraw()


func _rotate_view(step: int) -> void:
	var old := _proj()
	_apply_rotation(_rot + step)
	_cam_pos = _proj() * old.affine_inverse() * _cam_pos


func _view_center() -> Vector2:
	var size := get_viewport_rect().size
	return Vector2((size.x - HUD_WIDTH) / 2, size.y / 2)


func _update_view() -> void:
	var c := _view_center()
	get_viewport().canvas_transform = Transform2D(
		Vector2(_zoom.x, 0), Vector2(0, _zoom.y), _zoom * (-_cam_pos) + c)


func _zoom_at_mouse(factor: float) -> void:
	var new_zoom := (_zoom * factor).clampf(ZOOM_MIN, ZOOM_MAX)
	if new_zoom.is_equal_approx(_zoom):
		return
	var m := get_viewport().get_mouse_position()
	var world := (m - _view_center()) / _zoom.x + _cam_pos
	_cam_pos = world - (world - _cam_pos) * (_zoom.x / new_zoom.x)
	_zoom = new_zoom
	queue_redraw()


# ---------- 占用与道路 ----------

func _is_road(cell: Vector2i) -> bool:
	return buildings.get(cell, "") == "road"


func _estate_anchor_at(cell: Vector2i) -> Vector2i:
	## 返回覆盖该格的大院锚点，无则 (-1,-1)
	for anchor: Vector2i in estates:
		if cell.x >= anchor.x and cell.x < anchor.x + 2 \
				and cell.y >= anchor.y and cell.y < anchor.y + 2:
			return anchor
	return Vector2i(-1, -1)


func _is_occupied(cell: Vector2i) -> bool:
	return buildings.has(cell) or trees.has(cell) or _estate_anchor_at(cell) != Vector2i(-1, -1)


func _road_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for dir: Vector2i in DIRS:
		var nb := cell + dir
		if _is_road(nb):
			result.append(nb)
	return result


func _has_adjacent_road(cell: Vector2i) -> bool:
	return not _road_neighbors(cell).is_empty()


func _estate_has_road(anchor: Vector2i) -> bool:
	for dx in 2:
		for dy in 2:
			if _has_adjacent_road(anchor + Vector2i(dx, dy)):
				return true
	return false


# ---------- 行人 ----------

func _spawn_walkers() -> void:
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		var kind := -1
		if btype == "hut" or btype == "tilehouse":
			kind = 0
		elif btype == "market":
			kind = 1
		if kind < 0 or walkers.size() >= WALKER_MAX:
			continue
		if not _has_adjacent_road(cell):
			continue
		var roads := _road_neighbors(cell)
		var start: Vector2i = roads[randi() % roads.size()]
		_spawn_walker_from(start, cell, kind)
	# 大院从任意邻路格派人
	for anchor: Vector2i in estates:
		if walkers.size() >= WALKER_MAX:
			return
		if not _estate_has_road(anchor):
			continue
		var spawned := false
		for dx in 2:
			for dy in 2:
				var roads := _road_neighbors(anchor + Vector2i(dx, dy))
				if not roads.is_empty():
					_spawn_walker_from(roads[randi() % roads.size()], anchor, 0)
					spawned = true
					break
			if spawned:
				break


func _spawn_walker_from(start: Vector2i, home: Variant, kind: int) -> void:
	var next := _choose_next_road(start, home)
	if next == Vector2i(-1, -1):
		return
	walkers.append({
		"pos": Vector2(start),
		"cur": start,
		"nxt": next,
		"prev": home,
		"t": 0.0,
		"left": WALKER_STEPS,
		"kind": kind,
	})
	_service_around(start)


func _choose_next_road(cur: Vector2i, prev: Variant) -> Vector2i:
	var options: Array[Vector2i] = []
	for nb: Vector2i in _road_neighbors(cur):
		if nb != prev:
			options.append(nb)
	if options.is_empty():
		options = _road_neighbors(cur)
	if options.is_empty():
		return Vector2i(-1, -1)
	return options[randi() % options.size()]


func _service_around(road_cell: Vector2i) -> void:
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if buildings.get(nb, "") == "hut" or buildings.get(nb, "") == "tilehouse":
			serviced[nb] = _months_total
		else:
			var anchor := _estate_anchor_at(nb)
			if anchor != Vector2i(-1, -1):
				serviced[anchor] = _months_total


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
					_try_place(_screen_to_cell(_mouse_grid_pos()))
	elif event is InputEventMouseMotion:
		if _dragging:
			_cam_pos -= event.relative / _zoom.x
		hover_cell = _screen_to_cell(_mouse_grid_pos())
		queue_redraw()


func _mouse_grid_pos() -> Vector2:
	return _proj().affine_inverse() * get_global_mouse_position()


func _screen_to_cell(pos: Vector2) -> Vector2i:
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
	if _is_occupied(cell):
		_show_message("这里已被占用")
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

	_spawn_accum += delta
	if _spawn_accum >= SPAWN_INTERVAL:
		_spawn_accum = 0.0
		_spawn_walkers()
	if not walkers.is_empty():
		_update_walkers(delta)
		_walker_label.text = "行人：%d" % walkers.size()
		queue_redraw()

	var new_hover := _screen_to_cell(_mouse_grid_pos())
	if new_hover != hover_cell:
		hover_cell = new_hover
		queue_redraw()

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


func _recently_serviced(key: Vector2i) -> bool:
	return _months_total - int(serviced.get(key, -999)) <= 1


func _advance_month() -> void:
	_months_total += 1

	# 生产链
	var stock := {"grain": grain, "flour": flour, "food": food}
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		var def: Dictionary = building_defs.get(btype, {})
		if not _has_adjacent_road(cell):
			continue
		if def.has("grain_per_month"):
			stock["grain"] = float(stock["grain"]) + float(def["grain_per_month"])
		if def.has("convert_from"):
			var use: float = minf(float(def["convert_rate"]), float(stock[def["convert_from"]]))
			stock[def["convert_from"]] = float(stock[def["convert_from"]]) - use
			stock[def["convert_to"]] = float(stock[def["convert_to"]]) + use
	grain = stock["grain"]
	flour = stock["flour"]
	food = stock["food"]

	# 居所与有效容量
	var residence_keys: Array = []  # 民居格 或 大院锚点
	for cell: Vector2i in buildings:
		if buildings[cell] == "hut" or buildings[cell] == "tilehouse":
			residence_keys.append(cell)
	residence_keys.append_array(estates.keys())
	var serviced_count := 0
	for key: Vector2i in residence_keys:
		if _recently_serviced(key):
			serviced_count += 1
	var eff_capacity := 0
	if not residence_keys.is_empty():
		var ratio := float(serviced_count) / residence_keys.size()
		eff_capacity = int(round(pop_capacity * ratio))
		if ratio < 0.5 and population > 0:
			_show_message("部分民居缺乏行人往来，发展停滞")

	# 人口吃食品
	var fed := false
	var consumption: int = int(ceil(population * 0.5))
	if food >= consumption:
		food -= consumption
		fed = true
		if population < eff_capacity:
			population = mini(eff_capacity, population + maxi(1, eff_capacity / 20))
	elif population > 0:
		food = 0.0
		population = maxi(0, population - maxi(1, population / 10))
		if grain > 0 or flour > 0:
			_show_message("有粮无食！需要磨坊和市集把粮食端上桌")
		else:
			_show_message("饥荒！人口下降")

	if not residence_keys.is_empty() and eff_capacity < pop_capacity and population > eff_capacity:
		population = maxi(eff_capacity, population - maxi(1, population / 20))

	# 住房演进（需吃饱 + 有服务）
	_evolve_housing(fed)

	gold += population * 0.2

	month += 1
	if month > 12:
		month = 1
		year += 1

	_update_hud()
	queue_redraw()


func _evolve_housing(fed: bool) -> void:
	# 茅屋 -> 瓦房
	for cell: Vector2i in buildings.keys():
		if buildings.get(cell, "") != "hut":
			continue
		if fed and _recently_serviced(cell):
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) + 1
			if evolve_prog[cell] >= EVOLVE_HUT:
				buildings[cell] = "tilehouse"
				evolve_prog.erase(cell)
				_show_message("一间茅屋翻修成了瓦房")
		else:
			evolve_prog[cell] = 0

	# 瓦房 -> 宅院（2x2 合并；合并会改动 buildings，用 .get 防快照键失效）
	for cell: Vector2i in buildings.keys():
		if buildings.get(cell, "") != "tilehouse":
			continue
		if fed and _recently_serviced(cell):
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) + 1
			if evolve_prog[cell] >= EVOLVE_MERGE and _try_merge_estate(cell):
				pass  # 合并成功后 cell 已被移除
		else:
			evolve_prog[cell] = 0

	# 宅院 -> 豪华大宅
	for anchor: Vector2i in estates.keys():
		if estates[anchor] != 2:
			continue
		if fed and _recently_serviced(anchor):
			evolve_prog[anchor] = int(evolve_prog.get(anchor, 0)) + 1
			if evolve_prog[anchor] >= EVOLVE_ESTATE:
				estates[anchor] = 3
				evolve_prog.erase(anchor)
				_show_message("一座宅院扩建成了豪华大宅！")
		else:
			evolve_prog[anchor] = 0


func _try_merge_estate(cell: Vector2i) -> bool:
	## 尝试以 cell 为四角之一合并 2x2 宅院；空地或瓦房均可被吞并
	for anchor: Vector2i in [cell, cell + Vector2i(-1, 0), cell + Vector2i(0, -1), cell + Vector2i(-1, -1)]:
		if not _mergeable(anchor):
			continue
		for dx in 2:
			for dy in 2:
				var c := anchor + Vector2i(dx, dy)
				if buildings.get(c, "") == "tilehouse":
					buildings.erase(c)
					evolve_prog.erase(c)
					serviced.erase(c)
		estates[anchor] = 2
		serviced[anchor] = _months_total
		evolve_prog[anchor] = 0
		_refresh_capacity()
		_show_message("几户村民合建了一座宅院！")
		return true
	return false


func _mergeable(anchor: Vector2i) -> bool:
	if anchor.x < 0 or anchor.y < 0 or anchor.x + 1 >= GRID_W or anchor.y + 1 >= GRID_H:
		return false
	for dx in 2:
		for dy in 2:
			var c := anchor + Vector2i(dx, dy)
			if trees.has(c):
				return false
			if buildings.has(c) and buildings[c] != "tilehouse":
				return false
			if _estate_anchor_at(c) != Vector2i(-1, -1):
				return false
	return true


func _refresh_capacity() -> void:
	var cap := 0
	for type: String in buildings.values():
		if type == "hut":
			cap += HUT_CAP
		elif type == "tilehouse":
			cap += TILEHOUSE_CAP
	for tier: int in estates.values():
		cap += int(ESTATE_CAP[tier])
	pop_capacity = cap


# ---------- 存档 ----------

func _on_save_pressed() -> void:
	var list := []
	for cell: Vector2i in buildings:
		list.append({"x": cell.x, "y": cell.y, "type": buildings[cell]})
	var estate_list := []
	for anchor: Vector2i in estates:
		estate_list.append({"x": anchor.x, "y": anchor.y, "tier": estates[anchor]})
	var tree_list := []
	for cell: Vector2i in trees:
		tree_list.append({"x": cell.x, "y": cell.y})
	var state := {
		"population": population,
		"grain": grain,
		"flour": flour,
		"food": food,
		"gold": gold,
		"year": year,
		"month": month,
		"months_total": _months_total,
		"buildings": list,
		"estates": estate_list,
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
	flour = float(state.get("flour", 0.0))
	food = float(state.get("food", 20.0))
	gold = float(state["gold"])
	year = int(state["year"])
	month = int(state["month"])
	_months_total = int(state.get("months_total", (year - 1) * 12 + month))
	buildings.clear()
	estates.clear()
	trees.clear()
	serviced.clear()
	walkers.clear()
	evolve_prog.clear()
	for entry: Dictionary in state["buildings"]:
		buildings[Vector2i(int(entry["x"]), int(entry["y"]))] = String(entry["type"])
	for entry: Dictionary in state.get("estates", []):
		estates[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["tier"])
	for entry: Dictionary in state.get("trees", []):
		trees[Vector2i(int(entry["x"]), int(entry["y"]))] = true
	_refresh_capacity()
	_update_hud()
	queue_redraw()
	_show_message("读取成功")


func _on_reset_pressed() -> void:
	buildings.clear()
	estates.clear()
	walkers.clear()
	serviced.clear()
	evolve_prog.clear()
	_months_total = 0
	population = 0
	grain = 100.0
	flour = 0.0
	food = 20.0
	gold = 10000.0
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
	_flour_label = Label.new()
	box.add_child(_flour_label)
	_food_label = Label.new()
	box.add_child(_food_label)
	_gold_label = Label.new()
	box.add_child(_gold_label)
	_walker_label = Label.new()
	box.add_child(_walker_label)
	_tool_label = Label.new()
	box.add_child(_tool_label)

	var sep := HSeparator.new()
	box.add_child(sep)

	# 建造按钮（跳过不可直接建造的类型，如瓦房）
	for type: String in building_defs:
		var def: Dictionary = building_defs[type]
		if bool(def.get("buildable", true)) == false:
			continue
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
	_flour_label.text = "面粉：%d" % int(flour)
	_food_label.text = "食品：%d" % int(food)
	_gold_label.text = "金钱：%d" % int(gold)
	_walker_label.text = "行人：%d" % walkers.size()


func _show_message(text: String) -> void:
	message = text
	if _message_label:
		_message_label.text = text


# ---------- 绘制 ----------

func _draw() -> void:
	var world_size := get_viewport_rect().size / _zoom.x
	var top_left := _cam_pos - world_size / 2
	draw_set_transform_matrix(Transform2D(Vector2(_zoom.x, 0), Vector2(0, _zoom.y), Vector2.ZERO))
	draw_rect(Rect2(top_left, world_size), Color(0.13, 0.12, 0.10))
	draw_set_transform_matrix(Transform2D())

	# 地面层：草地 + 贴地建筑
	for cell: Vector2i in grass:
		var ground: Texture2D = ground_tex[0] if grass[cell] == 0 else ground_tex[1]
		draw_texture(ground, MAP_ORIGIN + Vector2(cell) * CELL)
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		if bool(building_defs[btype].get("flat", false)):
			if btype == "road":
				draw_texture(_road_tex(cell), MAP_ORIGIN + Vector2(cell) * CELL)
			else:
				draw_texture(_building_tex(btype), MAP_ORIGIN + Vector2(cell) * CELL)

	# 立牌层（含大院），按深度排序
	var dv: Vector2 = DEPTH_VECS[_rot]
	var items := []
	for cell: Vector2i in trees:
		items.append([Vector2(cell).dot(dv), cell, "tree"])
	for cell: Vector2i in buildings:
		if not bool(building_defs[buildings[cell]].get("flat", false)):
			items.append([Vector2(cell).dot(dv), cell, buildings[cell]])
	for anchor: Vector2i in estates:
		items.append([Vector2(anchor + Vector2i(1, 1)).dot(dv), anchor, "estate"])
	for w: Dictionary in walkers:
		items.append([w.pos.dot(dv), null, "walker", w])
	items.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	for item: Array in items:
		if item[2] == "walker":
			var w: Dictionary = item[3]
			var wbase: Vector2 = _proj() * (MAP_ORIGIN + w.pos * CELL + Vector2(CELL, CELL) / 2)
			draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, wbase))
			var tint := Color(0.95, 0.78, 0.6) if int(w.get("kind", 0)) == 1 else Color.WHITE
			draw_texture(villager_tex, Vector2(-6, -18), tint)
			draw_set_transform_matrix(Transform2D())
			continue
		if item[2] == "estate":
			var anchor: Vector2i = item[1]
			var tier: int = estates[anchor]
			# 落脚点：2x2 地块的底边中心
			var ebase: Vector2 = _proj() * (MAP_ORIGIN + Vector2(anchor + Vector2i(1, 2)) * CELL)
			draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, ebase))
			var etex: Texture2D = estate_tex[tier][_rot]
			draw_texture(etex, Vector2(-48, -58))
			draw_set_transform_matrix(Transform2D())
			continue
		var cell: Vector2i = item[1]
		var base: Vector2 = _proj() * (MAP_ORIGIN + Vector2(cell) * CELL + Vector2(CELL / 2, CELL))
		draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, base))
		if item[2] == "tree":
			draw_texture(tree_tex, Vector2(-20, -54))
		else:
			draw_texture(_building_tex(item[2]), Vector2(-16, -30))
	draw_set_transform_matrix(Transform2D())

	# 悬停预览
	if _in_bounds(hover_cell) and not selected_tool.is_empty():
		var valid := not _is_occupied(hover_cell)
		var p0 := MAP_ORIGIN + Vector2(hover_cell) * CELL
		var corners := [p0, p0 + Vector2(CELL, 0), p0 + Vector2(CELL, CELL), p0 + Vector2(0, CELL)]
		var tint2 := Color(0.4, 0.9, 0.4, 0.25) if valid else Color(0.9, 0.3, 0.3, 0.35)
		draw_colored_polygon(corners, tint2)
		draw_polyline(corners + [corners[0]], Color(0.4, 0.9, 0.4) if valid else Color(0.9, 0.3, 0.3), 1.5)
		if valid:
			var ghost_def: Dictionary = building_defs[selected_tool]
			if bool(ghost_def.get("flat", false)):
				var gtex: Texture2D = road_tex["o"] if selected_tool == "road" else _building_tex(selected_tool)
				draw_texture(gtex, p0, Color(1, 1, 1, 0.6))
			else:
				var gbase: Vector2 = _proj() * (p0 + Vector2(CELL / 2, CELL))
				draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, gbase))
				draw_texture(_building_tex(selected_tool), Vector2(-16, -30), Color(1, 1, 1, 0.6))
				draw_set_transform_matrix(Transform2D())
