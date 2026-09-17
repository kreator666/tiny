class_name Main
extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 渲染：45° 斜投影（菱形地砖）+ 建筑立牌（billboard）+ 深度排序遮挡。
##       立牌建筑带四方向贴图，随视角旋转切换；贴地 tile 随投影自动转向。
## 视角：滚轮缩放（以鼠标为中心）、中键拖拽平移、WASD/方向键平移、Q/E 旋转 90°。
## 核心玩法：
##   生产链：水稻田/麦田 -> 磨坊 -> 大米/面粉 -> 粮油店 -> 一级食品 -> 民居。
##     大豆 -> 油坊 -> 豆油 ┐
##     葡萄 -> 酒坊 -> 葡萄酒 ┴ 二级食品（宅院升级豪华大宅所需）。
##     棉花 -> 织布坊 -> 布匹，连同豆油/葡萄酒由市集售卖换金钱。
##     大米/面粉/豆油/葡萄酒各生产过一次后，商业解锁酒楼。
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
const CELL := 48
const MAP_ORIGIN := Vector2(16, 16)
const MONTH_SECONDS := 2.0

const ZOOM_MIN := 0.4
const ZOOM_MAX := 3.0
const ZOOM_STEP := 1.15
const PAN_SPEED := 600.0  # 世界像素/秒
const HUD_WIDTH := 332.0  # 右侧三卡片导航栏宽 320 + 边距 12

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
const WALKER_SCALE := 2.0  # 行人贴图放大倍数（原图 18x30，直接显示太小看不清）

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
# DEBUG 模式（仅开发者）：用命令行参数启动（见 tools/run_debug.bat），最终用户双击 exe 不会携带参数。
# 该模式下各项数值只增不减：资源不消耗、人口不流失、维护不衰减、火灾不损毁、建造修缮免费，并禁止存档。
static var debug_mode := false


static func detect_debug_mode() -> void:
	## 识别开发者命令行参数：xinsong-zhisuo.exe -- --debug
	for arg: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if arg == "--debug":
			debug_mode = true
			return

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

var walkers: Array = []  # {pos, cur, nxt, t, left, prev, kind} kind: 0居民 1挑夫 2挑水夫 3伐木工 4郎中 5工匠
var serviced: Dictionary = {}  # 居所(民居格或大院锚点) -> 最近服务月份序号
var watered: Dictionary = {}  # 居所 -> 最近送水月份序号
var doctored: Dictionary = {}  # 居所 -> 最近诊治病月份序号（医馆郎中）
var evolve_prog: Dictionary = {}  # 居所 -> 连续达标月数

var population := 0
var pop_capacity := 0
var shortage_months := 0  # 连续断粮月数：满 3 个月才开始流失人口
# 资源：五种作物 -> 加工品 -> 食品（货品价格见 buildings.json 的 sells）
var paddy := 60.0  # 水稻
var wheat := 0.0  # 小麦
var cotton := 0.0  # 棉花
var soy := 0.0  # 大豆
var grape := 0.0  # 葡萄
var rice := 0.0  # 大米（磨坊出品，一级食品原料）
var flour := 0.0  # 面粉（磨坊出品，一级食品原料）
var oil := 0.0  # 豆油（油坊出品，二级食品）
var wine := 0.0  # 葡萄酒（酒坊出品，二级食品）
var cloth := 0.0  # 布匹（织布坊出品，市集售卖）
var food := 20.0  # 一级食品（粮油店出品，供百姓食用）
var wood := 0.0  # 木材：伐木屋产出，维修站修缮消耗
var gold := 10000.0
var year := 1
var month := 1
var _months_total := 0

# 酒楼解锁：大米/面粉/豆油/葡萄酒 各生产过一次后点亮
var foods_produced := {"rice": false, "flour": false, "oil": false, "wine": false}
var restaurant_unlocked := false

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
var plague_months_left := 0  # 瘟疫：流行剩余月数（每月病亡，医馆诊治可减灾）

var selected_tool := ""
var hover_cell := Vector2i(-1, -1)
var message := ""

var _elapsed := 0.0
var _anim_t := 0.0  # 动画时钟（水车/炊烟/行人/火灾），_process 累计
var _dragging := false
var _spawn_accum := 0.0

var _rot := 0
var _cam_pos := Vector2.ZERO
var _zoom := Vector2.ONE

# 立牌/大宅贴图锚点约定：贴图底影中心 = (图宽/2, 图高-8)（AI 素材已逐张校验，四方向一致），
# 偏移按贴图尺寸计算（_billboard_off / _estate_off）。
# 锚点四方向恒定：菱形地砖旋转 90° 后与自身重合，单格建筑取格子中心、大院取 2x2 地块中心。
const ESTATE_GROUND_MARGIN := 8
const BILLBOARD_ANCHOR := Vector2(0.5, 0.5)
const ESTATE_CENTER := Vector2(1.0, 1.0)

# 烟囱冒烟的建筑及其出烟点（相对建筑基座触地点的屏幕偏移，截图校订）
# 冒烟建筑：烟圈起点（相对格原点=格底部中心，y 向上为负）；仅贴图带烟囱的建筑
const SMOKE_BUILDINGS := {
	"mill": Vector2(-19, -62),
	"winery": Vector2(-13, -71),
}

