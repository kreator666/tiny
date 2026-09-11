class_name Main
extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 渲染：45° 斜投影（菱形地砖）+ 建筑立牌（billboard）+ 深度排序遮挡。
##       立牌建筑带四方向贴图，随视角旋转切换；贴地 tile 随投影自动转向。
## 视角：滚轮缩放（以鼠标为中心）、中键拖拽平移、WASD/方向键平移、Q/E 旋转 90°。
## 核心玩法：
##   生产链：农田 -> 粮食 -> 磨坊 -> 面粉 -> 市集 -> 食品 -> 民居。
##   住房演进：茅屋(1格,4人) -> 瓦房(1格,8人) -> 宅院(2x2,32人) -> 豪华大宅(2x2,48人)。
##     条件：持续有行人服务 + 无饥荒；瓦房凑齐 2x2 空地自动合并为宅院。
##   建筑需邻接道路激活；行人（居民/挑夫/挑水夫/伐木工）沿路随机行走并服务相邻民居。
##   劳动：人口即劳力，工业建筑占用岗位（农田1/磨坊1/市集1/水井1/伐木屋2），
##        招不满人按在岗比例减产；维护度每月下降，低于 60% 半产、低于 30% 停产，可花钱修缮。
##   树木：拆除工具花 10 金立刻砍除；或建伐木屋免费缓慢砍路边树。
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
const EVOLVE_ESTATE := 4  # 宅院->豪华大宅所需达标月数
const ESTATE_CAP := {2: 32, 3: 48}
const HUT_CAP := 4
const TILEHOUSE_CAP := 8

# 财政：按居所等级定的人均月税（金/人/月）与大院维护
const TAX_RATE := {"hut": 0.12, "tilehouse": 0.25, 2: 0.4, 3: 0.6}
const ESTATE_UPKEEP := 5.0
# 朝廷诏令轮换：缴税/贡粮/人口/宅院
const EDICT_CYCLE := ["tax", "tribute", "population", "estate"]

# 难度档位（主菜单选择，新游戏生效；读档时以存档为准）
const DIFFICULTY := {
	"easy": {"name": "悠闲", "gold": 15000.0, "food_use": 0.35, "growth": 1.6, "events": 0.5, "cond": 0.5},
	"normal": {"name": "标准", "gold": 10000.0, "food_use": 0.5, "growth": 1.0, "events": 1.0, "cond": 1.0},
	"hard": {"name": "挑战", "gold": 8000.0, "food_use": 0.65, "growth": 0.7, "events": 1.8, "cond": 1.6},
}

# 启动模式（由主菜单 scene 写入静态变量后切场景）：
#   "new"  全新开局； "auto" 读自动存档； "slot" 读 boot_slot 指定存档位
static var boot_mode := "new"
static var boot_slot := 1
static var difficulty := "normal"  # 由主菜单写入

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

var walkers: Array = []  # {pos, cur, nxt, t, left, prev, kind} kind: 0居民 1挑夫 2挑水夫
var serviced: Dictionary = {}  # 居所(民居格或大院锚点) -> 最近服务月份序号
var watered: Dictionary = {}  # 居所 -> 最近送水月份序号
var evolve_prog: Dictionary = {}  # 居所 -> 连续达标月数

var population := 0
var pop_capacity := 0
var shortage_months := 0  # 连续断粮月数：满 3 个月才开始流失人口
var grain := 100.0
var flour := 0.0
var food := 20.0
var gold := 10000.0
var year := 1
var month := 1
var _months_total := 0

# 朝廷与财政
var prestige := 0  # 声望：诏令达成 +1，失败 -1
var edict: Dictionary = {}  # 当前诏令 {kind, target, deadline(总月数)}
var _edict_counter := 0
var last_tax_income := 0.0
var last_upkeep := 0.0

# 劳动与维护
var employed: Dictionary = {}  # 工业建筑格 -> 在岗人数
var jobs_total := 0
var jobs_filled := 0
var building_cond: Dictionary = {}  # 建筑/大院锚点格 -> 维护度 0..100（缺失=100）
var selected_cell := Vector2i(-1, -1)  # 左键查看的建筑/树木格

# 灾害与事件
var burning: Dictionary = {}  # 建筑格 -> 剩余燃烧月数
var locust_months_left := 0  # 蝗灾：农田减产剩余月数

var selected_tool := ""
var hover_cell := Vector2i(-1, -1)
var message := ""

var _elapsed := 0.0
var _dragging := false
var _spawn_accum := 0.0

