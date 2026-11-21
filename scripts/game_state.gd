class_name GameState
extends Node
## 纯游戏逻辑层（阶段0 自 main.gd 拆出）：网格地图状态、建造/拆除判定、月份推演、
## 经济结算、生产链、朝廷诏令、灾害事件、行人移动、存档 state 的构建与应用。
## 本类不含任何渲染代码；画面由渲染层（阶段1 为 WorldRenderer3D）读取这里的公共字段绘制。
## 与 HUD 的交互通过信号：hud_dirty（数值/选中变化后刷新 HUD 并重绘）、
## message_shown（底部提示条）、build_menu_refresh（酒楼解锁后重建建造菜单）。
## 启动模式等静态变量仍由 Main 持有（见 Main.boot_mode / boot_slot / difficulty / debug_mode）。

signal hud_dirty
signal slot_dirty
signal message_shown(text: String)
signal build_menu_refresh

const GRID_W := 40
const GRID_H := 30
const CELL := 48
const MAP_ORIGIN := Vector2(16, 16)
const MONTH_SECONDS := 2.0

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

# 农田：连片只需一格邻路即可整片耕种；FARM_CYCLE 个月一熟
# （1 月播种 4 月收获），生长阶段 幼苗->生长->茂盛->成熟 可见
const FARM_CYCLE := 4

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

var renderer: Node  # 由 Main 注入（阶段1 为 WorldRenderer3D）；仅用于把鼠标位置反算成格子（悬停格）

# ---------- 状态 ----------

var building_defs: Dictionary = {}
var buildings: Dictionary = {}  # Vector2i -> 类型（1 格建筑，含 hut/tilehouse/farm/mill/market/road）
var estates: Dictionary = {}  # 2x2 大院锚点 Vector2i -> 等级(2 宅院 / 3 豪华大宅)
var grass: Dictionary = {}
var trees: Dictionary = {}
var farm_linked: Dictionary = {}  # 农田格 -> 是否与道路连通（连片只需一格邻路）
var farm_grow: Dictionary = {}  # 农田格 -> 生长阶段 0幼苗/1生长/2茂盛/3待收

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
var _spawn_accum := 0.0


func _ready() -> void:
	_load_building_defs()
	_generate_terrain()
	_refresh_capacity()
	_assign_jobs()


func apply_starting_gold() -> void:
	## 新开局初始金钱（读档会被存档覆盖）；由 Main 在首次 HUD 刷新前调用，保证首帧数值正确
	gold = float(_diff("gold"))


func _res_name(key: String) -> String:
	return CROP_NAMES.get(key, GOODS_NAMES.get(key, key))


func _say(text: String) -> void:
	## 原 _show_message：写状态并发信号，HUD 标签由 Main 更新
	message = text
	message_shown.emit(text)


func _load_building_defs() -> void:
	AssetLib.init()
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
		if def.has("crop"):
			# 农田生长阶段贴图（tools/gen_farm_stages.py 生成）
			def["tex_stages"] = []
			for i in 4:
				def["tex_stages"].append(AssetLib.tex("%s_s%d.png" % [String(def["texture"]).get_basename(), i]))


func _generate_terrain() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240101
	for x in GRID_W:
		for y in GRID_H:
			var cell := Vector2i(x, y)
			grass[cell] = rng.randi_range(0, 1)
			if rng.randf() < 0.05:
				trees[cell] = true


# ---------- 每帧推进（由 Main._process 按原有时序调用） ----------

func tick(delta: float) -> void:
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

	var new_hover := screen_to_cell(renderer.mouse_grid_pos())
	if new_hover != hover_cell:
		hover_cell = new_hover


# ---------- 占用与道路 ----------

func screen_to_cell(pos: Vector2) -> Vector2i:
	var local := pos - MAP_ORIGIN
	return Vector2i((local / CELL).floor())


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < GRID_W and cell.y < GRID_H


func _is_road(cell: Vector2i) -> bool:
	return buildings.get(cell, "") == "road"


func _is_farm(btype: String) -> bool:
	return building_defs.get(btype, {}).has("crop")


