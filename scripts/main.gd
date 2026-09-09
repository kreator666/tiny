extends Node2D
## 游戏主逻辑：网格地图、建筑放置、月份推演、HUD。
## 时间流速：每 2 秒 = 1 个月。

const GRID_W := 20
const GRID_H := 20
const CELL := 32
const MAP_ORIGIN := Vector2(16, 16)
const MONTH_SECONDS := 2.0

# ---------- 状态 ----------

var building_defs: Dictionary = {}
var buildings: Dictionary = {}  # Vector2i 坐标 -> 建筑类型(String)

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
var _message_label: Label
var _tool_buttons := {}


func _ready() -> void:
	_load_building_defs()
	_build_hud()
	_refresh_capacity()
	_update_hud()


func _load_building_defs() -> void:
	var file := FileAccess.open("res://data/buildings.json", FileAccess.READ)
	assert(file != null, "找不到 data/buildings.json")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(typeof(parsed) == TYPE_DICTIONARY, "buildings.json 格式错误")
	building_defs = parsed


# ---------- 输入 ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
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
	if not _in_bounds(cell) or buildings.has(cell):
		_show_message("这里不能建造")
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
	var state := {
		"population": population,
		"grain": grain,
		"gold": gold,
		"year": year,
		"month": month,
		"buildings": list,
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
	for entry: Dictionary in state["buildings"]:
		buildings[Vector2i(int(entry["x"]), int(entry["y"]))] = String(entry["type"])
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

	var sep := HSeparator.new()
	box.add_child(sep)

	# 建造按钮：根据 buildings.json 自动生成
	for type: String in building_defs:
		var def: Dictionary = building_defs[type]
		var btn := Button.new()
		btn.text = "建造%s（%d 金）" % [def["name"], int(def["cost_gold"])]
		btn.tooltip_text = def["desc"]
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
	_show_message("已选择：%s" % (building_defs[type]["name"] if not type.is_empty() else "无"))


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

func _draw() -> void:
	# 地图底色与网格线
	draw_rect(Rect2(MAP_ORIGIN, Vector2(GRID_W, GRID_H) * CELL), Color(0.13, 0.14, 0.16))
	for x in GRID_W + 1:
		var px := MAP_ORIGIN.x + x * CELL
		draw_line(Vector2(px, MAP_ORIGIN.y), Vector2(px, MAP_ORIGIN.y + GRID_H * CELL), Color(0.3, 0.3, 0.3))
	for y in GRID_H + 1:
		var py := MAP_ORIGIN.y + y * CELL
		draw_line(Vector2(MAP_ORIGIN.x, py), Vector2(MAP_ORIGIN.x + GRID_W * CELL, py), Color(0.3, 0.3, 0.3))

	# 建筑
	for cell: Vector2i in buildings:
		var def: Dictionary = building_defs[buildings[cell]]
		var rect := Rect2(MAP_ORIGIN + Vector2(cell) * CELL + Vector2(2, 2), Vector2(CELL - 4, CELL - 4))
		draw_rect(rect, Color(def["color"]))

	# 悬停高亮
	if _in_bounds(hover_cell) and not selected_tool.is_empty():
		var valid := not buildings.has(hover_cell)
		var hover := Rect2(MAP_ORIGIN + Vector2(hover_cell) * CELL, Vector2(CELL, CELL))
		draw_rect(hover, Color(0.4, 0.9, 0.4, 0.35) if valid else Color(0.9, 0.3, 0.3, 0.35), true)
