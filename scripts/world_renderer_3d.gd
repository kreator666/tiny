class_name WorldRenderer3D
extends Node3D
## 3D Billboard 渲染层（阶段1）+ 真 3D 低模建筑（阶段2，路线 B）：
##   地面/道路/农田 tile：y=0 水平 QuadMesh（1 格 = 1 个 3D 单位 = 48 像素）
##   建筑：默认 BuildingMeshFactory 程序化低模（盒体+坡屋顶+基座，UV 采样原 billboard 贴图区带），
##         按相机水平角以 90° 整数倍旋转对位四方向；use_meshes=false 或缺 mesh_size 时回退 Sprite3D 立牌
##   树/行人/大院：Sprite3D 立牌，底部中心锚地，逐帧面向相机
##   水车轮/酒楼幌子/市集旗：立牌子节点分层动画；炊烟/火焰：柔圆贴图池，
##     相位/尺寸/颜色/透明度逐一对照原 2D _draw 公式（git HEAD:scripts/main.gd）
##   昼夜：DirectionalLight3D + WorldEnvironment，按 2D 同一 _nightness/_duskness 公式插值
##   夜间灯火：OmniLight3D 池（取离相机目标最近的若干个，控制 gl_compatibility 灯数）
## 世界数据全部只读自 GameState；本类不改动任何游戏状态。
## 由 Main._process 单一驱动：_anim_t 累计 -> state.tick -> pan -> update_dynamic。

const PX := 1.0 / 48.0  # 像素 -> 3D 单位换算（1 格 = 48 像素）

const GROUND_SLAB := 28.0  # 基座平台典型厚度（像素），锚点 = 平台下缘行 - SLAB/2
const ESTATE_CENTER := Vector2(1.0, 1.0)

# 冒烟的建筑及其出烟点（画布坐标相对 (宽/2, 高)，即旧触地点；运行时按基座锚点自动补偿）
const SMOKE_BUILDINGS := {
	"mill": Vector2(-19, -62),
	"winery": Vector2(-13, -71),
	"hut": Vector2(-6, -74),
	"tilehouse": Vector2(-2, -72),
	"oilpress": Vector2(-28, -44),
	"restaurant": Vector2(7, -81),
}

# 磨坊水车：逐方向轮心（96x96 画布坐标，截图校订）
const MILL_WHEEL := [Vector2(75, 57), Vector2(70, 55), Vector2(72, 52), Vector2(25, 55)]
const WHEEL_SPEED := 0.6  # rad/s

# 市集三角旗：逐方向 {旗杆顶挂点, 朝向(1右/-1左), 尺寸}（画布坐标；波动参数同 2D）
const MARKET_FLAG := [
	{"at": Vector2(24, 4), "dir": 1.0, "size": Vector2(20, 7)},
	{"at": Vector2(61, 3), "dir": 1.0, "size": Vector2(19, 8)},
	{"at": Vector2(26, 3), "dir": 1.0, "size": Vector2(15, 6)},
	{"at": Vector2(32, 3), "dir": -1.0, "size": Vector2(19, 7)},
]
const FLAG_SEGS := 6  # 旗面分段数（同 2D 折线分段）

# 酒楼幌子：逐方向顶部挂点（画布坐标）
const REST_BANNER := [Vector2(12, 21), Vector2(62, 37), Vector2(13, 21), Vector2(40, 38)]

# 昼夜交替：一昼夜 60 秒（纯氛围，不与月份历法挂钩）
const DAY_SECONDS := 60.0
# 夜间点灯的建筑（民居/商业/酒楼）
const LIGHT_BUILDINGS := {"hut": 1, "tilehouse": 1, "market": 1, "restaurant": 1, "grocer": 1}
const MAX_NIGHT_LIGHTS := 10  # gl_compatibility 下限制实时光源数量
const MAX_SMOKE_SOURCES := 24  # 炊烟来源上限（每个 6 精灵：外圈+亮芯 x3 相位）

const WALKER_SCALE := 2.0  # 行人贴图放大倍数（同 2D）

var state: GameState  # 由 Main 注入
var camera: CameraRig  # 由 Main 注入
var use_meshes := true  # 双模式开关：false 整体回退 Sprite3D 立牌（便于对比）

var _anim_t := 0.0  # 动画时钟（水车/炊烟/行人/昼夜），由 Main._process 累计
var _cur_dir := 0  # 当前四方向贴图索引（相机水平角最近 90°）

var _factory := BuildingMeshFactory.new()

# 贴图运行时加载（素材包切换见 AssetLib）
var ground_tex: Array = []  # [ground_0, ground_1]
var tree_tex: Texture2D
var villager_tex: Texture2D
var road_tex: Dictionary = {}  # 方向键 -> Texture2D，键同 ROAD_KEYS
var estate_tex: Dictionary = {}  # 等级 2/3 -> [d0..d3]
var mill_wheel_tex: Array = []  # 水车转轮层 [d0..d3]
var mill_front_tex: Array = []  # 水车前景层（石柱/水流，保持静止）
var rest_banner_tex: Array = []  # 酒楼幌子 [d0..d3]

const ROAD_KEYS: Array = ["o", "n", "e", "s", "w", "ne", "ns", "nw", "es", "ew", "sw", "nes", "new", "nsw", "esw", "nesw"]

# 场景子节点
var _ground_mm: Array = []  # 草地 MultiMeshInstance3D x2
var _flat_root: Node3D  # 贴地 tile 池（道路/农田/flat 建筑）
var _billboard_root: Node3D  # 建筑/树/大院池
var _walker_root: Node3D
var _effect_root: Node3D  # 炊烟/火焰
var _light_root: Node3D
var _sun: DirectionalLight3D
var _world_env: WorldEnvironment

