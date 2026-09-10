class_name AssetLib
## 素材包加载器。
## 目录约定：
##   assets/packs/<包名>/*.png   一个文件夹即一个素材包
##   data/pack.json              {"active": "<包名>"} 切换激活包
## 规则：
##   - 启动时 init() 一次，之后 tex() 只读缓存（严禁在 _draw 中 load，见白屏事故）
##   - 激活包缺少的文件自动回退默认包 gongbi，因此新素材包可以逐张替换

const DEFAULT_PACK := "gongbi"
const BASE := "res://assets/packs/"

static var active := DEFAULT_PACK
static var _cache: Dictionary = {}  # 文件名 -> Texture2D（null 表示缺失已告警）


static func init() -> void:
	active = DEFAULT_PACK
	var f := FileAccess.open("res://data/pack.json", FileAccess.READ)
	if f:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has("active"):
			var want := str(parsed["active"])
			if DirAccess.dir_exists_absolute(BASE + want):
				active = want
			else:
				push_warning("素材包 '%s' 不存在，回退默认包 '%s'" % [want, DEFAULT_PACK])
	_cache.clear()


static func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var t: Texture2D = null
	if FileAccess.file_exists(BASE + active + "/" + name):
		t = load(BASE + active + "/" + name)
	elif FileAccess.file_exists(BASE + DEFAULT_PACK + "/" + name):
		t = load(BASE + DEFAULT_PACK + "/" + name)
	if t == null:
		push_error("贴图缺失: " + name)
	_cache[name] = t
	return t