# 建造菜单分类（法老王式）：一级为分类方块 + 道路/拆除，二级为分类内建筑
const BUILD_MENU := {
	"住宅": ["hut"],
	"农业": ["farm", "wheat", "cotton", "soy", "grape", "mill"],
	"商业": ["grocer", "market", "winery", "oilpress", "restaurant"],
	"市政": ["well", "clinic", "repair"],
	"工业": ["woodcutter", "loom"],
}

const CROP_NAMES := {"paddy": "水稻", "wheat": "小麦", "cotton": "棉花", "soy": "大豆", "grape": "葡萄"}
const GOODS_NAMES := {"rice": "大米", "flour": "面粉", "oil": "豆油", "wine": "葡萄酒",
	"cloth": "布匹", "food": "一级食品", "wood": "木材", "gold": "金钱"}


func _res_name(key: String) -> String:
	return CROP_NAMES.get(key, GOODS_NAMES.get(key, key))

var _pop_label: Label
var _grain_label: Label
var _flour_label: Label
var _food_label: Label
var _wood_label: Label
var _gold_label: Label
var _date_label: Label
var _tool_label: Label
var _walker_label: Label
var _message_label: Label
var _prestige_label: Label
var _edict_label: Label
var _econ_label: Label
var _tool_buttons := {}
var _menu_box: VBoxContainer  # 建造菜单容器（两级：分类 -> 建筑）
var _menu_cat := ""  # 当前二级菜单分类名（空 = 一级分类页）
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
	if debug_mode:
		_show_message("DEBUG 模式：各项数值只增不减，禁止存档")


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
		elif btype == "clinic":
			kind = 4
		elif btype == "repair":
			kind = 5
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
	elif kind == 4:
		_doctor_around(start)
	elif kind == 5:
		_repair_around(start)


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


func _doctor_around(road_cell: Vector2i) -> void:
	# 郎中为邻路居所诊治（医馆服务，瘟疫期保命）
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if buildings.get(nb, "") == "hut" or buildings.get(nb, "") == "tilehouse":
			doctored[nb] = _months_total
		else:
			var anchor := _estate_anchor_at(nb)
			if anchor != Vector2i(-1, -1):
				doctored[anchor] = _months_total


func _repair_around(road_cell: Vector2i) -> void:
	# 工匠为邻路建筑恢复维护度（1 木材 +10），并扑灭火灾（2 木材）；DEBUG 不耗木材
	for dir: Vector2i in DIRS:
		var nb := road_cell + dir
		if burning.has(nb):
			if debug_mode or wood >= 2.0:
				if not debug_mode:
					wood -= 2.0
				burning.erase(nb)
				_show_message("工匠扑灭了一场火灾！")
			continue
		if buildings.has(nb) and buildings[nb] != "road":
			if building_cond.get(nb, 100) < 100 and (debug_mode or wood >= 1.0):
				if not debug_mode:
					wood -= 1.0
				building_cond[nb] = mini(100, _cond_of(nb) + 10)
			continue
		var anchor := _estate_anchor_at(nb)
		if anchor != Vector2i(-1, -1) and building_cond.get(anchor, 100) < 100 and (debug_mode or wood >= 1.0):
			if not debug_mode:
				wood -= 1.0
			building_cond[anchor] = mini(100, _cond_of(anchor) + 10)


func _update_walkers(delta: float) -> void:
	for i in range(walkers.size() - 1, -1, -1):
		var w: Dictionary = walkers[i]
		w.t += delta * WALK_SPEED
		if w.t >= 1.0:
			w.cur = w.nxt
			w.t = 0.0
			w.left -= 1
			var wkind := int(w.get("kind", 0))
			_service_around(w.cur, wkind == 2)
			if wkind == 3:
				_chop_adjacent_tree(w.cur)
			elif wkind == 4:
				_doctor_around(w.cur)
			elif wkind == 5:
				_repair_around(w.cur)
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
	if bool(def.get("locked", false)) and not restaurant_unlocked:
		_show_message("酒楼尚未解锁：需生产过 大米、面粉、豆油、葡萄酒 四种食品")
		return
	if gold < int(def["cost_gold"]):
		_show_message("金钱不足")
		return
	if not debug_mode:
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
		if not debug_mode and gold < TREE_COST:
			_show_message("金钱不足（砍树需 %d 金，或建伐木屋免费砍伐）" % TREE_COST)
			return
		if not debug_mode:
			gold -= TREE_COST
		trees.erase(cell)
		_show_message("砍除了一棵树（%d 金）" % (0 if debug_mode else TREE_COST))
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
	_anim_t += delta

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

	var new_hover := _screen_to_cell(_mouse_grid_pos())
	if new_hover != hover_cell:
		hover_cell = new_hover

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

	queue_redraw()  # 动画（水车/炊烟/行人/火灾）需要逐帧重绘


func _recently_serviced(key: Vector2i) -> bool:
	return _months_total - int(serviced.get(key, -999)) <= 3