func _recompute_farm_connectivity() -> void:
	## 连片农田：从邻路农田格出发沿农田 flood fill，整片连通即视为可耕种
	farm_linked.clear()
	var queue: Array[Vector2i] = []
	for cell: Vector2i in buildings:
		if _is_farm(buildings[cell]) and _has_adjacent_road(cell):
			queue.append(cell)
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		if farm_linked.has(c):
			continue
		if not _is_farm(buildings.get(c, "")):
			continue
		farm_linked[c] = true
		for dir: Vector2i in DIRS:
			queue.append(c + dir)


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
	# 连片农田上的农夫：在田块间走动劳作（法老王式田间氛围）
	var plots: Array[Vector2i] = []
	for cell: Vector2i in farm_linked:
		plots.append(cell)
	var farmers := mini(maxi(1, plots.size() / 6), 4)
	for i in farmers:
		if walkers.size() >= WALKER_MAX or plots.is_empty():
			break
		var c: Vector2i = plots[randi() % plots.size()]
		_spawn_walker_from(c, c, 6)


func _spawn_walker_from(start: Vector2i, home: Variant, kind: int) -> void:
	var next := _choose_next_road(start, home, kind)
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


func _choose_next_road(cur: Vector2i, prev: Variant, kind: int = 0) -> Vector2i:
	var options: Array[Vector2i] = []
	for nb: Vector2i in _walk_neighbors(cur, kind):
		if nb != prev:
			options.append(nb)
	if options.is_empty():
		options = _walk_neighbors(cur, kind)
	if options.is_empty():
		return Vector2i(-1, -1)
	return options[randi() % options.size()]


func _walk_neighbors(cell: Vector2i, kind: int) -> Array[Vector2i]:
	## 行人可达邻格：农夫（kind 6）在连片农田间走动，其余行人走道路
	if kind == 6:
		var result: Array[Vector2i] = []
		for dir: Vector2i in DIRS:
			if _is_farm(buildings.get(cell + dir, "")):
				result.append(cell + dir)
		return result
	return _road_neighbors(cell)


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
			if Main.debug_mode or wood >= 2.0:
				if not Main.debug_mode:
					wood -= 2.0
				burning.erase(nb)
				_say("工匠扑灭了一场火灾！")
			continue
		if buildings.has(nb) and buildings[nb] != "road":
			if building_cond.get(nb, 100) < 100 and (Main.debug_mode or wood >= 1.0):
				if not Main.debug_mode:
					wood -= 1.0
				building_cond[nb] = mini(100, _cond_of(nb) + 10)
			continue
		var anchor := _estate_anchor_at(nb)
		if anchor != Vector2i(-1, -1) and building_cond.get(anchor, 100) < 100 and (Main.debug_mode or wood >= 1.0):
			if not Main.debug_mode:
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
			var next: Vector2i = _choose_next_road(w.cur, w.prev, wkind)
			w.prev = w.cur
			if next == Vector2i(-1, -1) or w.left <= 0:
				walkers.remove_at(i)
				continue
			w.nxt = next
		w.pos = Vector2(w.cur).lerp(Vector2(w.nxt), minf(w.t, 1.0))


# ---------- 建造 / 拆除 ----------

func _try_place(cell: Vector2i) -> void:
	if selected_tool.is_empty():
		return
	if not _in_bounds(cell):
		_say("这里不能建造")
		return
	if selected_tool == "demolish":
		_try_demolish(cell)
		return
	if trees.has(cell):
		_say("这里有树木，暂不可建造")
		return
	if _is_occupied(cell):
		_say("这里已被占用")
		return
	var def: Dictionary = building_defs[selected_tool]
	if bool(def.get("locked", false)) and not restaurant_unlocked:
		_say("酒楼尚未解锁：需生产过 大米、面粉、豆油、葡萄酒 四种食品")
		return
	if gold < int(def["cost_gold"]):
		_say("金钱不足")
		return
	if not Main.debug_mode:
		gold -= int(def["cost_gold"])
	buildings[cell] = selected_tool
	_recompute_farm_connectivity()
	_refresh_capacity()
	_say("建造了 %s" % def["name"])
	Sound.play("build")
	hud_dirty.emit()


## 铺路专用批量接口（拖拽连续铺路的提交动作）：沿路径顺序逐格铺设道路。
## 与逐格单击 _try_place 的道路分支语义一致：该格在界内、无树、未占用、剩余金钱足够
## 该格造价才铺（扣钱、置格）；不可建造或钱不够的格跳过、不中断后续格。
## 置格/扣款逐格进行（金钱逐格递减，与单击相同），连通性与容量收尾重算一次——
## 与逐格单击的最终游戏状态完全一致。只做道路；selected_tool 非 "road" 时返回 0。
func pave_road_path(cells: Array[Vector2i]) -> int:
	if selected_tool != "road":
		return 0
	var cost := int(building_defs["road"]["cost_gold"])
	var paved := 0
	for cell: Vector2i in cells:
		if not _in_bounds(cell) or trees.has(cell) or _is_occupied(cell):
			continue
		if not Main.debug_mode and gold < cost:
			continue
		if not Main.debug_mode:
			gold -= cost
		buildings[cell] = "road"
		paved += 1
	if paved > 0:
		_recompute_farm_connectivity()
		_refresh_capacity()
		hud_dirty.emit()
	return paved


