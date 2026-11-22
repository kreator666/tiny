class_name Main
extends Node3D
## 游戏主场景（阶段1：3D Billboard 版）：持有 GameState（纯逻辑，未动）、
## WorldRenderer3D（3D 渲染）与 CameraRig（轨道相机/拾取），转发输入，
## 挂载 HUD 与小地图，处理启动/读档流程。menu.gd 的 boot_mode/boot_slot 接口不变。
## 单一 _process 驱动顺序（同阶段0约定）：动画时钟 -> state.tick -> 相机平移 -> 渲染动态更新。
##
## 核心玩法（未变）：
##   生产链：水稻田/麦田 -> 磨坊 -> 大米/面粉 -> 粮油店 -> 一级食品 -> 民居。
##     大豆 -> 油坊 -> 豆油 ┐
##     葡萄 -> 酒坊 -> 葡萄酒 ┴ 二级食品（宅院升级豪华大宅所需）。
##     棉花 -> 织布坊 -> 布匹，连同豆油/葡萄酒由市集售卖换金钱。
##     大米/面粉/豆油/葡萄酒各生产过一次后，商业解锁酒楼。
##   农田：连片只需一格邻路即可整片耕种；4 个月一熟（幼苗->生长->茂盛->成熟
##     贴图随月份变化），收获月一次性产出 4x 月产量；农夫在田块间走动劳作。
##   住房演进：茅屋(1格,4人) -> 瓦房(1格,8人) -> 宅院(2x2,32人) -> 豪华大宅(2x2,48人)。
##     条件：持续有行人服务 + 无饥荒；瓦房凑齐 2x2 空地自动合并为宅院。
##   建筑需邻接道路激活；行人（居民/挑夫/挑水夫/伐木工）沿路随机行走并服务相邻民居。
##   劳动：人口即劳力，工业建筑占用岗位（农田1/磨坊1/市集1/水井1/伐木屋2），
##        招不满人按在岗比例减产；维护度每月下降，低于 60% 半产、低于 30% 停产，可花钱修缮。
##   树木：拆除工具花 10 金立刻砍除；或建伐木屋免费缓慢砍路边树。
## 时间流速：每 2 秒 = 1 个月。
## 操作：滚轮缩放(向鼠标) | 中键/WASD平移 | Q/E旋转90° | 右键拖拽微调视角。
## 素材：程序化生成工笔画风（tools/gen_gongbi_assets.py）。

# 难度档位定义在 GameState.DIFFICULTY（menu.gd 直接引用 GameState.DIFFICULTY）

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


var state: GameState
var renderer: WorldRenderer3D
var camera_rig: CameraRig

var _pop_label: Label
var _grain_label: Label
var _flour_label: Label
var _ore_label: Label
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

# 道路工具拖拽铺路状态：左键按下先"武装"，移动超过阈值转拖拽采集路径，松开批量提交；
# 未过阈值视为单击，走原 _try_place 单格放置（手感与语义均不变）
const ROAD_DRAG_THRESHOLD := 0.3 * GameState.CELL  # 0.3 格（像素）
var _road_armed := false  # 道路工具左键已按下
var _road_drag_moved := false  # 已越过拖拽阈值（否则松开按单击处理）
var _road_press_pos := Vector2.ZERO  # 按下点地面像素坐标
var _road_drag_cells: Array[Vector2i] = []  # 已采集路径（去重、插值填满）
var _road_drag_set := {}  # 路径格查重集

# 时间速度档（0=暂停 1/2/4×；纯运行态不入存档，读档回 1×）
var time_scale := 1.0
var _speed_buttons := {}  # 档位 -> Button（高亮当前档）