func _recently_watered(key: Vector2i) -> bool:
	return _months_total - int(watered.get(key, -999)) <= 3


func _recently_doctored(key: Vector2i) -> bool:
	return _months_total - int(doctored.get(key, -999)) <= 3


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
			if ok and not debug_mode:
				gold -= target
		"tribute":
			ok = food >= target
			if ok and not debug_mode:
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
		if not debug_mode:
			prestige -= 1
		_show_message("诏令未达成，朝廷震怒！声望 %s" % ("不变（DEBUG）" if debug_mode else "-1"))
		Sound.play("warn")
	edict = {}
	_issue_edict()


# ---------- 灾害与事件 ----------

func _events_month() -> void:
	# 火灾倒计时（DEBUG：火灾自行熄灭，不烧毁建筑）
	for cell: Vector2i in burning.keys():
		burning[cell] = int(burning[cell]) - 1
		if int(burning[cell]) <= 0:
			burning.erase(cell)
			if debug_mode:
				continue
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
	# 瘟疫流行：每月病亡，医馆诊治覆盖可减八成
	if plague_months_left > 0:
		plague_months_left -= 1
		if population > 0:
			var covered := 0
			for cell: Vector2i in buildings:
				if (buildings[cell] == "hut" or buildings[cell] == "tilehouse") and _recently_doctored(cell):
					covered += _capacity_of(cell)
			for anchor: Vector2i in estates:
				if _recently_doctored(anchor):
					covered += _capacity_of(anchor)
			var coverage := minf(1.0, float(covered) / maxf(1.0, float(pop_capacity)))
			var loss: int = maxi(1, int(round(population * 0.12 * (1.0 - coverage * 0.85))))
			if not debug_mode:
				population = maxi(0, population - loss)
			if coverage >= 0.99:
				_show_message("瘟疫流行，所幸医馆诊治及时，仅 %d 人病亡" % loss)
			else:
				_show_message("瘟疫流行，%d 人病亡！医馆诊治可保百姓平安" % loss)
		if plague_months_left <= 0:
			_show_message("瘟疫终于消退了")
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
		plague_months_left = 3
		_show_message("瘟疫爆发！未来三月人口将持续病亡，速建医馆派郎中医治")
	elif roll < 75:
		# 风调雨顺：五种作物田各丰收 +10
		var gained: Array = []
		for b: String in buildings.values():
			var bdef: Dictionary = building_defs.get(b, {})
			if bdef.has("crop"):
				var crop: String = bdef["crop"]
				set(crop, float(get(crop)) + 10.0)
				gained.append(CROP_NAMES[crop])
		if gained.is_empty():
			return
		_show_message("风调雨顺，%s丰收！" % "、".join(gained))
	else:
		locust_months_left = 6
		_show_message("蝗灾来袭！六个月内农田减产一半")


func _note_produced(item: String, amount: float) -> void:
	## 记录四种食品的首产，集齐后解锁酒楼
	if amount <= 0.0 or not foods_produced.has(item) or foods_produced[item]:
		return
	foods_produced[item] = true
	if restaurant_unlocked:
		return
	for done: bool in foods_produced.values():
		if not done:
			return
	restaurant_unlocked = true
	_show_message("四种食品齐备（大米、面粉、豆油、葡萄酒），商业解锁酒楼！")
	Sound.play("evolve")
	# 建造菜单里的酒楼按钮由置灰转为可点：重建当前菜单视图
	if _menu_box:
		if _menu_cat.is_empty():
			_show_build_menu_root()
		else:
			_show_build_menu_category(_menu_cat)