var _flat_tiles := {}  # cell -> MeshInstance3D
var _billboards := {}  # key -> {root, visual, visual_kind, kind, cell, anchor, extras}
var _walkers: Array = []  # Sprite3D 池
var _effects: Array = []  # {kind, sprites, origin}
var _puff_pool: Array = []  # 复用的柔圆 Sprite3D
var _lights: Array = []  # OmniLight3D 池

# 悬停/选中标记
var _hover_quad: MeshInstance3D
var _ghost_flat: MeshInstance3D  # flat 建筑幽灵（道路等贴地图标）
var _ghost: Node3D  # 幽灵容器
var _ghost_sprite: Sprite3D
var _ghost_mesh: MeshInstance3D
var _sel_frame: Array = []  # 选中金框（4 根细条）
var _road_path_root: Node3D  # 铺路拖拽预览（贴地高亮 Quad 池）
var _road_path_quads: Array = []

var _anchor_cache := {}
var _mat_cache := {}
var _unit_quad: QuadMesh
var _quad_flat_transform := Basis(Vector3(1, 0, 0), -PI / 2.0)  # XY 单位 Quad -> 铺地
var _puff_tex: ImageTexture
var _flame_tex: ImageTexture


func _ready() -> void:
	_load_pack_textures()
	_load_mesh_params()
	_unit_quad = QuadMesh.new()
	_unit_quad.size = Vector2.ONE
	_puff_tex = _make_radial_tex()
	_flame_tex = _make_flame_tex()
	_build_environment()
	_build_ground()
	_flat_root = Node3D.new()
	_flat_root.name = "FlatTiles"
	add_child(_flat_root)
	_billboard_root = Node3D.new()
	_billboard_root.name = "Buildings"
	add_child(_billboard_root)
	_walker_root = Node3D.new()
	_walker_root.name = "Walkers"
	add_child(_walker_root)
	_effect_root = Node3D.new()
	_effect_root.name = "Effects"
	add_child(_effect_root)
	_light_root = Node3D.new()
	_light_root.name = "NightLights"
	add_child(_light_root)
	_build_markers()


# ---------- 世界同步（状态变化时由 Main 调用） ----------

func sync_world() -> void:
	## 按 GameState 全量同步贴地 tile 与建筑/树/大院（建造/拆除/月结/读档后调用）
	_cur_dir = camera.get_view_dir_index()  # 单一来源：四方向索引始终以相机水平角为准
	_sync_flat_tiles()
	_sync_billboards()
	_sync_effects()


# ---------- 每帧动态更新（由 Main._process 在逻辑推进后调用） ----------

func update_dynamic() -> void:
	var idx := camera.get_view_dir_index()
	if idx != _cur_dir:
		_cur_dir = idx
		sync_world()  # 四方向贴图/网格朝向随视角季度切换
	var cam_pos: Vector3 = camera.camera.global_position
	var night := _nightness()
	_update_walkers(cam_pos)
	_update_buildings(cam_pos)
	_update_effects()
	_update_markers(cam_pos)
	_update_daynight(night)
	_update_night_lights(night)


## 鼠标所指地面点的 2D 像素坐标（喂给 GameState.screen_to_cell，接口同 2D 渲染层）
func mouse_grid_pos() -> Vector2:
	return camera.mouse_grid_pos()


## 指定屏幕点的地面点 2D 像素坐标（测试/调试用途）
func mouse_grid_pos_at(screen_pos: Vector2) -> Vector2:
	return camera.grid_pos_at(screen_pos)


## 指定屏幕点的射线与地面交点（测试/调试用途）
func ground_point_at(screen_pos: Vector2) -> Vector3:
	return camera.ground_at(screen_pos)


# ---------- 贴图与材质 ----------

func _load_pack_textures() -> void:
	ground_tex = [AssetLib.tex("ground_0.png"), AssetLib.tex("ground_1.png")]
	tree_tex = AssetLib.tex("tree.png")
	villager_tex = AssetLib.tex("villager.png")
	for k: String in ROAD_KEYS:
		road_tex[k] = AssetLib.tex("road_%s.png" % k)
	estate_tex = {2: [], 3: []}
	for tier in [2, 3]:
		for i in 4:
			estate_tex[tier].append(AssetLib.tex("estate%d_d%d.png" % [tier, i]))
	for i in 4:
		mill_wheel_tex.append(AssetLib.tex("mill_wheel_d%d.png" % i))
		mill_front_tex.append(AssetLib.tex("mill_front_d%d.png" % i))
		rest_banner_tex.append(AssetLib.tex("rest_banner_d%d.png" % i))