func _ready() -> void:
	state = GameState.new()
	add_child(state)  # state._ready：加载建筑定义、生成地形、容量与岗位初算
	renderer = WorldRenderer3D.new()
	renderer.state = state
	add_child(renderer)  # renderer._ready：贴图/环境/草地
	camera_rig = CameraRig.new()
	add_child(camera_rig)  # rig._ready：创建 Camera3D 并复位视角
	renderer.camera = camera_rig
	state.renderer = renderer
	state.hud_dirty.connect(_on_state_hud_dirty)
	state.slot_dirty.connect(_update_slot_btn)
	state.message_shown.connect(_show_message)
	state.build_menu_refresh.connect(_on_build_menu_refresh)
	_build_hud()
	state.apply_starting_gold()  # 新开局初始金钱（读档会被存档覆盖）；须先于首次 HUD 刷新
	_update_hud()

	# 按主菜单指定的启动模式读档（测试脚本直接实例化本场景时保持 "new" 不受影响）
	match boot_mode:
		"auto":
			var auto_state := SaveManager.load_auto()
			if not auto_state.is_empty():
				state._apply_state(auto_state)
				_show_message("已读取自动存档（第 %d 年 %d 月）" % [state.year, state.month])
		"slot":
			var slot_state := SaveManager.load_slot(boot_slot)
			if not slot_state.is_empty():
				_active_slot = boot_slot
				state._apply_state(slot_state)
				_show_message("已读取存档槽 %d（第 %d 年 %d 月）" % [boot_slot, state.year, state.month])
	boot_mode = "new"
	renderer.sync_world()  # 初始世界（含读档后的建筑/树/立牌）
	_update_slot_btn()
	if debug_mode:
		_show_message("DEBUG 模式：各项数值只增不减，禁止存档")