var _rot := 0
var _cam_pos := Vector2.ZERO
var _zoom := Vector2.ONE
# 大宅立牌锚点偏移（按等级、旋转方向）：贴图实体基座近角对齐 2x2 地块前边线中点 +2px（同 1x1 建筑惯例）
# 素材底部 y 与近角 x 逐图不一致（如 estate2_d2 整体偏高 8px），故逐图常量标定
const ESTATE_GROUND_OFF := {
	2: [Vector2(-48, -74), Vector2(-58, -75), Vector2(-47, -66), Vector2(-36, -75)],
	3: [Vector2(-47, -73), Vector2(-39, -74), Vector2(-47, -74), Vector2(-56, -74)],
}

var _pop_label: Label
var _grain_label: Label
var _flour_label: Label
var _food_label: Label
var _gold_label: Label
var _date_label: Label
var _tool_label: Label
var _walker_label: Label
var _message_label: Label
var _prestige_label: Label
var _edict_label: Label
var _econ_label: Label
var _tool_buttons := {}
var _active_slot := 1
var _slot_btn: Button
var _minimap: Minimap
var _info_panel: PanelContainer
var _info_title: Label
var _info_body: Label
var _repair_btn: Button


func _ready() -> void:
	_load_pack_textures()
	_load_building_defs()
	_generate_terrain()
	_build_hud()
	_refresh_capacity()
	_assign_jobs()
	_update_hud()
	_apply_rotation(0)
	var map_center := MAP_ORIGIN + Vector2(GRID_W, GRID_H) * CELL / 2
	_cam_pos = _proj() * map_center

	gold = float(_diff("gold"))  # 新开局初始金钱（读档会被存档覆盖）

	# 按主菜单指定的启动模式读档（测试脚本直接实例化本场景时保持 "new" 不受影响）
	match boot_mode:
		"auto":
			var auto_state := SaveManager.load_auto()
			if not auto_state.is_empty():
				_apply_state(auto_state)
				_show_message("已读取自动存档（第 %d 年 %d 月）" % [year, month])
		"slot":
			var slot_state := SaveManager.load_slot(boot_slot)
			if not slot_state.is_empty():
				_active_slot = boot_slot
				_apply_state(slot_state)
				_show_message("已读取存档槽 %d（第 %d 年 %d 月）" % [boot_slot, year, month])
	boot_mode = "new"
	_update_slot_btn()


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
		elif btype == "well":
			kind = 2
		elif btype == "woodcutter":
			kind = 3
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
	_service_around(start, kind == 2)
	if kind == 3:
		_chop_adjacent_tree(start)


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


func _service_around(road_cell: Vector2i, is_water: bool = false) -> void:
	var target := watered if is_water else serviced
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if buildings.get(nb, "") == "hut" or buildings.get(nb, "") == "tilehouse":
			target[nb] = _months_total
		else:
			var anchor := _estate_anchor_at(nb)
			if anchor != Vector2i(-1, -1):
				target[anchor] = _months_total


func _update_walkers(delta: float) -> void:
	for i in range(walkers.size() - 1, -1, -1):
		var w: Dictionary = walkers[i]
		w.t += delta * WALK_SPEED
		if w.t >= 1.0:
			w.cur = w.nxt
			w.t = 0.0
			w.left -= 1
			_service_around(w.cur, int(w.get("kind", 0)) == 2)
			if int(w.get("kind", 0)) == 3:
				_chop_adjacent_tree(w.cur)
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
				_close_info_panel()
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
					_close_info_panel()
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					if selected_tool.is_empty():
						_select_at(_screen_to_cell(_mouse_grid_pos()))
					else:
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
	if selected_tool == "demolish":
		_try_demolish(cell)
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
	Sound.play("build")
	_update_hud()
	queue_redraw()


func _try_demolish(cell: Vector2i) -> void:
	var anchor := _estate_anchor_at(cell)
	if anchor != Vector2i(-1, -1):
		var tier: int = estates[anchor]
		estates.erase(anchor)
		serviced.erase(anchor)
		evolve_prog.erase(anchor)
		building_cond.erase(anchor)
		gold += 40 * tier  # 大院按等级退款
		_show_message("拆除了大院，返还 %d 金" % int(40 * tier))
	elif buildings.has(cell):
		var btype: String = buildings[cell]
		var refund := int(building_defs[btype]["cost_gold"]) / 2
		buildings.erase(cell)
		serviced.erase(cell)
		evolve_prog.erase(cell)
		building_cond.erase(cell)
		gold += refund
		_show_message("拆除了 %s，返还 %d 金" % [building_defs[btype]["name"], refund])
	elif trees.has(cell):
		const TREE_COST := 10
		if gold < TREE_COST:
			_show_message("金钱不足（砍树需 %d 金，或建伐木屋免费砍伐）" % TREE_COST)
			return
		gold -= TREE_COST
		trees.erase(cell)
		_show_message("砍除了一棵树（%d 金）" % TREE_COST)
	else:
		_show_message("这里没有可拆除的建筑")
		return
	Sound.play("demolish")
	_refresh_capacity()
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
	return _months_total - int(serviced.get(key, -999)) <= 3