func _try_demolish(cell: Vector2i) -> void:
	var anchor := _estate_anchor_at(cell)
	if anchor != Vector2i(-1, -1):
		var tier: int = estates[anchor]
		estates.erase(anchor)
		serviced.erase(anchor)
		evolve_prog.erase(anchor)
		building_cond.erase(anchor)
		gold += 40 * tier  # 大院按等级退款
		_say("拆除了大院，返还 %d 金" % int(40 * tier))
	elif buildings.has(cell):
		var btype: String = buildings[cell]
		var refund := int(building_defs[btype]["cost_gold"]) / 2
		buildings.erase(cell)
		serviced.erase(cell)
		evolve_prog.erase(cell)
		building_cond.erase(cell)
		farm_grow.erase(cell)
		gold += refund
		_say("拆除了 %s，返还 %d 金" % [building_defs[btype]["name"], refund])
	elif trees.has(cell):
		const TREE_COST := 10
		if not Main.debug_mode and gold < TREE_COST:
			_say("金钱不足（砍树需 %d 金，或建伐木屋免费砍伐）" % TREE_COST)
			return
		if not Main.debug_mode:
			gold -= TREE_COST
		trees.erase(cell)
		_say("砍除了一棵树（%d 金）" % (0 if Main.debug_mode else TREE_COST))
	else:
		_say("这里没有可拆除的建筑")
		return
	Sound.play("demolish")
	_recompute_farm_connectivity()
	_refresh_capacity()
	hud_dirty.emit()


# ---------- 时间推演 ----------

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
	_say("朝廷下达新诏令：" + _edict_desc())


func _resolve_edict() -> void:
	var kind: String = edict["kind"]
	var target: int = int(edict["target"])
	var ok := false
	match kind:
		"tax":
			ok = gold >= target
			if ok and not Main.debug_mode:
				gold -= target
		"tribute":
			ok = food >= target
			if ok and not Main.debug_mode:
				food -= target
		"population":
			ok = population >= target
		"estate":
			ok = estates.size() >= target
	if ok:
		prestige += 1
		if kind == "population" or kind == "estate":
			gold += 100
		_say("诏令达成，朝廷嘉奖！声望 +1")
		Sound.play("coin")
	else:
		if not Main.debug_mode:
			prestige -= 1
		_say("诏令未达成，朝廷震怒！声望 %s" % ("不变（DEBUG）" if Main.debug_mode else "-1"))
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
			if Main.debug_mode:
				continue
			var btype: String = buildings.get(cell, "")
			if not btype.is_empty():
				buildings.erase(cell)
				serviced.erase(cell)
				watered.erase(cell)
				evolve_prog.erase(cell)
				building_cond.erase(cell)
				farm_grow.erase(cell)
				_say("一场火灾烧毁了%s！" % building_defs[btype]["name"])
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
			if not Main.debug_mode:
				population = maxi(0, population - loss)
			if coverage >= 0.99:
				_say("瘟疫流行，所幸医馆诊治及时，仅 %d 人病亡" % loss)
			else:
				_say("瘟疫流行，%d 人病亡！医馆诊治可保百姓平安" % loss)
		if plague_months_left <= 0:
			_say("瘟疫终于消退了")
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
		_say("%s起火了！两月后将被烧毁" % building_defs[buildings[cell]]["name"])
	elif roll < 50:
		plague_months_left = 3
		_say("瘟疫爆发！未来三月人口将持续病亡，速建医馆派郎中医治")
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
		_say("风调雨顺，%s丰收！" % "、".join(gained))
	else:
		locust_months_left = 6
		_say("蝗灾来袭！六个月内农田减产一半")


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
	_say("四种食品齐备（大米、面粉、豆油、葡萄酒），商业解锁酒楼！")
	Sound.play("evolve")
	# 建造菜单里的酒楼按钮由置灰转为可点：重建当前菜单视图（由 Main 执行）
	build_menu_refresh.emit()