func _process(delta: float) -> void:
	# 与阶段0相同的单一驱动顺序：动画时钟 -> 逻辑 -> 相机平移 -> 渲染动态更新。
	# 时间速度：tick 与 _anim_t 同乘 time_scale（0/1/2/4），视觉动画与逻辑同速；
	# 暂停时画面静止，相机平移/输入/HUD 仍可用
	var dt := delta * time_scale
	renderer._anim_t += dt
	state.tick(dt)
	if not state.walkers.is_empty():
		_walker_label.text = "行人：%d" % state.walkers.size()
	camera_rig.pan_wasd(delta)  # 相机不随暂停锁定
	renderer.update_dynamic()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				_cancel_road_drag()
				_on_tool_selected("")
				_close_info_panel()
			KEY_SPACE:
				# 速度快捷键：暂停 <-> 1×（与按钮同效）
				_set_time_scale(1.0 if time_scale == 0.0 else 0.0)
			KEY_Q:
				camera_rig.rotate_view(1)
			KEY_E:
				camera_rig.rotate_view(-1)
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					camera_rig.zoom_at_mouse(1.0 / CameraRig.ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					camera_rig.zoom_at_mouse(CameraRig.ZOOM_STEP)
			MOUSE_BUTTON_MIDDLE:
				camera_rig.set_dragging(event.pressed)
			MOUSE_BUTTON_RIGHT:
				_cancel_road_drag()
				camera_rig.set_orbiting(event.pressed)
				if event.pressed:
					_on_tool_selected("")
					_close_info_panel()
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_on_left_pressed(event.position)
				else:
					_finish_road_drag()
	elif event is InputEventMouseMotion:
		if camera_rig.is_dragging():
			camera_rig.pan_by(event.relative)
		elif camera_rig.is_orbiting():
			camera_rig.orbit_adjust(event.relative)
		if _road_armed:
			_update_road_drag(event.position)
		state.hover_cell = state.screen_to_cell(renderer.mouse_grid_pos())


## 左键按下：道路工具进入"待拖拽"状态（不立即放置）；其余工具/选择保持原行为
func _on_left_pressed(screen_pos: Vector2) -> void:
	var cell := state.screen_to_cell(camera_rig.grid_pos_at(screen_pos))
	if state.selected_tool == "road":
		_road_armed = true
		_road_drag_moved = false
		_road_press_pos = camera_rig.grid_pos_at(screen_pos)
		_road_drag_cells = [cell]
		_road_drag_set = {cell: true}
		renderer.sync_road_path(_road_drag_cells)
		_show_message("铺路 %d 格 · %d 金" % [1, int(state.building_defs["road"]["cost_gold"])])
	elif state.selected_tool.is_empty():
		_select_at(cell)
	else:
		state._try_place(cell)


## 拖拽采集：先判阈值（未过阈值不采格，松开仍按单击）；越过阈值后悬停格变化时
## 与上一格做网格直线插值填满（快速拖动不断线），重复格不计入
func _update_road_drag(screen_pos: Vector2) -> void:
	var grid_pos := camera_rig.grid_pos_at(screen_pos)
	if not _road_drag_moved:
		if grid_pos.distance_to(_road_press_pos) < ROAD_DRAG_THRESHOLD:
			return
		_road_drag_moved = true  # 阈值刚越过：从按下格到当前格同样插值填满
	var cur := state.screen_to_cell(grid_pos)
	var last: Vector2i = _road_drag_cells[_road_drag_cells.size() - 1]
	if cur == last:
		return
	var d := cur - last
	var steps := maxi(absi(d.x), absi(d.y))
	for i in range(1, steps + 1):
		var c := last + Vector2i(roundi(d.x * i / float(steps)), roundi(d.y * i / float(steps)))
		if _road_drag_set.has(c):
			continue
		_road_drag_set[c] = true
		_road_drag_cells.append(c)
	renderer.sync_road_path(_road_drag_cells)
	_show_message("铺路 %d 格 · %d 金" % [_road_drag_cells.size(),
		_road_drag_cells.size() * int(state.building_defs["road"]["cost_gold"])])


## 松开左键：未过阈值 = 原单击放置（走 _try_place 全语义）；
## 已拖拽 = pave_road_path 批量提交，提示铺成/跳过格数（铺成功格放一次建造音）
func _finish_road_drag() -> void:
	if not _road_armed:
		return
	var cells := _road_drag_cells
	var was_drag := _road_drag_moved
	_road_armed = false
	_road_drag_moved = false
	renderer.clear_road_path()
	if not was_drag:
		state._try_place(cells[0])
		return
	var paved: int = state.pave_road_path(cells)
	var skipped := cells.size() - paved
	if paved > 0:
		Sound.play("build")
		_show_message("已铺 %d 格道路（跳过 %d 格）" % [paved, skipped] if skipped > 0 else "已铺 %d 格道路" % paved)
	elif skipped > 0:
		_show_message("没有可铺的格子（跳过 %d 格）" % skipped)


## 右键/Esc 取消本次拖拽：不铺、不扣钱、无音效
func _cancel_road_drag() -> bool:
	if not _road_armed:
		return false
	_road_armed = false
	_road_drag_moved = false
	renderer.clear_road_path()
	_show_message("已取消铺路")
	return true


# ---------- GameState 信号处理 ----------

func _on_state_hud_dirty() -> void:
	## 逻辑层数值/选中/世界内容变化：刷新 HUD 并同步 3D 世界
	_update_hud()
	renderer.sync_world()


## 时间速度档切换：高亮当前档按钮；纯运行态，不入存档
func _set_time_scale(v: float) -> void:
	time_scale = v
	_sync_speed_buttons()


func _sync_speed_buttons() -> void:
	for v: float in _speed_buttons:
		_speed_buttons[v].set_pressed_no_signal(v == time_scale)


func _on_build_menu_refresh() -> void:
	## 酒楼解锁后重建建造菜单（置灰按钮转可点）
	if _menu_box == null:
		return
	if _menu_cat.is_empty():
		_show_build_menu_root()
	else:
		_show_build_menu_category(_menu_cat)


# ---------- 查看面板 ----------

func _select_at(cell: Vector2i) -> void:
	if state.buildings.has(cell) or state.trees.has(cell) or state._estate_anchor_at(cell) != Vector2i(-1, -1):
		state.selected_cell = cell
		_refresh_info_panel()
		Sound.play("click")
	else:
		_close_info_panel()


func _close_info_panel() -> void:
	state.selected_cell = Vector2i(-1, -1)
	if _info_panel:
		_info_panel.visible = false


func _refresh_info_panel() -> void:
	if _info_panel == null or state.selected_cell == Vector2i(-1, -1):
		return
	var cell := state.selected_cell
	var anchor := state._estate_anchor_at(cell)
	var key := anchor if anchor != Vector2i(-1, -1) else cell
	var lines: Array = []
	var show_repair := false
	if anchor != Vector2i(-1, -1):
		var tier: int = state.estates[anchor]
		_info_title.text = "豪华大宅" if tier == 3 else "宅院"
		var cap: int = GameState.ESTATE_CAP[tier]
		lines.append("居住人口：%d / %d" % [state._occupants(cap), cap])
		lines.append("维护度：%d%%" % state._cond_of(key))
		lines.append("服务：%s　供水：%s　诊治：%s" % [_yesno(state._recently_serviced(key)), _yesno(state._recently_watered(key)), _yesno(state._recently_doctored(key))])
		if tier == 2:
			lines.append("升级进度：%d / %d 月" % [int(state.evolve_prog.get(key, 0)), GameState.EVOLVE_ESTATE])
			lines.append("二级食品：葡萄酒 %d ｜ 豆油 %d（升级每月消耗 1）" % [int(state.wine), int(state.oil)])
		show_repair = true
	elif state.buildings.has(cell):
		var btype: String = state.buildings[cell]
		_info_title.text = state.building_defs[btype]["name"]
		if btype == "hut" or btype == "tilehouse":
			var cap2: int = GameState.HUT_CAP if btype == "hut" else GameState.TILEHOUSE_CAP
			lines.append("居住人口：%d / %d" % [state._occupants(cap2), cap2])
			lines.append("维护度：%d%%" % state._cond_of(key))
			lines.append("服务：%s　供水：%s　诊治：%s" % [_yesno(state._recently_serviced(key)), _yesno(state._recently_watered(key)), _yesno(state._recently_doctored(key))])
			if btype == "hut":
				lines.append("升级进度：%d / %d 月" % [int(state.evolve_prog.get(key, 0)), GameState.EVOLVE_HUT])
			else:
				lines.append("升级进度：%d / %d 月" % [int(state.evolve_prog.get(key, 0)), GameState.EVOLVE_MERGE])
		elif btype == "road":
			lines.append("供行人通行，连接建筑。")
		else:
			var def: Dictionary = state.building_defs[btype]
			if int(def.get("jobs", 0)) > 0:
				var jobs := int(def["jobs"])
				var on := int(state.employed.get(key, 0))
				lines.append("岗位：%d　在岗：%d（效率 %d%%）" % [jobs, on, int(state._work_efficiency(key, def) * 100)])
			lines.append("维护度：%d%%" % state._cond_of(key))
			if btype == "mine":
				var left: Dictionary = state.ore_left.get(key, {})
				if left.is_empty() or float(left["amount"]) <= 0.0:
					lines.append("矿脉已枯竭（矿井可拆除）")
				else:
					lines.append("矿脉剩余：%d / %d" % [int(round(float(left["amount"]))), GameState.ORE_AMOUNT])
			if def.has("crop"):
				var stage := mini(int(state.farm_grow.get(cell, 0)), 3)
				var sname: String = ["幼苗", "生长", "茂盛", "待收"][stage]
				if state.farm_linked.get(cell, false):
					lines.append("生长：%s（每 %d 月收获 %d %s）" % [sname, GameState.FARM_CYCLE, int(def["crop_per_month"]) * GameState.FARM_CYCLE, GameState.CROP_NAMES[def["crop"]]])
				else:
					lines.append("抛荒中：农田需连片且有一格邻路才能耕种")
			if def.has("converts"):
				var parts: Array = []
				for cv: Dictionary in def["converts"]:
					parts.append("%s→%s %d" % [state._res_name(cv["from"]), state._res_name(cv["to"]), int(cv["rate"])])
				lines.append("加工：%s /月" % "，".join(parts))
			if def.has("sells"):
				var parts2: Array = []
				for item: String in def["sells"]:
					parts2.append("%s %d金" % [state._res_name(item), int(def["sells"][item])])
				lines.append("售卖：%s，每月至多 %d 件" % ["、".join(parts2), int(def["sell_rate"])])
			if def.has("consumes"):
				var parts3: Array = []
				for item: String in def["consumes"]:
					parts3.append("%s×%d" % [state._res_name(item), int(def["consumes"][item])])
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
	elif state.trees.has(cell):
		_info_title.text = "树木"
		lines.append("遮挡建造。可花 10 金立刻砍除，")
		lines.append("或建伐木屋派工人免费缓慢砍伐。")
	_info_body.text = "\n".join(lines)
	if show_repair:
		var base := 40 * int(state.estates.get(key, 1)) if anchor != Vector2i(-1, -1) else int(state.building_defs[state.buildings[cell]]["cost_gold"])
		var cost := state._repair_cost(key, base)
		_repair_btn.visible = true
		_repair_btn.text = "修缮（%d 金）" % cost
		_repair_btn.disabled = state._cond_of(key) >= 100 or state.gold < cost
	else:
		_repair_btn.visible = false
	_info_panel.visible = true


func _yesno(v: bool) -> String:
	return "有" if v else "无"


func _on_repair_pressed() -> void:
	var cell := state.selected_cell
	var anchor := state._estate_anchor_at(cell)
	var key := anchor if anchor != Vector2i(-1, -1) else cell
	var base := 40 * int(state.estates.get(key, 1)) if anchor != Vector2i(-1, -1) else int(state.building_defs[state.buildings[cell]]["cost_gold"])
	var cost := state._repair_cost(key, base)
	if state._cond_of(key) >= 100 or state.gold < cost:
		return
	if not debug_mode:
		state.gold -= cost
	state.building_cond[key] = 100
	_show_message("修缮完成")
	Sound.play("coin")
	_update_hud()
	_refresh_info_panel()


func _on_panel_demolish_pressed() -> void:
	var cell := state.selected_cell
	_close_info_panel()
	state._try_demolish(cell)


# ---------- 存档 ----------

func _on_save_pressed() -> void:
	if debug_mode:
		_show_message("DEBUG 模式已禁止存档（防止污染存档位）")
		return
	var err := SaveManager.save_slot(_active_slot, state._build_state())
	_update_slot_btn()
	_show_message("已保存到存档槽 %d" % _active_slot if err == OK else "保存失败")


func _on_load_pressed() -> void:
	var st := SaveManager.load_slot(_active_slot)
	if st.is_empty():
		_show_message("存档槽 %d 是空的" % _active_slot)
		return
	state._apply_state(st)
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
		sys_popup.add_radio_check_item("难度：" + str(GameState.DIFFICULTY[diff_keys[i]]["name"]), 10 + i)
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
			_show_message("难度已切换为：%s" % state._diff_name()))
	top_row.add_child(sys_menu)

	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(top_spacer)

	var help_label := Label.new()
	help_label.text = "滚轮缩放 | 中键/WASD平移 | Q/E旋转 | 右键拖拽调视角"
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
	_minimap.state = state
	_minimap.camera_rig = camera_rig
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
	# 时间速度档（⏸/1×/2×/4×，空格切换 暂停<->1×）
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 4)
	sbox.add_child(speed_row)
	for spec in [[0.0, "⏸", "暂停"], [1.0, "1×", "正常"], [2.0, "2×", "快速"], [4.0, "4×", "超快速"]]:
		var sb := Button.new()
		sb.text = spec[1]
		sb.tooltip_text = "%s（空格切换 暂停/正常）" % spec[2]
		sb.toggle_mode = true
		sb.custom_minimum_size = Vector2(40, 0)
		var v: float = spec[0]
		sb.pressed.connect(_set_time_scale.bind(v))
		speed_row.add_child(sb)
		_speed_buttons[v] = sb
	_sync_speed_buttons()
	_date_label = Label.new()
	sbox.add_child(_date_label)
	_pop_label = Label.new()
	sbox.add_child(_pop_label)
	_grain_label = Label.new()
	sbox.add_child(_grain_label)
	_flour_label = Label.new()
	sbox.add_child(_flour_label)
	_ore_label = Label.new()
	sbox.add_child(_ore_label)
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
	var def: Dictionary = state.building_defs[btype]
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
	for cat: String in GameState.BUILD_MENU:
		var members: Array = GameState.BUILD_MENU[cat]
		var names: Array = members.map(func(t: String) -> String: return state.building_defs[t]["name"])
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
	for btype: String in GameState.BUILD_MENU[cat]:
		var def: Dictionary = state.building_defs[btype]
		var btn := _make_square_btn(_menu_icon(btype), def["name"])
		btn.tooltip_text = "%s\n造价 %d 金" % [def["desc"], int(def["cost_gold"])]
		if not state._is_unlocked(btype):
			# 锁定建筑（酒楼=四食品；兵器坊/炼金坊=采到过铁/金矿）：置灰 + 解锁提示
			btn.disabled = true
			btn.tooltip_text = state._unlock_hint(btype)
		btn.toggle_mode = true
		btn.pressed.connect(_on_tool_selected.bind(btype))
		grid.add_child(btn)
		_tool_buttons[btype] = btn