func _load_mesh_params() -> void:
	## 造型参数（data/building_meshes.json，由 tools/gen_3d_buildings.py 生成；缺失时用工厂内置默认）
	var file := FileAccess.open("res://data/building_meshes.json", FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_factory.params = parsed


## 立牌/网格材质：透明裁剪保持工笔边缘干净；带 tint 变体（火灾泛红等）
func _billboard_mat(tex: Texture2D, tint: Color = Color.WHITE) -> StandardMaterial3D:
	var key := "bb:%s:%s" % [tex.resource_path, str(tint)]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mat_cache[key] = mat
	return mat


## 半透明材质（幽灵/标记/烟火焰，用 modulate 控制颜色）
func _blend_mat(tex: Texture2D = null) -> StandardMaterial3D:
	var key := "blend:%s" % (tex.resource_path if tex else "none")
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mat := StandardMaterial3D.new()
	if tex:
		mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mat_cache[key] = mat
	return mat


func _make_radial_tex() -> ImageTexture:
	## 程序生成的柔圆贴图（炊烟用，颜色经 Sprite3D.modulate 调制）
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length() / 16.0
			var a := clampf(1.0 - d, 0.0, 1.0)
			a *= a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


func _make_flame_tex() -> ImageTexture:
	## 火焰轮廓贴图：上尖下宽的三角柔边（近似 2D 火苗三角形的 3D 替代）
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var u := (x + 0.5) / 32.0  # 0..1 左->右
			var v := 1.0 - (y + 0.5) / 32.0  # 0 底部 .. 1 顶部
			var half_w := 0.5 * pow(1.0 - v, 0.8)  # 顶部尖、底部宽
			var dx := absf(u - 0.5)
			var a := clampf((half_w - dx) / 0.18, 0.0, 1.0)
			a *= a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


# ---------- 锚点（同 2D：贴图基座平台中心 / 底部中心） ----------

func _ground_anchor(tex: Texture2D) -> Vector2:
	## 贴图地面落点（画布坐标）：自下而上找首行致密不透明行 = 基座平台下缘
	if _anchor_cache.has(tex):
		return _anchor_cache[tex]
	var img := tex.get_image()
	var w := img.get_width()
	var gy := img.get_height() - 1
	for y in range(img.get_height() - 1, -1, -1):
		var n := 0
		for x in w:
			if img.get_pixel(x, y).a > 0.4:
				n += 1
		if n * 4 >= w:
			gy = y
			break
	var anchor := Vector2(w / 2.0, gy - GROUND_SLAB / 2.0)
	_anchor_cache[tex] = anchor
	return anchor


## 画布点 -> 立牌本地坐标（sprite 原点 = 贴图锚点，底部中心对齐地面）
func _canvas_local(p: Vector2, anchor: Vector2) -> Vector3:
	return Vector3((p.x - anchor.x) * PX, (anchor.y - p.y) * PX, 0.0)


func _building_tex(btype: String) -> Texture2D:
	var def: Dictionary = state.building_defs[btype]
	if def.has("tex_dirs"):
		return def["tex_dirs"][_cur_dir]
	return def["tex"]


## 建筑类型的基准贴图（网格 UV 采样与立牌锚点共用 d0/单图）
func _base_tex(btype: String) -> Texture2D:
	var def: Dictionary = state.building_defs[btype]
	if def.has("tex_dirs"):
		return def["tex_dirs"][0]
	return def["tex"]


# 道路方向块：按格子四邻连接选贴图（键同 2D）
func _road_tex(cell: Vector2i) -> Texture2D:
	var mask := ""
	if state._is_road(cell + Vector2i(1, 0)):
		mask += "e"
	if state._is_road(cell + Vector2i(-1, 0)):
		mask += "w"
	if state._is_road(cell + Vector2i(0, 1)):
		mask += "s"
	if state._is_road(cell + Vector2i(0, -1)):
		mask += "n"
	var key := ""
	for c in "nesw":
		if c in mask:
			key += c
	if key.is_empty():
		key = "o"  # 孤立路块
	return road_tex[key]


# ---------- 环境 / 光照 ----------

func _build_environment() -> void:
	_world_env = WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.12, 0.10)  # 同 2D 底色
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.9
	_world_env.environment = env
	add_child(_world_env)
	_sun = DirectionalLight3D.new()
	_sun.shadow_enabled = false
	add_child(_sun)


func _update_daynight(night: float) -> void:
	## 按 2D 同一套昼夜公式插值（b=亮度, night, dusk）：
	##   2D 在整屏叠加 夜色 (0.08,0.11,0.38) x night*0.5、黄昏暖调 (0.95,0.55,0.25) x dusk*0.15；
	##   3D 用环境光颜色/能量逼近夜色混合，太阳色温逼近黄昏暖调，天空色 = 底色精确混合。
	var b := 0.5 + 0.5 * sin(fmod(_anim_t / DAY_SECONDS, 1.0) * TAU)
	var dusk := clampf(1.0 - absf(b - 0.55) / 0.3, 0.0, 1.0)
	_sun.rotation_degrees = Vector3(-(b * 75.0 - 10.0), 35.0, 0.0)
	_sun.light_energy = b * 1.1
	# 黄昏暖调：向 (0.95,0.55,0.25) 收敛，强度对照 2D 叠加 alpha dusk*0.15（乘法模型取 3 倍）
	_sun.light_color = Color(1.0, 0.72, 0.55).lerp(Color.WHITE, clampf(b * 1.4, 0.0, 1.0))
	var env := _world_env.environment
	# 夜色混合：能量降至 (1-0.5*night)，环境色向夜蓝的 2 倍收敛（补偿能量减半，等效 lerp 到夜蓝）
	env.ambient_light_energy = 0.9 * (1.0 - 0.5 * night)
	env.ambient_light_color = Color.WHITE.lerp(Color(0.16, 0.22, 0.76), night)
	# 天空色 = 2D 屏幕调色矩形的叠加结果（底色向夜蓝按 night*0.5 精确混合）
	env.background_color = Color(0.13, 0.12, 0.10).lerp(Color(0.08, 0.11, 0.38), night * 0.5)


func _update_night_lights(night: float) -> void:
	if night <= 0.02:
		for li: OmniLight3D in _lights:
			li.visible = false
		return
	# 收集夜间点灯位置（同 2D 抖动公式，避免灯火排队），取离相机目标最近的若干个
	var pts: Array = []
	for cell: Vector2i in state.buildings:
		if LIGHT_BUILDINGS.has(state.buildings[cell]) and not state.burning.has(cell):
			var btype: String = state.buildings[cell]
			var anchor := _ground_anchor(_base_tex(btype))
			var jx := sin(cell.x * 12.3 + cell.y * 7.7) * 8.0
			var jy := cos(cell.x * 5.1 + cell.y * 3.3) * 4.0
			pts.append(Vector3(cell.x + 0.5 + jx * PX, -anchor.y * 0.55 * PX + jy * PX, cell.y + 0.5))
	for anchor2: Vector2i in state.estates:
		var c := Vector3(anchor2.x + 1.0, 0.0, anchor2.y + 1.0)
		pts.append(c + Vector3(0, 34.0 * PX, 0))  # 正房
		pts.append(c + Vector3(-30.0 * PX, 18.0 * PX, 0))  # 两厢
		pts.append(c + Vector3(30.0 * PX, 18.0 * PX, 0))
	var tgt: Vector3 = camera.target
	pts.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		return a.distance_squared_to(tgt) < b.distance_squared_to(tgt))
	while _lights.size() < mini(pts.size(), MAX_NIGHT_LIGHTS):
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.72, 0.4)
		l.omni_range = 2.6
		_light_root.add_child(l)
		_lights.append(l)
	for i in _lights.size():
		var li: OmniLight3D = _lights[i]
		if i >= pts.size():
			li.visible = false
			continue
		li.visible = true
		li.global_position = pts[i]
		# 2D 灯火闪烁：0.9 + 0.1*sin(t*3 + x*0.7)
		li.light_energy = night * (0.72 + 0.08 * sin(_anim_t * 3.0 + pts[i].x * 0.7))