func _recently_watered(key: Vector2i) -> bool:
	return _months_total - int(watered.get(key, -999)) <= 3


# 财政：分级人头税 - 建筑维护（含大院）。返回本月净收入。
func _economy_month() -> float:
	var cap_total := 0
	var tax_sum := 0.0
	for cell: Vector2i in buildings:
		var t: String = buildings[cell]
		if t == "hut" or t == "tilehouse":
			var c: int = HUT_CAP if t == "hut" else TILEHOUSE_CAP
			cap_total += c
			tax_sum += c * float(TAX_RATE[t])
	for tier: int in estates.values():
		cap_total += int(ESTATE_CAP[tier])
		tax_sum += int(ESTATE_CAP[tier]) * float(TAX_RATE[tier])
	var tax := tax_sum / cap_total * float(population) if cap_total > 0 else 0.0
	var upkeep := 0.0
	for b: String in buildings.values():
		upkeep += float(building_defs[b].get("upkeep", 0.0))
	upkeep += estates.size() * ESTATE_UPKEEP
	last_tax_income = tax
	last_upkeep = upkeep
	return tax - upkeep


# ---------- 朝廷诏令 ----------

func _edict_desc() -> String:
	if edict.is_empty():
		return "暂无诏令"
	var kind: String = edict["kind"]
	var target: int = int(edict["target"])
	var left: int = maxi(0, int(edict["deadline"]) - _months_total)
	match kind:
		"tax":
			return "诏令：%d 月内缴纳赋税 %d 金（现有 %d）" % [left, target, int(gold)]
		"tribute":
			return "诏令：%d 月内缴纳贡粮 %d 食品（现有 %d）" % [left, target, int(food)]
		"population":
			return "诏令：%d 月内人口达 %d（现有 %d）" % [left, target, population]
		"estate":
			return "诏令：%d 月内宅院达 %d 座（现有 %d）" % [left, target, estates.size()]
	return ""


func _issue_edict() -> void:
	_edict_counter += 1
	var kind: String = EDICT_CYCLE[_edict_counter % EDICT_CYCLE.size()]
	var target := 0
	match kind:
		"tax":
			target = int(100 + population * 1.5)
		"tribute":
			target = int(50 + population * 1.0)
		"population":
			target = population + maxi(5, population / 4)
		"estate":
			target = estates.size() + 1
	edict = {"kind": kind, "target": target, "deadline": _months_total + 12}
	_show_message("朝廷下达新诏令：" + _edict_desc())


func _resolve_edict() -> void:
	var kind: String = edict["kind"]
	var target: int = int(edict["target"])
	var ok := false
	match kind:
		"tax":
			ok = gold >= target
			if ok:
				gold -= target
		"tribute":
			ok = food >= target
			if ok:
				food -= target
		"population":
			ok = population >= target
		"estate":
			ok = estates.size() >= target
	if ok:
		prestige += 1
		if kind == "population" or kind == "estate":
			gold += 100
		_show_message("诏令达成，朝廷嘉奖！声望 +1")
		Sound.play("coin")
	else:
		prestige -= 1
		_show_message("诏令未达成，朝廷震怒！声望 -1")
		Sound.play("warn")
	edict = {}
	_issue_edict()


# ---------- 灾害与事件 ----------

func _events_month() -> void:
	# 火灾倒计时
	for cell: Vector2i in burning.keys():
		burning[cell] = int(burning[cell]) - 1
		if int(burning[cell]) <= 0:
			burning.erase(cell)
			var btype: String = buildings.get(cell, "")
			if not btype.is_empty():
				buildings.erase(cell)
				serviced.erase(cell)
				watered.erase(cell)
				evolve_prog.erase(cell)
				building_cond.erase(cell)
				_show_message("一场火灾烧毁了%s！" % building_defs[btype]["name"])
	_refresh_capacity()
	if locust_months_left > 0:
		locust_months_left -= 1
	# 新事件概率：月均 4%
	if randf() < 0.04 * _diff("events"):
		_trigger_event()


func _trigger_event() -> void:
	var roll := randi() % 100
	if roll < 30:
		var candidates: Array = []
		for cell: Vector2i in buildings:
			if buildings[cell] != "road" and not burning.has(cell):
				candidates.append(cell)
		if candidates.is_empty():
			return
		var cell: Vector2i = candidates[randi() % candidates.size()]
		burning[cell] = 2
		_show_message("%s起火了！两月后将被烧毁" % building_defs[buildings[cell]]["name"])
	elif roll < 50:
		if population > 0:
			var loss: int = maxi(1, population / 20)
			population -= loss
			_show_message("瘟疫流行，%d 人病亡" % loss)
	elif roll < 75:
		var farms := 0
		for b: String in buildings.values():
			if b == "farm":
				farms += 1
		var bonus := farms * 20
		grain += bonus
		_show_message("风调雨顺，农田丰收！粮食 +%d" % bonus)
	else:
		locust_months_left = 6
		_show_message("蝗灾来袭！六个月内农田减产一半")