func _advance_month() -> void:
	_months_total += 1
	_assign_jobs()

	# 生产链：作物 -> 加工（磨坊/油坊/酒坊/织布坊）-> 粮油店/市集/酒楼
	var stock := {
		"paddy": paddy, "wheat": wheat, "cotton": cotton, "soy": soy, "grape": grape,
		"rice": rice, "flour": flour, "oil": oil, "wine": wine, "cloth": cloth,
		"food": food, "wood": wood, "gold": gold,
	}
	# DEBUG 模式：记录月初库存下限，月末任何资源跌破月初值都会被抬回（只增不减）
	var stock_floor := {}
	for k: String in stock:
		stock_floor[k] = stock[k]
	for cell: Vector2i in buildings:
		var btype: String = buildings[cell]
		var def: Dictionary = building_defs.get(btype, {})
		if not _has_adjacent_road(cell):
			continue
		var eff := _work_efficiency(cell, def)
		if eff <= 0.0:
			continue
		if def.has("crop"):
			var mult := 0.5 if locust_months_left > 0 else 1.0
			stock[def["crop"]] = float(stock[def["crop"]]) + float(def["crop_per_month"]) * mult * eff
		if def.has("wood_per_month"):
			stock["wood"] = float(stock["wood"]) + float(def["wood_per_month"]) * eff
		for cv: Dictionary in def.get("converts", []):
			var use: float = minf(float(cv["rate"]) * eff, float(stock[cv["from"]]))
			if use > 0.0:
				stock[cv["from"]] = float(stock[cv["from"]]) - use
				stock[cv["to"]] = float(stock[cv["to"]]) + use
				_note_produced(str(cv["to"]), use)
		if def.has("sells"):
			# 市集：按 葡萄酒->豆油->布匹 顺序售卖，每月限量 sell_rate 件
			var quota: float = float(def["sell_rate"]) * eff
			for item: String in def["sells"]:
				var n: float = minf(quota, float(stock[item]))
				if n <= 0.0:
					continue
				stock[item] = float(stock[item]) - n
				stock["gold"] = float(stock["gold"]) + n * float(def["sells"][item])
				quota -= n
		if def.has("consumes"):
			# 酒楼：四种食品都够才开张，按缺料比例折减产出
			var ratio := 1.0
			for item: String in def["consumes"]:
				ratio = minf(ratio, float(stock[item]) / (float(def["consumes"][item]) * eff))
			if ratio > 0.0:
				for item: String in def["consumes"]:
					stock[item] = float(stock[item]) - float(def["consumes"][item]) * eff * ratio
				stock["gold"] = float(stock["gold"]) + float(def["income"]) * eff * ratio
	paddy = stock["paddy"]
	wheat = stock["wheat"]
	cotton = stock["cotton"]
	soy = stock["soy"]
	grape = stock["grape"]
	rice = stock["rice"]
	flour = stock["flour"]
	oil = stock["oil"]
	wine = stock["wine"]
	cloth = stock["cloth"]
	food = stock["food"]
	wood = stock["wood"]
	gold = stock["gold"]
	if debug_mode:
		for k: String in stock_floor:
			set(k, maxf(float(get(k)), float(stock_floor[k])))

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
	if debug_mode:
		# DEBUG：百姓永不挨饿、人口只增不减
		fed = true
		shortage_months = 0
		if population < eff_capacity:
			var vacancy2 := eff_capacity - population
			var influx2 := maxi(2, int(ceil(vacancy2 * 0.25 * _diff("growth"))))
			population = mini(eff_capacity, population + influx2)
	elif food >= consumption:
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
			if rice > 0 or flour > 0:
				_show_message("有米面无食！粮油店产能跟不上，百姓已在挨饿")
			elif paddy > 0 or wheat > 0:
				_show_message("有粮无米面！磨坊产能跟不上，百姓已在挨饿")
			else:
				_show_message("存粮不足，百姓已在挨饿（连续断粮三月将致人口流失）")
		else:
			# 断粮超三个月：无论囤了多少原粮都开始流失人口
			population = maxi(0, population - maxi(1, population / 20))
			_show_message("饥荒！人口下降")

	# 住房演进（需吃饱 + 有服务）
	_evolve_housing(fed)

	# 财政与朝廷（DEBUG：净收入为负时不扣钱，只增不减）
	var net := _economy_month()
	gold += maxf(0.0, net) if debug_mode else net
	if edict.is_empty():
		_issue_edict()
	elif _months_total >= int(edict["deadline"]):
		_resolve_edict()

	# 灾害与事件
	_events_month()

	# 维护度自然损耗（道路不衰减；大院慢一点）；难度越高损耗越快（DEBUG：不衰减）
	if not debug_mode:
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

	# 每年自动保存一次（静默；DEBUG 模式禁止存档）
	if _months_total % 12 == 0 and not debug_mode:
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

	# 宅院 -> 豪华大宅（每月还需消耗 1 份二级食品：葡萄酒或豆油）
	for anchor: Vector2i in estates.keys():
		if estates[anchor] != 2:
			continue
		if fed and _recently_serviced(anchor) and _consume_luxury():
			evolve_prog[anchor] = int(evolve_prog.get(anchor, 0)) + 1
			if evolve_prog[anchor] >= EVOLVE_ESTATE:
				estates[anchor] = 3
				evolve_prog.erase(anchor)
				_show_message("一座宅院扩建成了豪华大宅！")
				Sound.play("evolve")
		else:
			evolve_prog[anchor] = int(evolve_prog.get(anchor, 0)) / 2  # 断档减半，不清零


