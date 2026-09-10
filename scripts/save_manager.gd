class_name SaveManager
extends RefCounted
## 负责把游戏状态存成 JSON 文件、再读回来。
## 支持 3 个手动存档位 + 1 个自动存档：
##   user://save_slot_1.json ~ save_slot_3.json
##   user://autosave.json
## 存档位置：Godot 的 user:// 目录（Windows 下是
## C:\Users\<用户名>\AppData\Roaming\Godot\app_userdata\新宋 · 治所\）

const SLOT_COUNT := 3
const AUTO_PATH := "user://autosave.json"


static func _slot_path(slot: int) -> String:
	return "user://save_slot_%d.json" % slot


static func save_slot(slot: int, state: Dictionary) -> Error:
	return _write(_slot_path(slot), state)


static func load_slot(slot: int) -> Dictionary:
	return _read(_slot_path(slot))


static func slot_info(slot: int) -> Dictionary:
	## 返回槽位完整存档（调用方自取 year/month/population/gold），空槽返回 {}
	return load_slot(slot)


static func save_auto(state: Dictionary) -> Error:
	return _write(AUTO_PATH, state)


static func load_auto() -> Dictionary:
	return _read(AUTO_PATH)


static func has_any_save() -> bool:
	if FileAccess.file_exists(AUTO_PATH):
		return true
	for slot in range(1, SLOT_COUNT + 1):
		if FileAccess.file_exists(_slot_path(slot)):
			return true
	return false


# 旧单文件接口的兼容别名（统一落到存档槽 1）
static func save_game(state: Dictionary) -> Error:
	return save_slot(1, state)


static func load_game() -> Dictionary:
	return load_slot(1)


static func _write(path: String, state: Dictionary) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(state, "\t"))
	return OK


static func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