# ---------- 地面与贴地 tile ----------

func _build_ground() -> void:
	## 草地一次性 MultiMesh（两种变体各一个 draw call）
	for v in 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _unit_quad
		var cells: Array = []
		for cell: Vector2i in state.grass:
			if int(state.grass[cell]) == v:
				cells.append(cell)
		mm.instance_count = cells.size()
		for i in cells.size():
			var cell: Vector2i = cells[i]
			mm.set_instance_transform(i, Transform3D(_quad_flat_transform, Vector3(cell.x + 0.5, 0.0, cell.y + 0.5)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _billboard_mat(ground_tex[v])
		add_child(mmi)
		_ground_mm.append(mmi)


func _sync_flat_tiles() -> void:
	## 道路/农田/flat 建筑：按 state.buildings 增删贴地 Quad 池
	var want := {}
	for cell: Vector2i in state.buildings:
		var btype: String = state.buildings[cell]
		if not bool(state.building_defs[btype].get("flat", false)):
			continue
		var tex: Texture2D
		if btype == "road":
			tex = _road_tex(cell)
		elif state._is_farm(btype):
			tex = state.building_defs[btype]["tex_stages"][mini(int(state.farm_grow.get(cell, 0)), 3)]
		else:
			tex = _building_tex(btype)
		var tint := Color(1, 0.45, 0.35) if state.burning.has(cell) else Color.WHITE
		want[cell] = [tex, tint]
	for cell: Vector2i in _flat_tiles.keys():
		if not want.has(cell):
			_flat_tiles[cell].queue_free()
			_flat_tiles.erase(cell)
	for cell: Vector2i in want:
		var mi: MeshInstance3D = _flat_tiles.get(cell)
		if mi == null:
			mi = MeshInstance3D.new()
			mi.mesh = _unit_quad
			_flat_root.add_child(mi)
			_flat_tiles[cell] = mi
			mi.transform = Transform3D(_quad_flat_transform, Vector3(cell.x + 0.5, 0.0, cell.y + 0.5))
		var mat: StandardMaterial3D = _billboard_mat(want[cell][0], want[cell][1])
		if mi.material_override != mat:
			mi.material_override = mat


# ---------- 建筑/树/大院（网格立牌双模式） ----------

func _use_mesh_for(kind: String) -> bool:
	if not use_meshes or kind == "tree" or kind == "estate":
		return false
	var def: Dictionary = state.building_defs.get(kind, {})
	return def.has("mesh_size") and not bool(def.get("flat", false))


func _sync_billboards() -> void:
	var want := {}
	for cell: Vector2i in state.trees:
		want["t:%s" % cell] = {"kind": "tree", "cell": cell}
	for cell: Vector2i in state.buildings:
		var btype: String = state.buildings[cell]
		if not bool(state.building_defs[btype].get("flat", false)):
			want["b:%s" % cell] = {"kind": btype, "cell": cell}
	for anchor: Vector2i in state.estates:
		want["e:%s" % anchor] = {"kind": "estate", "cell": anchor}
	for key: String in _billboards.keys():
		if not want.has(key):
			_billboards[key].root.queue_free()
			_billboards.erase(key)
	for key: String in want:
		var entry = _billboards.get(key)  # Dictionary 或 null
		if entry == null:
			entry = _make_billboard(want[key]["kind"], want[key]["cell"])
			_billboards[key] = entry
		_refresh_billboard(entry)


func _make_billboard(kind: String, cell: Vector2i) -> Dictionary:
	var root := Node3D.new()
	_billboard_root.add_child(root)
	var sign := Node3D.new()  # 幌子/旗面挂载点：逐帧面向相机
	root.add_child(sign)
	var entry := {"root": root, "visual": null, "visual_kind": "", "kind": kind,
		"cell": cell, "anchor": Vector2.ZERO, "extras": {"sign": sign}}
	if kind == "mill":
		var wheel := Sprite3D.new()
		wheel.pixel_size = PX
		wheel.shaded = true
		root.add_child(wheel)
		var front := Sprite3D.new()
		front.pixel_size = PX
		front.shaded = true
		sign.add_child(front)
		entry.extras = {"sign": sign, "wheel": wheel, "front": front}
	elif kind == "restaurant":
		var pivot := Node3D.new()
		sign.add_child(pivot)
		var banner := Sprite3D.new()
		banner.pixel_size = PX
		banner.shaded = true
		pivot.add_child(banner)
		entry.extras = {"sign": sign, "pivot": pivot, "banner": banner}
	elif kind == "market":
		var strips: Array = []
		for i in FLAG_SEGS:
			var strip := MeshInstance3D.new()
			strip.mesh = _unit_quad
			sign.add_child(strip)
			strips.append(strip)
		entry.extras = {"sign": sign, "strips": strips}
	return entry


func _refresh_billboard(entry: Dictionary) -> void:
	## 按当前四方向索引设置视觉内容：网格（MeshInstance3D）或立牌（Sprite3D）
	var kind: String = entry.kind
	var cell: Vector2i = entry.cell
	var tex: Texture2D
	match kind:
		"tree":
			tex = tree_tex
		"estate":
			tex = estate_tex[state.estates[cell]][_cur_dir]
		_:
			tex = _building_tex(kind)
	entry.anchor = _ground_anchor(tex) if kind != "tree" else Vector2(tex.get_width() / 2.0, tex.get_height())
	var root: Node3D = entry.root
	var pos := Vector3.ZERO
	match kind:
		"tree":
			pos = Vector3(cell.x + 0.5, 0.0, cell.y + 0.5)
		"estate":
			pos = Vector3(cell.x + ESTATE_CENTER.x, 0.0, cell.y + ESTATE_CENTER.y)
		_:
			pos = Vector3(cell.x + 0.5, 0.0, cell.y + 0.5)
	root.position = pos
	var tint := Color(1, 0.45, 0.35) if state.burning.has(cell) else Color.WHITE
	var want_kind := "mesh" if _use_mesh_for(kind) else "sprite"
	if entry.visual_kind != want_kind:
		if entry.visual:
			entry.visual.queue_free()
		if want_kind == "mesh":
			entry.visual = MeshInstance3D.new()
		else:
			var sprite := Sprite3D.new()
			sprite.pixel_size = PX
			sprite.shaded = true
			entry.visual = sprite
		root.add_child(entry.visual)
		entry.visual_kind = want_kind
	if want_kind == "mesh":
		var def: Dictionary = state.building_defs[kind]
		var mi: MeshInstance3D = entry.visual
		mi.mesh = _factory.get_mesh(kind, def)
		mi.material_override = null  # 纯色材质按 surface 挂载，避免被贴图覆盖
		for si in mi.mesh.get_surface_count():
			mi.set_surface_override_material(si, _factory.get_material(kind, si, tint, def))
		mi.rotation = Vector3(0, _cur_dir * PI / 2.0, 0)  # 四方向：90° 整数倍对位
	else:
		var sprite2: Sprite3D = entry.visual
		sprite2.texture = tex
		sprite2.material_override = _billboard_mat(tex, tint)
		sprite2.centered = true
		sprite2.offset = Vector2(0, tex.get_height() / 2.0)  # 底部中心对齐地面
	# 分层附加物（画布锚点换算，坐标挂在 root/sign 本地）
	var extras: Dictionary = entry.extras
	if extras.has("wheel"):
		var anchor: Vector2 = entry.anchor
		var wc: Vector2 = MILL_WHEEL[_cur_dir] - anchor  # 轮心画布点（boff = -anchor）
		extras.wheel.position = _canvas_local(wc, anchor) + Vector3(0, 0, 0.01)
		extras.wheel.texture = mill_wheel_tex[_cur_dir]
		extras.wheel.material_override = _billboard_mat(mill_wheel_tex[_cur_dir], tint)
		var fc: Vector2 = MILL_WHEEL[_cur_dir] - anchor
		extras.front.position = _canvas_local(fc, anchor) + Vector3(0, 0, 0.02)
		extras.front.texture = mill_front_tex[_cur_dir]
		extras.front.material_override = _billboard_mat(mill_front_tex[_cur_dir], tint)
	if extras.has("pivot"):
		var anchor2: Vector2 = entry.anchor
		var hang: Vector2 = REST_BANNER[_cur_dir] - anchor2
		extras.pivot.position = _canvas_local(hang, anchor2) + Vector3(0, 0, 0.01)
		var btex: Texture2D = rest_banner_tex[_cur_dir]
		extras.banner.texture = btex
		extras.banner.material_override = _billboard_mat(btex, Color.WHITE)
		extras.banner.centered = true
		extras.banner.offset = Vector2(0, -btex.get_height() / 2.0)  # 顶部挂点悬垂
	if extras.has("strips"):
		var anchor3: Vector2 = entry.anchor
		var fi: Dictionary = MARKET_FLAG[_cur_dir]
		var at: Vector2 = (fi["at"] as Vector2) - anchor3
		extras.sign.set_meta("flag_at", _canvas_local(at, anchor3))
		extras.sign.set_meta("flag_dir", fi["dir"])
		extras.sign.set_meta("flag_size", fi["size"])
		for strip: MeshInstance3D in extras.strips:
			strip.material_override = _flag_mat()


func _flag_mat() -> StandardMaterial3D:
	if _mat_cache.has("flag"):
		return _mat_cache["flag"]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.82, 0.16, 0.12)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache["flag"] = mat
	return mat


func _update_buildings(cam_pos: Vector3) -> void:
	## 逐帧：立牌面向相机（网格模式仅招牌面面向相机）；水车轮自转；幌子摆动；旗面正弦波动
	for key: String in _billboards:
		var entry: Dictionary = _billboards[key]
		var root: Node3D = entry.root
		var extras: Dictionary = entry.extras
		if entry.visual_kind == "mesh":
			root.rotation = Vector3.ZERO  # 网格建筑保持竖直，四方向在 refresh 时 90° 步进
		elif root.position.distance_squared_to(cam_pos) < 2500.0:
			root.look_at(cam_pos, Vector3.UP)
		var cell: Vector2i = entry.cell
		if extras.has("wheel"):
			var wheel: Sprite3D = extras.wheel
			wheel.look_at(cam_pos, Vector3.UP)
			wheel.rotate_z(_anim_t * WHEEL_SPEED)  # 绕轮心（本地原点）自转
		var sign: Node3D = extras.sign
		if extras.has("pivot"):
			sign.look_at(cam_pos, Vector3.UP)
			extras.pivot.rotation = Vector3(0, 0, sin(_anim_t * 2.1 + cell.x * 1.3 + cell.y * 0.7) * 0.07)
		if extras.has("strips"):
			sign.look_at(cam_pos, Vector3.UP)
			_update_flag_strips(sign, cell, extras.strips)


func _update_flag_strips(sign: Node3D, cell: Vector2i, strips: Array) -> void:
	## 市集三角旗：6 段正弦波动，频率/振幅同 2D（wave = sin(phase - t*5) * (0.5 + 2t)）
	var at: Vector3 = sign.get_meta("flag_at")
	var dir_sign := float(sign.get_meta("flag_dir"))
	var size: Vector2 = sign.get_meta("flag_size")
	var phase := _anim_t * 6.0 + cell.x * 1.1 + cell.y * 0.6
	var strip_w := size.x / FLAG_SEGS
	for i in strips.size():
		var t := float(i) / FLAG_SEGS
		var wave := sin(phase - t * 5.0) * (0.5 + 2.0 * t)
		var hh := size.y * (1.0 - 0.7 * t)
		var strip: MeshInstance3D = strips[i]
		strip.position = at + Vector3(dir_sign * (t + 0.5 / FLAG_SEGS) * size.x * PX, (wave + t * 2.0 - size.y / 2.0) * PX, 0.01)
		strip.scale = Vector3(strip_w * PX, hh * PX, 1.0)


# ---------- 行人 ----------

func _update_walkers(cam_pos: Vector3) -> void:
	var n: int = state.walkers.size()
	while _walkers.size() < n:
		var s := Sprite3D.new()
		s.pixel_size = PX * WALKER_SCALE
		s.texture = villager_tex
		s.material_override = _billboard_mat(villager_tex)
		_walker_root.add_child(s)
		_walkers.append(s)
	for i in range(_walkers.size() - 1, n - 1, -1):
		_walkers[i].queue_free()
		_walkers.remove_at(i)
	for i in n:
		var w: Dictionary = state.walkers[i]
		var s: Sprite3D = _walkers[i]
		var wkind := int(w.get("kind", 0))
		var tint := Color.WHITE
		match wkind:
			1:
				tint = Color(0.95, 0.78, 0.6)  # 挑夫：暖色
			2:
				tint = Color(0.62, 0.8, 0.98)  # 挑水夫：蓝色
			3:
				tint = Color(0.55, 0.75, 0.45)  # 伐木工：草绿
			4:
				tint = Color(0.85, 0.55, 0.75)  # 郎中：紫红
			5:
				tint = Color(0.98, 0.82, 0.35)  # 工匠：藤黄
			6:
				tint = Color(0.72, 0.58, 0.36)  # 农夫：草帽褐
		s.modulate = tint
		var bob := absf(sin(_anim_t * 8.0 + w.pos.x * 1.7 + w.pos.y)) * 2.0
		s.position = Vector3(w.pos.x + 0.5, (villager_tex.get_height() / 2.0 + bob) * PX * WALKER_SCALE, w.pos.y + 0.5)
		s.look_at(cam_pos, Vector3.UP)


# ---------- 炊烟 / 火焰（公式逐一对照 2D） ----------

func _take_puff(tex: ImageTexture) -> Sprite3D:
	for p: Sprite3D in _puff_pool:
		if not p.visible:
			p.visible = true
			p.texture = tex
			p.material_override = _blend_mat()
			return p
	var p := Sprite3D.new()
	p.pixel_size = PX
	p.texture = tex
	p.material_override = _blend_mat()
	_effect_root.add_child(p)
	_puff_pool.append(p)
	return p


func _sync_effects() -> void:
	for e: Dictionary in _effects:
		for sp: Sprite3D in e.sprites:
			sp.visible = false
	_effects.clear()
	# 炊烟来源（上限内取离相机目标最近的建筑）
	var sources: Array = []
	for cell: Vector2i in state.buildings:
		var btype: String = state.buildings[cell]
		if state.burning.has(cell):
			_add_fire_effect(cell, btype)
		elif SMOKE_BUILDINGS.has(btype):
			sources.append(cell)
	var tgt: Vector3 = camera.target
	sources.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector3(a.x, 0, a.y).distance_squared_to(tgt) < Vector3(b.x, 0, b.y).distance_squared_to(tgt))
	for i in mini(sources.size(), MAX_SMOKE_SOURCES):
		_add_smoke_effect(sources[i])