func _consume_luxury() -> bool:
	## 消耗 1 份二级食品（优先葡萄酒），供宅院升级豪华大宅；DEBUG 只验库存不扣减
	if debug_mode:
		return wine >= 1.0 or oil >= 1.0
	if wine >= 1.0:
		wine -= 1.0
		return true
	if oil >= 1.0:
		oil -= 1.0
		return true
	return false


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
	if not debug_mode:
		population = mini(population, pop_capacity)  # 拆除后人口不超过容量（DEBUG 不削人口）


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
			wood += 1.0  # 砍树得木材
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
		lines.append("服务：%s　供水：%s　诊治：%s" % [_yesno(_recently_serviced(key)), _yesno(_recently_watered(key)), _yesno(_recently_doctored(key))])
		if tier == 2:
			lines.append("升级进度：%d / %d 月" % [int(evolve_prog.get(key, 0)), EVOLVE_ESTATE])
			lines.append("二级食品：葡萄酒 %d ｜ 豆油 %d（升级每月消耗 1）" % [int(wine), int(oil)])
		show_repair = true
	elif buildings.has(cell):
		var btype: String = buildings[cell]
		_info_title.text = building_defs[btype]["name"]
		if btype == "hut" or btype == "tilehouse":
			var cap2: int = HUT_CAP if btype == "hut" else TILEHOUSE_CAP
			lines.append("居住人口：%d / %d" % [_occupants(cap2), cap2])
			lines.append("维护度：%d%%" % _cond_of(key))
			lines.append("服务：%s　供水：%s　诊治：%s" % [_yesno(_recently_serviced(key)), _yesno(_recently_watered(key)), _yesno(_recently_doctored(key))])
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
			if def.has("crop"):
				lines.append("产出：每月 %d %s（需有人劳作）" % [int(def["crop_per_month"]), CROP_NAMES[def["crop"]]])
			if def.has("converts"):
				var parts: Array = []
				for cv: Dictionary in def["converts"]:
					parts.append("%s→%s %d" % [_res_name(cv["from"]), _res_name(cv["to"]), int(cv["rate"])])
				lines.append("加工：%s /月" % "，".join(parts))
			if def.has("sells"):
				var parts2: Array = []
				for item: String in def["sells"]:
					parts2.append("%s %d金" % [_res_name(item), int(def["sells"][item])])
				lines.append("售卖：%s，每月至多 %d 件" % ["、".join(parts2), int(def["sell_rate"])])
			if def.has("consumes"):
				var parts3: Array = []
				for item: String in def["consumes"]:
					parts3.append("%s×%d" % [_res_name(item), int(def["consumes"][item])])
				lines.append("消耗：%s /月 → 产出 %d 金" % ["、".join(parts3), int(def["income"])])
			if def.has("wood_per_month"):
				lines.append("木产：每月 %d（需有人劳作）" % int(def["wood_per_month"]))
			if btype == "woodcutter":
				lines.append("伐木工沿路巡行砍树，每棵 +1 木材。")
			elif btype == "clinic":
				lines.append("郎中沿路巡诊；诊治过的百姓瘟疫期减伤八成。")
			elif btype == "repair":
				lines.append("工匠沿路修缮：1 木材 +10%% 维护度，2 木材扑灭火灾。")
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
	if not debug_mode:
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
		"paddy": paddy,
		"wheat": wheat,
		"cotton": cotton,
		"soy": soy,
		"grape": grape,
		"rice": rice,
		"flour": flour,
		"oil": oil,
		"wine": wine,
		"cloth": cloth,
		"food": food,
		"wood": wood,
		"gold": gold,
		"foods_produced": foods_produced,
		"year": year,
		"month": month,
		"months_total": _months_total,
		"difficulty": difficulty,
		"shortage": shortage_months,
		"prestige": prestige,
		"edict": edict,
		"edict_counter": _edict_counter,
		"plague": plague_months_left,
		"buildings": list,
		"estates": estate_list,
		"trees": tree_list,
		"conds": cond_list,
	}


func _apply_state(state: Dictionary) -> void:
	population = int(state["population"])
	# 旧档只有 grain（粮食）：折算为水稻，其余作物从零开始
	paddy = float(state.get("paddy", state.get("grain", 0.0)))
	wheat = float(state.get("wheat", 0.0))
	cotton = float(state.get("cotton", 0.0))
	soy = float(state.get("soy", 0.0))
	grape = float(state.get("grape", 0.0))
	rice = float(state.get("rice", 0.0))
	flour = float(state.get("flour", 0.0))
	oil = float(state.get("oil", 0.0))
	wine = float(state.get("wine", 0.0))
	cloth = float(state.get("cloth", 0.0))
	food = float(state.get("food", 20.0))
	wood = float(state.get("wood", 0.0))
	gold = float(state["gold"])
	foods_produced = {"rice": false, "flour": false, "oil": false, "wine": false}
	for k: String in foods_produced:
		foods_produced[k] = bool(state.get("foods_produced", {}).get(k, false))
	restaurant_unlocked = foods_produced.values().all(func(done: bool) -> bool: return done)
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
	doctored.clear()
	walkers.clear()
	evolve_prog.clear()
	burning.clear()
	building_cond.clear()
	employed.clear()
	locust_months_left = 0
	plague_months_left = int(state.get("plague", 0))
	shortage_months = 0
	for entry: Dictionary in state.get("conds", []):
		building_cond[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["cond"])
	for entry: Dictionary in state["buildings"]:
		var btype := String(entry["type"])
		if not building_defs.has(btype):
			push_warning("存档含未知建筑类型 %s，已跳过" % btype)
			continue
		buildings[Vector2i(int(entry["x"]), int(entry["y"]))] = btype
	for entry: Dictionary in state.get("estates", []):
		estates[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["tier"])
	for entry: Dictionary in state.get("trees", []):
		trees[Vector2i(int(entry["x"]), int(entry["y"]))] = true
	_refresh_capacity()
	_assign_jobs()  # 读档后 employed 已清空，必须重新分配岗位
	_update_hud()
	_update_slot_btn()
	queue_redraw()