func _advance_month() -> void:
	_months_total += 1
	_assign_jobs()

	# 生产链
	var stock := {"grain": grain, "flour": flour, "food": food}
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		var def: Dictionary = building_defs.get(btype, {})
		if not _has_adjacent_road(cell):
			continue
		var eff := _work_efficiency(cell, def)
		if eff <= 0.0:
			continue
		if def.has("grain_per_month"):
			var mult := 0.5 if locust_months_left > 0 else 1.0
			stock["grain"] = float(stock["grain"]) + float(def["grain_per_month"]) * mult * eff
		if def.has("convert_from"):
			var use: float = minf(float(def["convert_rate"]) * eff, float(stock[def["convert_from"]]))
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
	var eff_capacity := 0
	for key: Vector2i in residence_keys:
		if _recently_serviced(key):
			eff_capacity += _capacity_of(key)

	# 人口吃食品与移民迁入：有余房+有饭吃就稳定流入，连续断粮 3 个月才流失
	var fed := false
	var consumption: int = int(ceil(population * _diff("food_use")))
	if food >= consumption:
		food -= consumption
		fed = true
		shortage_months = 0
		if population < eff_capacity:
			var vacancy := eff_capacity - population
			var influx := maxi(2, int(ceil(vacancy * 0.25 * _diff("growth"))))
			population = mini(eff_capacity, population + influx)
	elif population > 0:
		food = 0.0
		shortage_months += 1
		if shortage_months <= 3:
			if grain > 0 or flour > 0:
				_show_message("有粮无食！磨坊、市集产能跟不上，百姓已在挨饿")
			else:
				_show_message("存粮不足，百姓已在挨饿（连续断粮三月将致人口流失）")
		else:
			# 断粮超三个月：无论囤了多少原粮都开始流失人口
			population = maxi(0, population - maxi(1, population / 20))
			_show_message("饥荒！人口下降")

	# 住房演进（需吃饱 + 有服务）
	_evolve_housing(fed)

	# 财政与朝廷
	gold += _economy_month()
	if edict.is_empty():
		_issue_edict()
	elif _months_total >= int(edict["deadline"]):
		_resolve_edict()

	# 灾害与事件
	_events_month()

	# 维护度自然损耗（道路不衰减；大院慢一点）；难度越高损耗越快
	var cond_decay := maxi(1, int(round(2 * _diff("cond"))))
	for cell: Vector2i in buildings:
		if buildings[cell] != "road":
			building_cond[cell] = maxi(0, _cond_of(cell) - cond_decay)
	for anchor: Vector2i in estates:
		building_cond[anchor] = maxi(0, _cond_of(anchor) - maxi(1, cond_decay / 2))

	month += 1
	if month > 12:
		month = 1
		year += 1

	# 每年自动保存一次（静默）
	if _months_total % 12 == 0:
		SaveManager.save_auto(_build_state())

	_update_hud()
	queue_redraw()


func _evolve_housing(fed: bool) -> void:
	# 茅屋 -> 瓦房（需有水喝）
	for cell: Vector2i in buildings.keys():
		if buildings.get(cell, "") != "hut":
			continue
		if fed and _recently_serviced(cell) and _recently_watered(cell):
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) + 1
			if evolve_prog[cell] >= EVOLVE_HUT:
				buildings[cell] = "tilehouse"
				evolve_prog.erase(cell)
				_show_message("一间茅屋翻修成了瓦房")
				Sound.play("evolve")
		else:
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) / 2  # 断档减半，不清零

	# 瓦房 -> 宅院（2x2 合并；合并会改动 buildings，用 .get 防快照键失效）
	for cell: Vector2i in buildings.keys():
		if buildings.get(cell, "") != "tilehouse":
			continue
		if fed and _recently_serviced(cell):
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) + 1
			if evolve_prog[cell] >= EVOLVE_MERGE and _try_merge_estate(cell):
				pass  # 合并成功后 cell 已被移除
		else:
			evolve_prog[cell] = int(evolve_prog.get(cell, 0)) / 2  # 断档减半，不清零

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
				Sound.play("evolve")
		else:
			evolve_prog[anchor] = int(evolve_prog.get(anchor, 0)) / 2  # 断档减半，不清零


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
		Sound.play("evolve")
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
	population = mini(population, pop_capacity)  # 拆除后人口不超过容量