func _smoke_origin(cell: Vector2i, btype: String) -> Vector3:
	var btex := _building_tex(btype)
	var anchor := _ground_anchor(btex)
	# 2D：SMOKE_BUILDINGS + (0, 贴图高 + boff.y)，boff = -anchor
	var p: Vector2 = SMOKE_BUILDINGS[btype] + Vector2(0, btex.get_height() - anchor.y)
	return Vector3(cell.x + 0.5, 0, cell.y + 0.5) + _canvas_local(p, anchor)


func _add_smoke_effect(cell: Vector2i) -> void:
	# 2D 每相位两圆：外圈 r*1.4 (0.48,0.50,0.54) + 亮芯 r*0.8 (0.72,0.73,0.76)
	var origin := _smoke_origin(cell, state.buildings[cell])
	var sprites: Array = []
	for k in 6:
		sprites.append(_take_puff(_puff_tex))
	_effects.append({"kind": "smoke", "sprites": sprites, "origin": origin})


func _add_fire_effect(cell: Vector2i, btype: String) -> void:
	var btex := _building_tex(btype)
	var anchor := _ground_anchor(btex)
	var top_local := (anchor.y - 6.0) * PX  # 2D：boff.y + 6 之上的跳焰
	var origin := Vector3(cell.x + 0.5, top_local, cell.y + 0.5)
	# 3 簇火苗 x（外层橙 + 黄心）+ 3 团黑烟
	var sprites: Array = []
	for k in 9:
		sprites.append(_take_puff(_flame_tex if k < 6 else _puff_tex))
	_effects.append({"kind": "fire", "sprites": sprites, "origin": origin})


