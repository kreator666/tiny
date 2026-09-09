class_name SaveManager
extends RefCounted
## 负责把游戏状态存成 JSON 文件、再读回来。
## 存档位置：Godot 的 user:// 目录（Windows 下是
## C:\Users\<用户名>\AppData\Roaming\Godot\app_userdata\新宋 · 治所\）

const SAVE_PATH := "user://save_city.json"


static func save_game(state: Dictionary) -> Error:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(state, "\t"))
	return OK


static func load_game() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