# ---------- 劳动 / 维护 / 查看 ----------

func _diff(key: String) -> float:
	return float(DIFFICULTY.get(difficulty, DIFFICULTY["normal"]).get(key, 1.0))


func _diff_name() -> String:
	return str(DIFFICULTY.get(difficulty, DIFFICULTY["normal"])["name"])


func _capacity_of(key: Vector2i) -> int:
	var btype: String = buildings.get(key, "")
	if btype == "hut":
		return HUT_CAP
	if btype == "tilehouse":
		return TILEHOUSE_CAP
	if estates.has(key):
		return int(ESTATE_CAP[estates[key]])
	return 0


func _assign_jobs() -> void:
	## 人口即劳力，按建筑放置顺序依次填满岗位；不邻路的建筑无法开工
	employed.clear()
	jobs_total = 0
	jobs_filled = 0
	var workforce := population
	for cell: Vector2i in buildings:
		var jobs := int(building_defs[buildings[cell]].get("jobs", 0))
		if jobs <= 0:
			continue
		jobs_total += jobs
		var take := 0
		if _has_adjacent_road(cell):
			take = mini(jobs, workforce)
			workforce -= take
		employed[cell] = take
		jobs_filled += take


func _cond_of(key: Vector2i) -> int:
	return int(building_cond.get(key, 100))


func _work_efficiency(cell: Vector2i, def: Dictionary) -> float:
	## 维护度 <30 停产，<60 半产；有岗位的建筑再按在岗比例折减
	var cond := _cond_of(cell)
	if cond < 30:
		return 0.0
	var eff := 0.5 if cond < 60 else 1.0
	if def.has("jobs"):
		var jobs := int(def["jobs"])
		if jobs > 0:
			eff *= float(employed.get(cell, 0)) / jobs
	return eff


func _occupants(cap: int) -> int:
	return int(round(population * cap / pop_capacity)) if pop_capacity > 0 else 0


func _repair_cost(key: Vector2i, base_cost: int) -> int:
	return maxi(1, (100 - _cond_of(key)) * base_cost / 100)


func _chop_adjacent_tree(road_cell: Vector2i) -> void:
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if trees.has(nb):
			trees.erase(nb)
			queue_redraw()
			return


func _select_at(cell: Vector2i) -> void:
	if buildings.has(cell) or trees.has(cell) or _estate_anchor_at(cell) != Vector2i(-1, -1):
		selected_cell = cell
		_refresh_info_panel()
		Sound.play("click")
	else:
		_close_info_panel()


func _close_info_panel() -> void:
	selected_cell = Vector2i(-1, -1)
	if _info_panel:
		_info_panel.visible = false
	queue_redraw()


func _refresh_info_panel() -> void:
	if _info_panel == null or selected_cell == Vector2i(-1, -1):
		return
	var cell := selected_cell
	var anchor := _estate_anchor_at(cell)
	var key := anchor if anchor != Vector2i(-1, -1) else cell
	var lines: Array = []
	var show_repair := false
	if anchor != Vector2i(-1, -1):
		var tier: int = estates[anchor]
		_info_title.text = "豪华大宅" if tier == 3 else "宅院"
		var cap: int = ESTATE_CAP[tier]
		lines.append("居住人口：%d / %d" % [_occupants(cap), cap])
		lines.append("维护度：%d%%" % _cond_of(key))
		lines.append("服务：%s　供水：%s" % [_yesno(_recently_serviced(key)), _yesno(_recently_watered(key))])
		if tier == 2:
			lines.append("升级进度：%d / %d 月" % [int(evolve_prog.get(key, 0)), EVOLVE_ESTATE])
		show_repair = true
	elif buildings.has(cell):
		var btype: String = buildings[cell]
		_info_title.text = building_defs[btype]["name"]
		if btype == "hut" or btype == "tilehouse":
			var cap2: int = HUT_CAP if btype == "hut" else TILEHOUSE_CAP
			lines.append("居住人口：%d / %d" % [_occupants(cap2), cap2])
			lines.append("维护度：%d%%" % _cond_of(key))
			lines.append("服务：%s　供水：%s" % [_yesno(_recently_serviced(key)), _yesno(_recently_watered(key))])
			if btype == "hut":
				lines.append("升级进度：%d / %d 月" % [int(evolve_prog.get(key, 0)), EVOLVE_HUT])
			else:
				lines.append("升级进度：%d / %d 月" % [int(evolve_prog.get(key, 0)), EVOLVE_MERGE])
		elif btype == "road":
			lines.append("供行人通行，连接建筑。")
		else:
			var def: Dictionary = building_defs[btype]
			if int(def.get("jobs", 0)) > 0:
				var jobs := int(def["jobs"])
				var on := int(employed.get(key, 0))
				lines.append("岗位：%d　在岗：%d（效率 %d%%）" % [jobs, on, int(_work_efficiency(key, def) * 100)])
			lines.append("维护度：%d%%" % _cond_of(key))
			if def.has("grain_per_month"):
				lines.append("粮产：每月 %d（需有人劳作）" % int(def["grain_per_month"]))
			if btype == "woodcutter":
				lines.append("伐木工沿路巡行，免费砍除路边树木。")
		show_repair = btype != "road"
	elif trees.has(cell):
		_info_title.text = "树木"
		lines.append("遮挡建造。可花 10 金立刻砍除，")
		lines.append("或建伐木屋派工人免费缓慢砍伐。")
	_info_body.text = "