func _update_effects() -> void:
	## 2D 原公式（git HEAD:scripts/main.gd _draw_smoke/_draw_flames/_draw_fire_smoke）：
	## 烟圈 ph=t*0.4+k/3 周期，r=3+6ph，上浮 30px，x 摆动 sin(t*1.7+k*2.1)*3ph
	## 火苗 h=12+7sin(t*11+i*2.3)，倾摆 lean=3sin(t*7+i*1.7)，外橙内黄双层三角
	## 火烟 ph=t*0.5+k/3，r=5+13ph，上浮 8+42px，x 摆动 sin(t*1.3+k*2.4)*4ph
	for e: Dictionary in _effects:
		var origin: Vector3 = e.origin
		if e.kind == "smoke":
			for k in 3:
				var sp: Sprite3D = e.sprites[k]
				var core: Sprite3D = e.sprites[3 + k]
				var ph := fmod(_anim_t * 0.4 + k / 3.0, 1.0)
				var r := 3.0 + 6.0 * ph
				var px: float = sin(_anim_t * 1.7 + k * 2.1) * 3.0 * ph
				sp.position = origin + Vector3(px * PX, 30.0 * ph * PX, 0)
				sp.scale = Vector3((r * 2.8) / 32.0, (r * 2.8) / 32.0, 1)  # 直径 r*1.4*2
				sp.modulate = Color(0.48, 0.50, 0.54, 0.55 * (1.0 - ph))
				core.position = sp.position
				core.scale = Vector3((r * 1.6) / 32.0, (r * 1.6) / 32.0, 1)  # 直径 r*0.8*2
				core.modulate = Color(0.72, 0.73, 0.76, 0.4 * (1.0 - ph))
		else:
			for i in 3:
				var outer: Sprite3D = e.sprites[i * 2]
				var inner: Sprite3D = e.sprites[i * 2 + 1]
				var fx := -18.0 + i * 18.0
				var h := 12.0 + 7.0 * sin(_anim_t * 11.0 + i * 2.3)
				var lean := 3.0 * sin(_anim_t * 7.0 + i * 1.7)
				var base_x := (fx + lean * 0.5) * PX  # 倾摆近似：顶端偏移 lean
				outer.position = origin + Vector3(base_x, h * PX / 2.0, 0)
				outer.scale = Vector3(10.0 / 32.0, h / 32.0, 1)  # 底宽 10px
				outer.rotation.z = -atan(lean / h)
				outer.modulate = Color(0.95, 0.45, 0.15, 0.9)
				inner.position = origin + Vector3(base_x, h * 0.55 * PX / 2.0, 0)
				inner.scale = Vector3(5.0 / 32.0, h * 0.55 / 32.0, 1)
				inner.rotation.z = -atan(lean * 0.6 / (h * 0.55))
				inner.modulate = Color(1.0, 0.85, 0.3, 0.95)
			for k in 3:
				var sp2: Sprite3D = e.sprites[6 + k]
				var ph2 := fmod(_anim_t * 0.5 + k / 3.0, 1.0)
				var r2 := 5.0 + 13.0 * ph2
				sp2.position = origin + Vector3(sin(_anim_t * 1.3 + k * 2.4) * 4.0 * ph2 * PX, (8.0 + 42.0 * ph2) * PX, 0)
				var s2 := (r2 * 2.0) / 32.0
				sp2.scale = Vector3(s2, s2, 1)
				sp2.modulate = Color(0.12, 0.11, 0.12, 0.55 * (1.0 - ph2))