func _advance_month() -> void:
	_months_total += 1
	_recompute_farm_connectivity()
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
		if _is_farm(btype):
			# 连片农田：整片只需一格邻路；不连通的农田抛荒
			if not farm_linked.get(cell, false):
				continue
		elif not _has_adjacent_road(cell):
			continue
		var eff := _work_efficiency(cell, def)
		if eff <= 0.0:
			continue
		if def.has("crop"):
			# 生长周期：每月推进一阶段，满 FARM_CYCLE 月收获一次（产量 = 月产 x 周期）
			var stage := int(farm_grow.get(cell, 0)) + 1
			if stage >= FARM_CYCLE:
				stage = 0
				var mult := 0.5 if locust_months_left > 0 else 1.0
				stock[def["crop"]] = float(stock[def["crop"]]) + float(def["crop_per_month"]) * FARM_CYCLE * mult * eff
			farm_grow[cell] = stage
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
	if Main.debug_mode:
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
	if Main.debug_mode:
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
				_say("有米面无食！粮油店产能跟不上，百姓已在挨饿")
			elif paddy > 0 or wheat > 0:
				_say("有粮无米面！磨坊产能跟不上，百姓已在挨饿")
			else:
				_say("存粮不足，百姓已在挨饿（连续断粮三月将致人口流失）")
		else:
			# 断粮超三个月：无论囤了多少原粮都开始流失人口
			population = maxi(0, population - maxi(1, population / 20))
			_say("饥荒！人口下降")

	# 住房演进（需吃饱 + 有服务）
	_evolve_housing(fed)

	# 财政与朝廷（DEBUG：净收入为负时不扣钱，只增不减）
	var net := _economy_month()
	gold += maxf(0.0, net) if Main.debug_mode else net
	if edict.is_empty():
		_issue_edict()
	elif _months_total >= int(edict["deadline"]):
		_resolve_edict()

	# 灾害与事件
	_events_month()

	# 维护度自然损耗（道路不衰减；大院慢一点）；难度越高损耗越快（DEBUG：不衰减）
	if not Main.debug_mode:
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
	if _months_total % 12 == 0 and not Main.debug_mode:
		SaveManager.save_auto(_build_state())

	hud_dirty.emit()


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
				_say("一间茅屋翻修成了瓦房")
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
				_say("一座宅院扩建成了豪华大宅！")
				Sound.play("evolve")
		else:
			evolve_prog[anchor] = int(evolve_prog.get(anchor, 0)) / 2  # 断档减半，不清零


func _consume_luxury() -> bool:
	## 消耗 1 份二级食品（优先葡萄酒），供宅院升级豪华大宅；DEBUG 只验库存不扣减
	if Main.debug_mode:
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
		_say("几户村民合建了一座宅院！")
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
	if not Main.debug_mode:
		population = mini(population, pop_capacity)  # 拆除后人口不超过容量（DEBUG 不削人口）


# ---------- 劳动 / 维护 / 查看 ----------

func _diff(key: String) -> float:
	return float(DIFFICULTY.get(Main.difficulty, DIFFICULTY["normal"]).get(key, 1.0))


func _diff_name() -> String:
	return str(DIFFICULTY.get(Main.difficulty, DIFFICULTY["normal"])["name"])


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
		if _has_adjacent_road(cell) or farm_linked.get(cell, false):
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
			hud_dirty.emit()
			return


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
	var grow_list := []
	for cell: Vector2i in farm_grow:
		grow_list.append({"x": cell.x, "y": cell.y, "stage": farm_grow[cell]})
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
		"difficulty": Main.difficulty,
		"shortage": shortage_months,
		"prestige": prestige,
		# 诏令字段写侧收敛为整数：老存档经 JSON 往返可能读出 13.0，避免再写出浮点
		"edict": {} if edict.is_empty() else {
			"kind": str(edict["kind"]),
			"target": int(edict["target"]),
			"deadline": int(edict["deadline"]),
		},
		"edict_counter": _edict_counter,
		"plague": plague_months_left,
		"buildings": list,
		"estates": estate_list,
		"trees": tree_list,
		"conds": cond_list,
		"grows": grow_list,
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
	Main.difficulty = str(state.get("difficulty", "normal"))
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
	farm_grow.clear()
	locust_months_left = 0
	plague_months_left = int(state.get("plague", 0))
	shortage_months = 0
	for entry: Dictionary in state.get("conds", []):
		building_cond[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["cond"])
	for entry: Dictionary in state.get("grows", []):
		farm_grow[Vector2i(int(entry["x"]), int(entry["y"]))] = int(entry["stage"])
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
	_recompute_farm_connectivity()
	_assign_jobs()  # 读档后 employed 已清空，必须重新分配岗位
	hud_dirty.emit()
	slot_dirty.emit()