".join(lines)
	if show_repair:
		var base := 40 * int(estates.get(key, 1)) if anchor != Vector2i(-1, -1) else int(building_defs[buildings[cell]]["cost_gold"])
		var cost := _repair_cost(key, base)
		_repair_btn.visible = true
		_repair_btn.text = "修缮（%d 金）" % cost
		_repair_btn.disabled = _cond_of(key) >= 100 or gold < cost
	else:
		_repair_btn.visible = false
	_info_panel.visible = true


func _yesno(v: bool) -> String:
	return "有" if v else "无"


func _on_repair_pressed() -> void:
	var cell := selected_cell
	var anchor := _estate_anchor_at(cell)
	var key := anchor if anchor != Vector2i(-1, -1) else cell
	var base := 40 * int(estates.get(key, 1)) if anchor != Vector2i(-1, -1) else int(building_defs[buildings[cell]]["cost_gold"])
	var cost := _repair_cost(key, base)
	if _cond_of(key) >= 100 or gold < cost:
		return
	gold -= cost
	building_cond[key] = 100
	_show_message("修缮完成")
	Sound.play("coin")
	_update_hud()
	_refresh_info_panel()
	queue_redraw()


func _on_panel_demolish_pressed() -> void:
	var cell := selected_cell
	_close_info_panel()
	_try_demolish(cell)


# ---------- 存档 ----------

func _build_state() -> Dictionary:
	var list := []
	for cell: Vector2i in buildings:
		list.append({"x": cell.x, "y": cell.y, "type": buildings[cell]})
	var estate_list := []
	for anchor: Vector2i in estates:
		estate_list.append({"x": anchor.x, "y": anchor.y, "tier": estates[anchor]})
	var tree_list := []
	for cell: Vector2i in trees:
		tree_list.append({"x": cell.x, "y": cell.y})
	var cond_list := []
	for key: Vector2i in building_cond:
		cond_list.append({"x": key.x, "y": key.y, "cond": building_cond[key]})
	return {
		"population": population,
		"grain": grain,
		"flour": flour,
		"food": food,
		"gold": gold,
		"year": year,
		"month": month,
		"months_total": _months_total,
		"difficulty": difficulty,
		"shortage": shortage_months,
		"prestige": prestige,
		"edict": edict,
		"edict_counter": _edict_counter,
		"buildings": list,
		"estates": estate_list,
		"trees": tree_list,
		"conds": cond_list,
	}


func _apply_state(state: Dictionary) -> void:
	population = int(state["population"])
	grain = float(state["grain"])
	flour = float(state.get("flour", 0.0))
	food = float(state.get("food", 20.0))
	gold = float(state["gold"])
	year = int(state["year"])
	month = int(state["month"])
	_months_total = int(state.get("months_total", (year - 1) * 12 + month))
	difficulty = str(state.get("difficulty", "normal"))
	shortage_months = int(state.get("shortage", 0))
	prestige = int(state.get("prestige", 0))
	edict = state.get("edict", {})
	_edict_counter = int(state.get("edict_counter", 0))
	buildings.clear()
	estates.clear()
	trees.clear()
	serviced.clear()
	watered.clear()
	walkers.clear()
	evolve_prog.clear()
	burning.clear()
	building_cond.clear()
	employed.clear()
	locust_months_left = 0
	shortage_months = 0
	for entry: Dictionary in state.get("conds", []):
		building_cond[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["cond"])
	for entry: Dictionary in state["buildings"]:
		buildings[Vector2i(int(entry["x"]), int(entry["y"]))] = String(entry["type"])
	for entry: Dictionary in state.get("estates", []):
		estates[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["tier"])
	for entry: Dictionary in state.get("trees", []):
		trees[Vector2i(int(entry["x"]), int(entry["y"]))] = true
	_refresh_capacity()
	_update_hud()
	_update_slot_btn()
	queue_redraw()


func _on_save_pressed() -> void:
	var err := SaveManager.save_slot(_active_slot, _build_state())
	_update_slot_btn()
	_show_message("已保存到存档槽 %d" % _active_slot if err == OK else "保存失败")