# ---------- 悬停 / 选中标记 ----------

func _build_markers() -> void:
	_hover_quad = MeshInstance3D.new()
	_hover_quad.mesh = _unit_quad
	_hover_quad.visible = false
	add_child(_hover_quad)
	_ghost_flat = MeshInstance3D.new()
	_ghost_flat.mesh = _unit_quad
	_ghost_flat.visible = false
	add_child(_ghost_flat)
	_ghost = Node3D.new()  # 幽灵容器：内含 Sprite3D（立牌）与 MeshInstance3D（网格）二选一
	_ghost_sprite = Sprite3D.new()
	_ghost_sprite.pixel_size = PX
	_ghost_sprite.visible = false
	_ghost.add_child(_ghost_sprite)
	_ghost_mesh = MeshInstance3D.new()
	_ghost_mesh.visible = false
	_ghost.add_child(_ghost_mesh)
	_ghost.visible = false
	add_child(_ghost)
	for i in 4:
		var bar := MeshInstance3D.new()
		bar.mesh = _unit_quad
		bar.material_override = _flag_mat_for(Color(1.0, 0.88, 0.35, 0.9))
		bar.visible = false
		add_child(bar)
		_sel_frame.append(bar)
	_road_path_root = Node3D.new()
	_road_path_root.name = "RoadPathPreview"
	add_child(_road_path_root)


# ---------- 铺路拖拽预览（贴地高亮 Quad 池，不逐帧实例化） ----------

## 按路径顺序显示贴地高亮：绿=按序可铺，红=将被跳过（越界/占用/有树/钱不够）。
## 可铺判定与 pave_road_path 一致：顺序模拟逐格扣款（DEBUG 模式免费）。
func sync_road_path(cells: Array) -> void:
	var cost := int(state.building_defs["road"]["cost_gold"])
	var remaining := state.gold
	while _road_path_quads.size() < cells.size():
		var q := MeshInstance3D.new()
		q.mesh = _unit_quad
		_road_path_root.add_child(q)
		_road_path_quads.append(q)
	for i in _road_path_quads.size():
		var quad: MeshInstance3D = _road_path_quads[i]
		if i >= cells.size():
			quad.visible = false
			continue
		var cell: Vector2i = cells[i]
		var ok := state._in_bounds(cell) and not state._is_occupied(cell) \
			and not state.trees.has(cell) and (Main.debug_mode or remaining >= cost)
		if ok and not Main.debug_mode:
			remaining -= cost
		quad.visible = true
		quad.transform = Transform3D(_quad_flat_transform, Vector3(cell.x + 0.5, 0.02, cell.y + 0.5))
		quad.material_override = _flag_mat_for(Color(0.4, 0.9, 0.4, 0.25) if ok else Color(0.9, 0.3, 0.3, 0.35))


