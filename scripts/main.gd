extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 时间流速：每 2 秒 = 1 个月。
## 视觉：Kenney Tiny Town / Tiny Farm（CC0 协议，见 assets/KENNEY_LICENSE.txt）

const GRID_W := 20
const GRID_H := 20
const CELL := 32
const MAP_ORIGIN := Vector2(16, 16)
const MONTH_SECONDS := 2.0

# 素材表参数：16px  tiles，每行 12 个
const SHEET_COLS := 12
const SRC := 16

const TOWN_SHEET: Texture2D = preload("res://assets/tiles/town_packed.png")
const FARM_SHEET: Texture2D = preload("res://assets/tiles/farm_packed.png")

const GRASS_TILES := [0, 1]  # 草地块（town 表 row0 col0-1）
const TREE_TILE := 6  # 小松树（town 表 row0 col6）

# ---------- 状态 ----------

var building_defs: Dictionary = {}
var buildings: Dictionary = {}  # Vector2i 坐标 -> 建筑类型(String)
var grass: Dictionary = {}  # Vector2i 坐标 -> 草地块变体索引
var trees: Dictionary = {}  # Vector2i 坐标 -> true

var population := 0
var pop_capacity := 0  # 由民居数量决定，每次变化时重算
var grain := 100.0
var gold := 100.0
var year := 1
var month := 1

var selected_tool := ""  # 当前选中的建造类型，空串 = 无
var hover_cell := Vector2i(-1, -1)
var message := ""

var _elapsed := 0.0

# HUD 节点引用（在 _build_hud 中创建）
var _pop_label: Label
var _grain_label: Label
var _gold_label: Label
var _date_label: Label
var _tool_label: Label
var _message_label: Label
var _tool_buttons := {}


func _ready() -> void:
	_load_building_defs()
	_generate_terrain()
	_build_hud()
	_refresh_capacity()
	_update_hud()


func _load_building_defs() -> void:
	var file := FileAccess.open("res://data/buildings.json", FileAccess.READ)
	assert(file != null, "找不到 data/buildings.json")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(typeof(parsed) == TYPE_DICTIONARY, "buildings.json 格式错误")
	building_defs = parsed


func _generate_terrain() -> void:
	# 固定种子，保证每次新档地形一致（可换成 randi 每次随机）
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240101
	for x in GRID_W:
		for y in GRID_H:
			var cell := Vector2i(x, y)
			grass[cell] = GRASS_TILES[rng.randi_range(0, GRASS_TILES.size() - 1)]
			if rng.randf() < 0.05:
				trees[cell] = true


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_tool_selected("")
	elif event is InputEventMouseMotion:
		hover_cell = _screen_to_cell(get_global_mouse_position())
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_try_place(_screen_to_cell(get_global_mouse_position()))


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
	_elapsed += delta
	if _elapsed >= MONTH_SECONDS:
		_elapsed = 0.0
		_advance_month()


func _advance_month() -> void:
	# 农田产出
	var farm_count := 0
	for type: String in buildings.values():
		if type == "farm":
			farm_count += 1
	grain += farm_count * int(building_defs["farm"]["grain_per_month"])

	# 人口消耗粮食
	var consumption: int = int(ceil(population * 0.5))
	if grain >= consumption:
		grain -= consumption
		# 有饭吃：人口向容量上限缓慢增长
		if population < pop_capacity:
			population = mini(pop_capacity, population + maxi(1, pop_capacity / 20))
	else:
		grain = 0.0
		# 饥荒：人口衰减
		population = maxi(0, population - maxi(1, population / 10))
		_show_message("饥荒！人口下降")

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
	buildings.clear()
	trees.clear()
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


func _on_tool_selected(type: String) -> void:
	selected_tool = type
	for tool: String in _tool_buttons:
		_tool_buttons[tool].set_pressed_no_signal(tool == type)
	var building_name: String = building_defs[type]["name"] if not type.is_empty() else "无"
	if _tool_label:
		_tool_label.text = "当前工具：%s（Esc 取消）" % building_name
	_show_message("已选择：%s" % building_name)


func _update_hud() -> void:
	_date_label.text = "第 %d 年 %d 月" % [year, month]
	_pop_label.text = "人口：%d / %d" % [population, pop_capacity]
	_grain_label.text = "粮食：%d" % int(grain)
	_gold_label.text = "金钱：%d" % int(gold)


func _show_message(text: String) -> void:
	message = text
	if _message_label:
		_message_label.text = text


# ---------- 绘制 ----------

func _sheet_texture(sheet: String) -> Texture2D:
	return TOWN_SHEET if sheet == "town" else FARM_SHEET


func _draw_sheet_tile(tex: Texture2D, idx: int, dest: Vector2, alpha: float = 1.0) -> void:
	var src := Rect2((idx % SHEET_COLS) * SRC, (idx / SHEET_COLS) * SRC, SRC, SRC)
	draw_texture_rect_region(tex, Rect2(dest, Vector2(SRC, SRC)), src, Color(1, 1, 1, alpha))


func _draw_building(type: String, origin: Vector2, alpha: float = 1.0) -> void:
	var def: Dictionary = building_defs[type]
	var tex := _sheet_texture(def["sheet"])
	var quad: Array = def["quad"]
	for i in 4:
		_draw_sheet_tile(tex, int(quad[i]), origin + Vector2(i % 2, i / 2) * SRC, alpha)


func _draw() -> void:
	# 地图外底色
	draw_rect(Rect2(Vector2.ZERO, Vector2(980, 700)), Color(0.09, 0.10, 0.12))

	# 草地地形
	for cell: Vector2i in grass:
		_draw_sheet_tile(TOWN_SHEET, grass[cell], MAP_ORIGIN + Vector2(cell) * CELL)

	# 树木装饰
	for cell: Vector2i in trees:
		_draw_sheet_tile(TOWN_SHEET, TREE_TILE, MAP_ORIGIN + Vector2(cell) * CELL + Vector2(0, 8))

	# 建筑
	for cell: Vector2i in buildings:
		_draw_building(buildings[cell], MAP_ORIGIN + Vector2(cell) * CELL)

	# 悬停预览：半透明影子 + 可建造性着色
	if _in_bounds(hover_cell) and not selected_tool.is_empty():
		var valid := not buildings.has(hover_cell) and not trees.has(hover_cell)
		var origin := MAP_ORIGIN + Vector2(hover_cell) * CELL
		_draw_building(selected_tool, origin, 0.6)
		var tint := Color(0.4, 0.9, 0.4, 0.25) if valid else Color(0.9, 0.3, 0.3, 0.35)
		draw_rect(Rect2(origin, Vector2(CELL, CELL)), tint, true)