func _on_save_pressed() -> void:
	if debug_mode:
		_show_message("DEBUG 模式已禁止存档（防止污染存档位）")
		return
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
	# canvas_transform 挂在根 Viewport 上，场景切换不会清除，
	# 残留的游戏相机会把菜单整体偏移/缩放，必须先复位
	get_viewport().canvas_transform = Transform2D.IDENTITY
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


	# ---------- HUD ----------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CanvasLayer"
	add_child(layer)

	# 顶部导航条：标题 | 存档位 | 存档 | 系统 | …… | 帮助
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.custom_minimum_size = Vector2(0, 40)
	top.add_theme_constant_override("margin_left", 8)
	top.add_theme_constant_override("margin_right", 8)
	top.add_theme_constant_override("margin_top", 4)
	top.add_theme_constant_override("margin_bottom", 4)
	layer.add_child(top)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 10)
	top.add_child(top_row)

	var title := Label.new()
	title.text = "新宋 · 治所"
	title.add_theme_font_size_override("font_size", 18)
	top_row.add_child(title)

	_slot_btn = Button.new()
	_slot_btn.pressed.connect(_on_slot_cycle_pressed)
	top_row.add_child(_slot_btn)

	var file_menu := MenuButton.new()
	file_menu.text = "存档"
	var file_popup := file_menu.get_popup()
	file_popup.add_item("保存到当前槽", 0)
	file_popup.add_item("读取当前槽", 1)
	file_popup.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_on_save_pressed()
		else:
			_on_load_pressed())
	top_row.add_child(file_menu)

	var sys_menu := MenuButton.new()
	sys_menu.text = "系统"
	var sys_popup := sys_menu.get_popup()
	var diff_keys := ["easy", "normal", "hard"]
	for i: int in diff_keys.size():
		sys_popup.add_radio_check_item("难度：" + str(DIFFICULTY[diff_keys[i]]["name"]), 10 + i)
		sys_popup.set_item_checked(sys_popup.get_item_count() - 1, diff_keys[i] == difficulty)
	sys_popup.add_separator()
	sys_popup.add_item("返回主菜单", 20)
	sys_popup.id_pressed.connect(func(id: int) -> void:
		if id == 20:
			_on_menu_pressed()
		elif id >= 10:
			difficulty = diff_keys[id - 10]
			for j: int in diff_keys.size():
				sys_popup.set_item_checked(j, diff_keys[j] == difficulty)
			_update_hud()
			_show_message("难度已切换为：%s" % _diff_name()))
	top_row.add_child(sys_menu)

	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(top_spacer)

	var help_label := Label.new()
	help_label.text = "滚轮缩放 | 中键/WASD平移 | Q/E旋转"
	help_label.modulate = Color(0.75, 0.75, 0.75)
	top_row.add_child(help_label)

	if debug_mode:
		# DEBUG 模式常驻红标，提醒开发者当前数值只增不减、存档已禁用
		var debug_label := Label.new()
		debug_label.text = "DEBUG"
		debug_label.add_theme_font_size_override("font_size", 18)
		debug_label.modulate = Color(1.0, 0.35, 0.3)
		top_row.add_child(debug_label)

	_minimap = Minimap.new()
	_minimap.main = self
	_minimap.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_minimap.position = Vector2(12, -132)
	layer.add_child(_minimap)

	# 右侧三卡片导航栏（靠右，从上到下）：状态 -> 朝廷诏令 -> 建造
	var side := VBoxContainer.new()
	side.anchor_left = 1.0
	side.anchor_top = 0.0
	side.anchor_right = 1.0
	side.anchor_bottom = 1.0
	side.offset_left = -320
	side.offset_top = 48  # 顶部导航条高 40，留 8 间隙
	side.offset_right = -12
	side.offset_bottom = -12
	side.add_theme_constant_override("separation", 8)
	layer.add_child(side)

	# 卡片 1：状态
	var status_card := PanelContainer.new()
	side.add_child(status_card)
	var sbox := VBoxContainer.new()
	status_card.add_child(sbox)
	var status_title := Label.new()
	status_title.text = "状态"
	status_title.add_theme_font_size_override("font_size", 16)
	sbox.add_child(status_title)
	_date_label = Label.new()
	sbox.add_child(_date_label)
	_pop_label = Label.new()
	sbox.add_child(_pop_label)
	_grain_label = Label.new()
	sbox.add_child(_grain_label)
	_flour_label = Label.new()
	sbox.add_child(_flour_label)
	_food_label = Label.new()
	sbox.add_child(_food_label)
	_wood_label = Label.new()
	sbox.add_child(_wood_label)
	_gold_label = Label.new()
	sbox.add_child(_gold_label)
	_econ_label = Label.new()
	sbox.add_child(_econ_label)
	_prestige_label = Label.new()
	sbox.add_child(_prestige_label)
	_walker_label = Label.new()
	sbox.add_child(_walker_label)

	# 卡片 2：朝廷诏令
	var edict_card := PanelContainer.new()
	side.add_child(edict_card)
	var ebox := VBoxContainer.new()
	edict_card.add_child(ebox)
	var edict_title := Label.new()
	edict_title.text = "朝廷诏令"
	edict_title.add_theme_font_size_override("font_size", 16)
	ebox.add_child(edict_title)
	_edict_label = Label.new()
	_edict_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ebox.add_child(_edict_label)

	# 卡片 3：建造（放大、占满右侧剩余高度）
	var build_card := PanelContainer.new()
	build_card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(build_card)
	var bwrap := VBoxContainer.new()
	build_card.add_child(bwrap)
	var build_title := Label.new()
	build_title.text = "建造"
	build_title.add_theme_font_size_override("font_size", 16)
	bwrap.add_child(build_title)
	_tool_label = Label.new()
	_tool_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bwrap.add_child(_tool_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bwrap.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	_menu_box = VBoxContainer.new()
	box.add_child(_menu_box)
	_show_build_menu_root()

	var cancel_btn := Button.new()
	cancel_btn.text = "取消建造（右键/Esc）"
	cancel_btn.pressed.connect(_on_tool_selected.bind(""))
	bwrap.add_child(cancel_btn)

	_message_label = Label.new()
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bwrap.add_child(_message_label)

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


func _menu_icon(btype: String) -> Texture2D:
	var def: Dictionary = building_defs[btype]
	if def.has("tex_dirs"):
		return def["tex_dirs"][0]
	return def["tex"]


func _make_x_icon() -> ImageTexture:
	# 拆除按钮图标：红叉（素材包里没有合适的图，程序绘制）
	var img := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	var red := Color(0.85, 0.25, 0.2)
	for i in 20:
		for w in range(-1, 2):
			if i + w >= 0 and i + w < 20:
				img.set_pixel(i + w, i, red)
				img.set_pixel(i + w, 19 - i, red)
	return ImageTexture.create_from_image(img)


func _make_square_btn(icon: Texture2D, text: String) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(92, 92)
	btn.icon = icon
	btn.expand_icon = true
	btn.text = text
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	return btn


func _clear_build_menu() -> void:
	for child: Node in _menu_box.get_children():
		_menu_box.remove_child(child)
		child.queue_free()
	_tool_buttons.clear()  # 被释放的按钮不能留在映射里


func _on_category_pressed(cat: String) -> void:
	Sound.play("click")
	_show_build_menu_category(cat)


func _show_build_menu_root() -> void:
	_menu_cat = ""
	_clear_build_menu()
	var grid := GridContainer.new()
	grid.columns = 3
	_menu_box.add_child(grid)
	for cat: String in BUILD_MENU:
		var members: Array = BUILD_MENU[cat]
		var names: Array = members.map(func(t: String) -> String: return building_defs[t]["name"])
		var btn := _make_square_btn(_menu_icon(members[0]), cat)
		btn.tooltip_text = "%s：%s" % [cat, "、".join(names)]
		btn.pressed.connect(_on_category_pressed.bind(cat))
		grid.add_child(btn)
	var road_btn := _make_square_btn(_menu_icon("road"), "道路")
	road_btn.tooltip_text = "建造道路（2 金），连接建筑供行人通行"
	road_btn.toggle_mode = true
	road_btn.pressed.connect(_on_tool_selected.bind("road"))
	grid.add_child(road_btn)
	_tool_buttons["road"] = road_btn
	var demo_btn := _make_square_btn(_make_x_icon(), "拆除")
	demo_btn.tooltip_text = "拆除建筑或树木（返还半价）"
	demo_btn.toggle_mode = true
	demo_btn.pressed.connect(_on_tool_selected.bind("demolish"))
	grid.add_child(demo_btn)
	_tool_buttons["demolish"] = demo_btn


func _show_build_menu_category(cat: String) -> void:
	_menu_cat = cat
	_clear_build_menu()
	var back := Button.new()
	back.text = "← 返回"
	back.pressed.connect(func() -> void:
		Sound.play("click")
		_show_build_menu_root())
	_menu_box.add_child(back)
	var grid := GridContainer.new()
	grid.columns = 3
	_menu_box.add_child(grid)
	for btype: String in BUILD_MENU[cat]:
		var def: Dictionary = building_defs[btype]
		var btn := _make_square_btn(_menu_icon(btype), def["name"])
		btn.tooltip_text = "%s\n造价 %d 金" % [def["desc"], int(def["cost_gold"])]
		if bool(def.get("locked", false)) and not restaurant_unlocked:
			# 酒楼：四种食品各生产过一次前保持置灰
			btn.disabled = true
			btn.tooltip_text = "尚未解锁：需生产过 大米、面粉、豆油、葡萄酒 四种食品"
		btn.toggle_mode = true
		btn.pressed.connect(_on_tool_selected.bind(btype))
		grid.add_child(btn)
		_tool_buttons[btype] = btn


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
	_grain_label.text = "作物：稻 %d ｜ 麦 %d ｜ 棉 %d ｜ 豆 %d ｜ 葡 %d" % [
		int(paddy), int(wheat), int(cotton), int(soy), int(grape)]
	_flour_label.text = "货品：米 %d ｜ 面 %d ｜ 油 %d ｜ 酒 %d ｜ 布 %d" % [
		int(rice), int(flour), int(oil), int(wine), int(cloth)]
	_food_label.text = "食品：%d" % int(food)
	_wood_label.text = "木材：%d" % int(wood)
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


# ---------- 立牌偏移与动画 ----------

func _billboard_off(tex: Texture2D) -> Vector2:
	## 立牌贴图偏移：水平居中，底部留 CELL/16 空隙（旧 32px 时代的 (-16,-30) 即此公式）
	return Vector2(-tex.get_width() / 2.0, CELL / 16.0 - tex.get_height())


func _estate_off(tex: Texture2D) -> Vector2:
	## 大宅贴图偏移：底影中心（图宽/2, 图高-ESTATE_GROUND_MARGIN）对齐 2x2 地块中心
	return Vector2(-tex.get_width() / 2.0, ESTATE_GROUND_MARGIN - tex.get_height())


func _draw_smoke(origin: Vector2) -> void:
	## 烟囱冒烟：3 个烟圈相位错开，渐大渐隐上浮（无状态，按 _anim_t 推算）
	for k in 3:
		var ph := fmod(_anim_t * 0.4 + k / 3.0, 1.0)
		var r := 3.0 + 6.0 * ph
		var p := origin + Vector2(sin(_anim_t * 1.7 + k * 2.1) * 3.0 * ph, -30.0 * ph)
		var c := Color(0.48, 0.50, 0.54, 0.55 * (1.0 - ph))
		draw_circle(p, r * 1.4, c)
		draw_circle(p, r * 0.8, Color(0.72, 0.73, 0.76, 0.4 * (1.0 - ph)))   # 烟圈亮芯


func _draw_flames(top_y: float) -> void:
	## 火灾跳焰：3 簇火苗在立牌顶部抖动（橙底黄心双层三角）
	for i in 3:
		var fx := -18.0 + i * 18.0
		var h := 12.0 + 7.0 * sin(_anim_t * 11.0 + i * 2.3)
		var lean := 3.0 * sin(_anim_t * 7.0 + i * 1.7)
		var base := Vector2(fx, top_y)
		draw_colored_polygon([base + Vector2(-5, 0), base + Vector2(5, 0), base + Vector2(lean, -h)],
			Color(0.95, 0.45, 0.15, 0.9))
		draw_colored_polygon([base + Vector2(-2.5, 0), base + Vector2(2.5, 0), base + Vector2(lean * 0.6, -h * 0.55)],
			Color(1.0, 0.85, 0.3, 0.95))


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
			elif wkind == 4:
				tint = Color(0.85, 0.55, 0.75)  # 郎中：紫红
			elif wkind == 5:
				tint = Color(0.98, 0.82, 0.35)  # 工匠：藤黄
			var vsz: Vector2 = villager_tex.get_size() * WALKER_SCALE
			var bob := absf(sin(_anim_t * 8.0 + w.pos.x * 1.7 + w.pos.y)) * 2.0
			draw_texture_rect(villager_tex, Rect2(Vector2(-vsz.x / 2, CELL / 16.0 - vsz.y - bob), vsz), false, tint)
			draw_set_transform_matrix(Transform2D())
			continue
		if item[2] == "estate":
			var anchor: Vector2i = item[1]
			var tier: int = estates[anchor]
			# 锚点 = 2x2 地块中心，四方向恒定（见 ESTATE_CENTER 注释）
			var ecenter: Vector2 = _proj() * (MAP_ORIGIN + (Vector2(anchor) + ESTATE_CENTER) * CELL)
			draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, ecenter))
			var etex: Texture2D = estate_tex[tier][_rot]
			draw_texture(etex, _estate_off(etex))
			draw_set_transform_matrix(Transform2D())
			continue
		var cell: Vector2i = item[1]
		# 立牌基座落点 = 格子中心，树木与建筑一致（见 BILLBOARD_ANCHOR 注释）
		var base: Vector2 = _proj() * (MAP_ORIGIN + (Vector2(cell) + BILLBOARD_ANCHOR) * CELL)
		draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, base))
		if item[2] == "tree":
			draw_texture(tree_tex, _billboard_off(tree_tex))
		else:
			var btex := _building_tex(item[2])
			var btint := Color(1, 0.45, 0.35) if burning.has(cell) else Color.WHITE
			draw_texture(btex, _billboard_off(btex), btint)
			if SMOKE_BUILDINGS.has(item[2]) and not burning.has(cell):
				_draw_smoke(SMOKE_BUILDINGS[item[2]])
			if burning.has(cell):
				_draw_flames(-btex.get_height() + 6.0)
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
					var gbase: Vector2 = _proj() * (p0 + BILLBOARD_ANCHOR * CELL)
					draw_set_transform_matrix(_proj().affine_inverse() * Transform2D(0, gbase))
					var gtex2 := _building_tex(selected_tool)
					draw_texture(gtex2, _billboard_off(gtex2), Color(1, 1, 1, 0.6))
					draw_set_transform_matrix(Transform2D())