func _on_tool_selected(type: String) -> void:
	_cancel_road_drag()  # 换工具/取消选择时中断进行中的铺路拖拽
	Sound.play("click")
	state.selected_tool = type
	for tool: String in _tool_buttons:
		_tool_buttons[tool].set_pressed_no_signal(tool == type)
	var building_name := "无"
	if state.building_defs.has(type):
		building_name = state.building_defs[type]["name"]
	elif type == "demolish":
		building_name = "拆除"
	if _tool_label:
		_tool_label.text = "当前工具：%s（右键/Esc 取消）" % building_name
	_show_message("已选择：%s" % building_name)


func _update_hud() -> void:
	_date_label.text = "第 %d 年 %d 月 · %s" % [state.year, state.month, state._diff_name()]
	_pop_label.text = "人口：%d / %d（就业 %d/%d）" % [state.population, state.pop_capacity, state.jobs_filled, state.jobs_total]
	_grain_label.text = "作物：稻 %d ｜ 麦 %d ｜ 棉 %d ｜ 豆 %d ｜ 葡 %d" % [
		int(state.paddy), int(state.wheat), int(state.cotton), int(state.soy), int(state.grape)]
	_flour_label.text = "货品：米 %d ｜ 面 %d ｜ 油 %d ｜ 酒 %d ｜ 布 %d" % [
		int(state.rice), int(state.flour), int(state.oil), int(state.wine), int(state.cloth)]
	_ore_label.text = "矿产：铁 %d ｜ 金 %d ｜ 兵器 %d" % [
		int(state.iron_ore), int(state.gold_ore), int(state.weapons)]
	_food_label.text = "食品：%d" % int(state.food)
	_wood_label.text = "木材：%d" % int(state.wood)
	_gold_label.text = "金钱：%d" % int(state.gold)
	_econ_label.text = "月税 %.1f − 维护 %.1f" % [state.last_tax_income, state.last_upkeep]
	_prestige_label.text = "朝廷声望：%d" % state.prestige
	_edict_label.text = state._edict_desc()
	_walker_label.text = "行人：%d" % state.walkers.size()
	if _info_panel and _info_panel.visible:
		_refresh_info_panel()


func _show_message(text: String) -> void:
	state.message = text
	if _message_label:
		_message_label.text = text