func _on_load_pressed() -> void:
	var state := SaveManager.load_slot(_active_slot)
	if state.is_empty():
		_show_message("存档槽 %d 是空的" % _active_slot)
		return
	_apply_state(state)
	_show_message("已读取存档槽 %d" % _active_slot)


func _on_slot_cycle_pressed() -> void:
	_active_slot = _active_slot % SaveManager.SLOT_COUNT + 1  # 1 -> 2 -> 3 -> 1
	_update_slot_btn()


func _update_slot_btn() -> void:
	if _slot_btn == null:
		return
	var info := SaveManager.slot_info(_active_slot)
	if info.is_empty():
		_slot_btn.text = "存档槽 %d（空，点击切换）" % _active_slot
	else:
		_slot_btn.text = "存档槽 %d｜第%d年%d月 人口%d（点击切换）" % [
			_active_slot, int(info.get("year", 1)), int(info.get("month", 1)), int(info.get("population", 0))]


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ---------- HUD ----------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	add_child(layer)

	_minimap = Minimap.new()
	_minimap.main = self
	_minimap.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_minimap.position = Vector2(12, -132)
	layer.add_child(_minimap)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	panel.position = Vector2(-284, -320)
	panel.custom_minimum_size = Vector2(268, 640)
	layer.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)

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
	_econ_label = Label.new()
	box.add_child(_econ_label)
	_prestige_label = Label.new()
	box.add_child(_prestige_label)
	_edict_label = Label.new()
	_edict_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_edict_label)
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

	var demo_btn := Button.new()
	demo_btn.text = "拆除（返还半价）"
	demo_btn.toggle_mode = true
	demo_btn.pressed.connect(_on_tool_selected.bind("demolish"))
	box.add_child(demo_btn)
	_tool_buttons["demolish"] = demo_btn

	var cancel_btn := Button.new()
	cancel_btn.text = "取消建造"
	cancel_btn.pressed.connect(_on_tool_selected.bind(""))
	box.add_child(cancel_btn)

	var sep2 := HSeparator.new()
	box.add_child(sep2)

	_slot_btn = Button.new()
	_slot_btn.pressed.connect(_on_slot_cycle_pressed)
	box.add_child(_slot_btn)

	var save_btn := Button.new()
	save_btn.text = "保存到当前槽"
	save_btn.pressed.connect(_on_save_pressed)
	box.add_child(save_btn)

	var load_btn := Button.new()
	load_btn.text = "读取当前槽"
	load_btn.pressed.connect(_on_load_pressed)
	box.add_child(load_btn)

	# 游戏内难度切换（立即生效，随存档保存）
	var diff_row := HBoxContainer.new()
	box.add_child(diff_row)
	var diff_label := Label.new()
	diff_label.text = "难度："
	diff_row.add_child(diff_label)
	var diff_opt := OptionButton.new()
	diff_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var diff_keys := ["easy", "normal", "hard"]
	for d: String in diff_keys:
		diff_opt.add_item(str(DIFFICULTY[d]["name"]))
	diff_opt.selected = maxi(0, diff_keys.find(difficulty))
	diff_opt.item_selected.connect(func(idx: int) -> void:
		difficulty = diff_keys[idx]
		_update_hud()
		_show_message("难度已切换为：%s" % _diff_name()))
	diff_row.add_child(diff_opt)

	var menu_btn := Button.new()
	menu_btn.text = "返回主菜单"
	menu_btn.pressed.connect(_on_menu_pressed)
	box.add_child(menu_btn)

	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_message_label)

	var help_label := Label.new()
	help_label.text = "滚轮缩放 | 中键/WASD平移 | Q/E旋转"
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help_label)

	# 建筑查看面板（左键点建筑弹出，默认隐藏）
	_info_panel = PanelContainer.new()
	_info_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_info_panel.position = Vector2(-580, -252)
	_info_panel.custom_minimum_size = Vector2(280, 0)
	_info_panel.visible = false
	layer.add_child(_info_panel)
	var ibox := VBoxContainer.new()
	_info_panel.add_child(ibox)
	_info_title = Label.new()
	_info_title.add_theme_font_size_override("font_size", 18)
	ibox.add_child(_info_title)
	_info_body = Label.new()
	_info_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ibox.add_child(_info_body)
	_repair_btn = Button.new()
	_repair_btn.pressed.connect(_on_repair_pressed)
	ibox.add_child(_repair_btn)
	var panel_demo_btn := Button.new()
	panel_demo_btn.text = "拆除该建筑"
	panel_demo_btn.pressed.connect(_on_panel_demolish_pressed)
	ibox.add_child(panel_demo_btn)
	var panel_close_btn := Button.new()
	panel_close_btn.text = "关闭"
	panel_close_btn.pressed.connect(_close_info_panel)
	ibox.add_child(panel_close_btn)


