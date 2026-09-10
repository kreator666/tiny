extends Control
## 主菜单：继续游戏（自动存档）/ 新游戏 / 读取存档位 1-3 / 退出。
## 通过 Main.boot_mode / Main.boot_slot 静态变量把选择传给游戏场景。

const MAIN_SCENE := "res://scenes/main.tscn"


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.10)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "新宋 · 治所"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "治一方水土，安一方百姓"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.modulate = Color(0.8, 0.75, 0.6)
	box.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	box.add_child(spacer)

	var cont := Button.new()
	cont.text = "继续游戏（自动存档）"
	cont.disabled = SaveManager.load_auto().is_empty()
	cont.custom_minimum_size = Vector2(300, 0)
	cont.pressed.connect(_on_continue)
	box.add_child(cont)

	var new_game := Button.new()
	new_game.text = "新游戏"
	new_game.custom_minimum_size = Vector2(300, 0)
	new_game.pressed.connect(_on_new_game)
	box.add_child(new_game)

	for slot in range(1, SaveManager.SLOT_COUNT + 1):
		var info := SaveManager.slot_info(slot)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(300, 0)
		if info.is_empty():
			btn.text = "存档槽 %d（空）" % slot
			btn.disabled = true
		else:
			btn.text = "存档槽 %d｜第%d年%d月 人口%d 金%d" % [
				slot, int(info.get("year", 1)), int(info.get("month", 1)),
				int(info.get("population", 0)), int(info.get("gold", 0))]
			btn.pressed.connect(_on_load_slot.bind(slot))
		box.add_child(btn)

	var quit := Button.new()
	quit.text = "退出游戏"
	quit.custom_minimum_size = Vector2(300, 0)
	quit.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(quit)


func _on_continue() -> void:
	Main.boot_mode = "auto"
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_new_game() -> void:
	Main.boot_mode = "new"
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_load_slot(slot: int) -> void:
	Main.boot_mode = "slot"
	Main.boot_slot = slot
	get_tree().change_scene_to_file(MAIN_SCENE)