func clear_road_path() -> void:
	for quad: MeshInstance3D in _road_path_quads:
		quad.visible = false


func _flag_mat_for(color: Color) -> StandardMaterial3D:
	var key := "mark:%s" % str(color)
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_cache[key] = mat
	return mat


func _update_markers(cam_pos: Vector3) -> void:
	## 悬停合法格标记（贴地半透明 Quad + 幽灵贴图）与选中金框
	var hover: Vector2i = state.hover_cell
	var show := state._in_bounds(hover) and not state.selected_tool.is_empty()
	_hover_quad.visible = show
	_ghost.visible = false
	_ghost_flat.visible = false
	if show:
		_hover_quad.transform = Transform3D(_quad_flat_transform, Vector3(hover.x + 0.5, 0.02, hover.y + 0.5))
		if state.selected_tool == "demolish":
			var can_demo := state._estate_anchor_at(hover) != Vector2i(-1, -1) or state.buildings.has(hover) or state.trees.has(hover)
			_hover_quad.material_override = _flag_mat_for(Color(0.9, 0.3, 0.3, 0.3) if can_demo else Color(0.5, 0.5, 0.5, 0.2))
		else:
			var valid := not state._is_occupied(hover)
			_hover_quad.material_override = _flag_mat_for(Color(0.4, 0.9, 0.4, 0.25) if valid else Color(0.9, 0.3, 0.3, 0.35))
			if valid:
				_show_ghost(hover, cam_pos)
	# 选中建筑金框（1x1 或大院 2x2）
	var sel: Vector2i = state.selected_cell
	var show_sel := sel != Vector2i(-1, -1)
	if show_sel:
		var anchor := state._estate_anchor_at(sel)
		var origin_cell := anchor if anchor != Vector2i(-1, -1) else sel
		var cells := 2 if anchor != Vector2i(-1, -1) else 1
		_place_sel_frame(Vector3(origin_cell.x + 0.5, 0.03, origin_cell.y + 0.5), float(cells))
	for bar: MeshInstance3D in _sel_frame:
		bar.visible = show_sel


func _show_ghost(cell: Vector2i, cam_pos: Vector3) -> void:
	var tool := state.selected_tool
	if not state.building_defs.has(tool):
		return
	var ghost_def: Dictionary = state.building_defs[tool]
	if bool(ghost_def.get("flat", false)):
		var gtex: Texture2D = road_tex["o"] if tool == "road" else _building_tex(tool)
		_ghost_flat.visible = true
		_ghost_flat.transform = Transform3D(_quad_flat_transform, Vector3(cell.x + 0.5, 0.01, cell.y + 0.5))
		# MeshInstance3D 无 modulate：用专用半透明材质（按贴图缓存，不影响共享 blend 材质）
		var gkey := "ghostflat:%s" % gtex.resource_path
		if not _mat_cache.has(gkey):
			var gm := StandardMaterial3D.new()
			gm.albedo_texture = gtex
			gm.albedo_color = Color(1, 1, 1, 0.6)
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gm.cull_mode = BaseMaterial3D.CULL_DISABLED
			gm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			_mat_cache[gkey] = gm
		_ghost_flat.material_override = _mat_cache[gkey]
	else:
		var gtex2 := _building_tex(tool)
		_ghost.visible = true
		if _use_mesh_for(tool):
			# 网格模式：预览 = 实体同款 ArrayMesh + facade 贴图×tint 的半透明克隆材质
			_ghost_sprite.visible = false
			_ghost_mesh.visible = true
			_ghost_mesh.mesh = _factory.get_mesh(tool, ghost_def)
			_ghost_mesh.material_override = null
			var ghost_mats: Array = _factory.get_ghost_materials(tool, ghost_def)
			for si in mini(ghost_mats.size(), _ghost_mesh.mesh.get_surface_count()):
				_ghost_mesh.set_surface_override_material(si, ghost_mats[si])
			_ghost.position = Vector3(cell.x + 0.5, 0, cell.y + 0.5)
			_ghost.rotation = Vector3(0, _cur_dir * PI / 2.0, 0)
		else:
			_ghost_mesh.visible = false
			_ghost_sprite.visible = true
			_ghost_sprite.texture = gtex2
			_ghost_sprite.material_override = _blend_mat(gtex2)
			_ghost_sprite.modulate = Color(1, 1, 1, 0.6)
			_ghost.position = Vector3(cell.x + 0.5, 0, cell.y + 0.5)
			_ghost.rotation = Vector3.ZERO
			_ghost_sprite.offset = Vector2(0, gtex2.get_height() / 2.0)
			_ghost.look_at(cam_pos, Vector3.UP)


func _place_sel_frame(center: Vector3, cells: float) -> void:
	## 四根细条拼贴地金框（长 cells 格、线宽 0.04；本地 X->世界 X，本地 Y->世界 Z，本地 Z->世界 Y）
	var t := 0.04
	var half := cells / 2.0
	var bars := [
		[Vector3(center.x, 0, center.z - half), Vector3(cells, t, 0.02)],
		[Vector3(center.x, 0, center.z + half), Vector3(cells, t, 0.02)],
		[Vector3(center.x - half, 0, center.z), Vector3(t, cells, 0.02)],
		[Vector3(center.x + half, 0, center.z), Vector3(t, cells, 0.02)],
	]
	for i in 4:
		var bar: MeshInstance3D = _sel_frame[i]
		bar.transform = Transform3D(_quad_flat_transform.scaled(bars[i][1] as Vector3), bars[i][0] as Vector3)


# ---------- 昼夜公式（与 2D 相同） ----------

func _nightness() -> float:
	var b := 0.5 + 0.5 * sin(fmod(_anim_t / DAY_SECONDS, 1.0) * TAU)
	return clampf((0.55 - b) / 0.55, 0.0, 1.0)