func _on_tool_selected(type: String) -> void:
	Sound.play("click")
	selected_tool = type
	for tool: String in _tool_buttons:
		_tool_buttons[tool].set_pressed_no_signal(tool == type)
	var building_name := "无"
	if building_defs.has(type):
		building_name = building_defs[type]["name"]
	elif type == "demolish":
		building_name = "拆除"
	if _tool_label:
		_tool_label.text = "当前工具：%s（右键/Esc 取消）" % building_name
	_show_message("已选择：%s" % building_name)


func _update_hud() -> void:
	_date_label.text = "第 %d 年 %d 月 · %s" % [year, month, _diff_name()]
	_pop_label.text = "人口：%d / %d（就业 %d/%d）" % [population, pop_capacity, jobs_filled, jobs_total]
	_grain_label.text = "粮食：%d" % int(grain)
	_flour_label.text = "面粉：%d" % int(flour)
	_food_label.text = "食品：%d" % int(food)
	_gold_label.text = "金钱：%d" % int(gold)
	_econ_label.text = "月税 %.1f − 维护 %.1f" % [last_tax_income, last_upkeep]
	_prestige_label.text = "朝廷声望：%d" % prestige
	_edict_label.text = _edict_desc()
	_walker_label.text = "行人：%d" % walkers.size()
	if _info_panel and _info_panel.visible:
		_refresh_info_panel()


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
			var ftint := Color(1, 0.45, 0.35) if burning.has(cell) else Color.WHITE
			if btype == "road":
				draw_texture(_road_tex(cell), MAP_ORIGIN + Vector2(cell) * CELL)
			else:
				draw_texture(_building_tex(btype), MAP_ORIGIN + Vector2(cell) * CELL, ftint)

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
			var wkind := int(w.get("kind", 0))
			var tint := Color.WHITE
			if wkind == 1:
				tint = Color(0.95, 0.78, 0.6)  # 挑夫：暖色
			elif wkind == 2:
				tint = Color(0.62, 0.8, 0.98)  # 挑水夫：蓝色
			elif wkind == 3:
				tint = Color(0.55, 0.75, 0.45)  # 伐木工：草绿
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
			draw_texture(etex, ESTATE_GROUND_OFF[tier][_rot])
			draw_set_transform_matrix(Transform2D())
			continue
		var cell: Vector2i = item[1]
		var base: Vector2 = _proj() * (MAP_ORIGIN + Vector2(cell) * CELL + Vector2(CELL / 2, CELL))
		draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, base))
		if item[2] == "tree":
			draw_texture(tree_tex, Vector2(-20, -54))
		else:
			var btint := Color(1, 0.45, 0.35) if burning.has(cell) else Color.WHITE
			draw_texture(_building_tex(item[2]), Vector2(-16, -30), btint)
	draw_set_transform_matrix(Transform2D())

	# 选中建筑高亮（金色框，大院描 2x2）
	if selected_cell != Vector2i(-1, -1):
		var s_anchor := _estate_anchor_at(selected_cell)
		var s_origin := s_anchor if s_anchor != Vector2i(-1, -1) else selected_cell
		var s_cells := 2 if s_anchor != Vector2i(-1, -1) else 1
		var sp0 := MAP_ORIGIN + Vector2(s_origin) * CELL
		var sc2 := [sp0, sp0 + Vector2(CELL * s_cells, 0), sp0 + Vector2(CELL * s_cells, CELL * s_cells), sp0 + Vector2(0, CELL * s_cells)]
		draw_polyline(sc2 + [sc2[0]], Color(1.0, 0.88, 0.35), 2.0)

	# 悬停预览
	if _in_bounds(hover_cell) and not selected_tool.is_empty():
		var p0 := MAP_ORIGIN + Vector2(hover_cell) * CELL
		var corners := [p0, p0 + Vector2(CELL, 0), p0 + Vector2(CELL, CELL), p0 + Vector2(0, CELL)]
		if selected_tool == "demolish":
			# 拆除模式：有建筑显红框，没有显灰框
			var can_demo := _estate_anchor_at(hover_cell) != Vector2i(-1, -1) or buildings.has(hover_cell) or trees.has(hover_cell)
			draw_colored_polygon(corners, Color(0.9, 0.3, 0.3, 0.3) if can_demo else Color(0.5, 0.5, 0.5, 0.2))
			draw_polyline(corners + [corners[0]], Color(0.9, 0.3, 0.3) if can_demo else Color(0.5, 0.5, 0.5), 1.5)
		else:
			var valid := not _is_occupied(hover_cell)
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
