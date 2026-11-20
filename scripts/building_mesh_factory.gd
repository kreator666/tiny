class_name BuildingMeshFactory
extends RefCounted
## 程序化盒体建筑网格（阶段2，方案1 纯色材质版）：几何 = 基座平台 + 盒体墙身 + 坡屋顶棱柱
## （与上一版一致，ArrayMesh 分 3 个 surface：0 基座 / 1 墙身 / 2 屋顶）。
## 材质不再包裹贴图区带（billboard 是 3/4 透视小景，裁条必错位），改为程序取色纯色：
##   屋顶 = 贴图 v0~0.25 不透明像素均值；墙身 = v0.3~0.7 均值向白 15%（防门窗拉深）；
##   基座 = v0.75~1.0 均值。取色失败回退宋风默认色（瓦青灰/粉白/青石），不崩溃。
## 四方向由渲染层旋转 90° 整数倍实现；每 surface 材质按 (类型, surface, tint) 缓存。

# 造型参数（tools/gen_3d_buildings.py 可生成同名 JSON 覆盖；键缺失时用此默认表）
const DEFAULT_PARAMS := {
	"hut": {"roof": "gable", "body_frac": 0.55},
	"tilehouse": {"roof": "gable", "body_frac": 0.55},
	"mill": {"roof": "gable", "body_frac": 0.55},
	"grocer": {"roof": "gable", "body_frac": 0.55},
	"market": {"roof": "gable", "body_frac": 0.60},
	"winery": {"roof": "gable", "body_frac": 0.55},
	"oilpress": {"roof": "gable", "body_frac": 0.55},
	"loom": {"roof": "flat", "body_frac": 0.85},
	"restaurant": {"roof": "gable", "body_frac": 0.60},
	"well": {"roof": "gable", "body_frac": 0.50},
	"clinic": {"roof": "gable", "body_frac": 0.55},
	"repair": {"roof": "flat", "body_frac": 0.85},
	"woodcutter": {"roof": "gable", "body_frac": 0.55},
}

# 贴图取色区带（v 从贴图顶部起算 UV 比例；几何不再使用 UV，仅取色参考）
const REGION_ROOF := Rect2(0.0, 0.0, 1.0, 0.25)
const REGION_BODY := Rect2(0.0, 0.3, 1.0, 0.4)
const REGION_BASE := Rect2(0.0, 0.75, 1.0, 0.25)

# 宋风兜底色（贴图缺失/全透明时）
const FALLBACK_ROOF := Color(0.36, 0.40, 0.46)  # 瓦青灰
const FALLBACK_BODY := Color(0.93, 0.89, 0.83)  # 粉白墙
const FALLBACK_BASE := Color(0.52, 0.54, 0.52)  # 青石基座

# surface 序号
const SURFACE_BASE := 0
const SURFACE_BODY := 1
const SURFACE_ROOF := 2

var params: Dictionary = {}  # 由渲染层注入（data/building_meshes.json，可空）
var _mesh_cache := {}
var _color_cache := {}  # btype -> [屋顶, 墙身, 基座]
var _mat_cache := {}


## 取（或生成）某建筑类型的低模网格（3 surface）；def 需含 mesh_size [w,h,d]（单位：格）
func get_mesh(btype: String, def: Dictionary) -> ArrayMesh:
	if _mesh_cache.has(btype):
		return _mesh_cache[btype]
	var mesh := _build_mesh(btype, def)
	_mesh_cache[btype] = mesh
	return mesh


## 每 surface 的立面材质：albedo_texture = facade 正交贴图 × albedo_color = 程序取色 tint
## （tint 让不同建筑共用贴图仍呈各自色调，如 winery 绛红）；贴图缺失/加载失败回退纯色素材
func get_material(btype: String, surface: int, tint: Color, def: Dictionary) -> StandardMaterial3D:
	var key := "%s:%d:%s" % [btype, surface, str(tint)]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var colors: Array = _colors(btype, def)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = (colors[surface] as Color) * tint
	var tex := _facade_tex(btype, surface)
	if tex != null:
		mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mat_cache[key] = mat
	return mat


## surface -> 立面贴图字段映射（tex_base/tex_wall/tex_roof），按文件名缓存加载
const SURFACE_TEX_KEY := {SURFACE_BASE: "tex_base", SURFACE_BODY: "tex_wall", SURFACE_ROOF: "tex_roof"}

const GHOST_ALPHA := 0.6  # 放置预览（幽灵）不透明度

var _facade_tex_cache := {}
var _ghost_mat_cache := {}


## 放置预览用半透明材质克隆（保留 facade 贴图与取色 tint，ALPHA 混合），按类型缓存复用
func get_ghost_materials(btype: String, def: Dictionary) -> Array:
	if _ghost_mat_cache.has(btype):
		return _ghost_mat_cache[btype]
	var mats: Array = []
	for si in 3:
		var src := get_material(btype, si, Color.WHITE, def)
		var m := StandardMaterial3D.new()
		m.albedo_texture = src.albedo_texture
		m.albedo_color = Color(src.albedo_color.r, src.albedo_color.g, src.albedo_color.b, GHOST_ALPHA)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.texture_filter = src.texture_filter
		mats.append(m)
	_ghost_mat_cache[btype] = mats
	return mats


func _facade_tex(btype: String, surface: int) -> Texture2D:
	var key: String = SURFACE_TEX_KEY[surface]
	var fname = _param(btype, key, "")
	if fname == "":
		return null
	if _facade_tex_cache.has(fname):
		return _facade_tex_cache[fname]
	var tex: Texture2D = load("res://assets/packs/gongbi/" + str(fname))
	_facade_tex_cache[fname] = tex  # 加载失败缓存 null，不重复尝试
	return tex


## 程序取色：按 surface 序号返回 [基座, 墙身, 屋顶]；墙身向白 15% 防门窗深色拉低均值
func _colors(btype: String, def: Dictionary) -> Array:
	if _color_cache.has(btype):
		return _color_cache[btype]
	var tex: Texture2D = null
	if def.has("tex_dirs") and not (def["tex_dirs"] as Array).is_empty():
		tex = def["tex_dirs"][0]
	elif def.has("tex"):
		tex = def["tex"]
	var img: Image = tex.get_image() if tex != null else null
	var colors: Array
	if img == null or img.is_empty():
		colors = [FALLBACK_BASE, FALLBACK_BODY, FALLBACK_ROOF]
	else:
		var base := _region_avg(img, REGION_BASE, FALLBACK_BASE)
		var body := _region_avg(img, REGION_BODY, FALLBACK_BODY).lerp(Color.WHITE, 0.15)
		var roof := _region_avg(img, REGION_ROOF, FALLBACK_ROOF)
		colors = [base, body, roof]
	_color_cache[btype] = colors
	return colors


## 区域不透明像素 RGB 均值（alpha<127 跳过；无有效像素回退 fallback）
func _region_avg(img: Image, region: Rect2, fallback: Color) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := maxi(0, int(region.position.x * w))
	var y0 := maxi(0, int(region.position.y * h))
	var x1 := mini(w, int((region.position.x + region.size.x) * w))
	var y1 := mini(h, int((region.position.y + region.size.y) * h))
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			if c.a < 0.5:  # alpha<127 跳过（透明底/软阴影）
				continue
			r += c.r
			g += c.g
			b += c.b
			n += 1
	if n == 0:
		return fallback
	return Color(r / n, g / n, b / n)


func _param(btype: String, key: String, fallback: Variant) -> Variant:
	if params.has(btype) and params[btype].has(key):
		return params[btype][key]
	if DEFAULT_PARAMS.has(btype) and DEFAULT_PARAMS[btype].has(key):
		return DEFAULT_PARAMS[btype][key]
	return fallback


func _build_mesh(btype: String, def: Dictionary) -> ArrayMesh:
	var ms: Array = def["mesh_size"]
	var size := Vector3(float(ms[0]), float(ms[1]), float(ms[2]))
	var roof := str(_param(btype, "roof", "gable"))
	var body_frac := float(_param(btype, "body_frac", 0.55))
	var base_h := mini(0.08, size.y * 0.1)
	var body_h := (size.y - base_h) * body_frac if roof == "gable" else size.y - base_h - 0.06
	var mesh := ArrayMesh.new()
	# 三个 surface 分开提交，各自挂纯色材质（基座/墙身/屋顶）
	var st_base := SurfaceTool.new()
	st_base.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(st_base, Vector3(size.x, base_h, size.z), base_h * 0.5)
	st_base.generate_normals()
	st_base.commit(mesh)
	var st_body := SurfaceTool.new()
	st_body.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box(st_body, Vector3(size.x * 0.94, body_h, size.z * 0.94), base_h + body_h * 0.5)
	st_body.generate_normals()
	st_body.commit(mesh)
	var st_roof := SurfaceTool.new()
	st_roof.begin(Mesh.PRIMITIVE_TRIANGLES)
	if roof == "gable":
		_add_prism(st_roof, size.x * 0.58, size.z * 0.58, base_h + body_h, size.y - base_h - body_h)
	else:
		_add_box(st_roof, Vector3(size.x * 1.0, 0.06, size.z * 1.0), size.y - 0.03)
	st_roof.generate_normals()
	st_roof.commit(mesh)
	for si in mesh.get_surface_count():
		mesh.surface_set_material(si, get_material(btype, si, Color.WHITE, def))
	mesh.resource_name = btype
	return mesh


## 轴对齐盒体 4 侧面 + 顶面
func _add_box(st: SurfaceTool, size: Vector3, cy: float) -> void:
	var hx := size.x / 2.0
	var hz := size.z / 2.0
	var y0 := cy - size.y / 2.0
	var y1 := cy + size.y / 2.0
	_quad(st, Vector3(-hx, y0, hz), Vector3(hx, y0, hz), Vector3(hx, y1, hz), Vector3(-hx, y1, hz))   # +z 正面
	_quad(st, Vector3(hx, y0, -hz), Vector3(-hx, y0, -hz), Vector3(-hx, y1, -hz), Vector3(hx, y1, -hz))  # -z
	_quad(st, Vector3(hx, y0, hz), Vector3(hx, y0, -hz), Vector3(hx, y1, -hz), Vector3(hx, y1, hz))   # +x
	_quad(st, Vector3(-hx, y0, -hz), Vector3(-hx, y0, hz), Vector3(-hx, y1, hz), Vector3(-hx, y1, -hz))  # -x
	_quad(st, Vector3(-hx, y1, hz), Vector3(hx, y1, hz), Vector3(hx, y1, -hz), Vector3(-hx, y1, -hz))  # 顶


## 坡屋顶棱柱：屋脊沿 X 轴，两坡面 + 两个山墙三角
func _add_prism(st: SurfaceTool, hx: float, hz: float, y_eave: float, h: float) -> void:
	var apex := y_eave + h
	# +z 坡面
	_quad(st, Vector3(-hx, y_eave, hz), Vector3(hx, y_eave, hz), Vector3(hx, apex, 0), Vector3(-hx, apex, 0))
	# -z 坡面
	_quad(st, Vector3(hx, y_eave, -hz), Vector3(-hx, y_eave, -hz), Vector3(-hx, apex, 0), Vector3(hx, apex, 0))
	# 山墙三角（+x / -x）
	_tri(st, Vector3(hx, y_eave, -hz), Vector3(hx, y_eave, hz), Vector3(hx, apex, 0))
	_tri(st, Vector3(-hx, y_eave, hz), Vector3(-hx, y_eave, -hz), Vector3(-hx, apex, 0))


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	## UV 0~1：一张立面贴图完整铺一个面（拉伸优先于平铺，避免接缝）
	st.set_uv(Vector2(0, 1)); st.add_vertex(a)
	st.set_uv(Vector2(1, 1)); st.add_vertex(b)
	st.set_uv(Vector2(1, 0)); st.add_vertex(c)
	st.set_uv(Vector2(0, 1)); st.add_vertex(a)
	st.set_uv(Vector2(1, 0)); st.add_vertex(c)
	st.set_uv(Vector2(0, 0)); st.add_vertex(d)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_uv(Vector2(0, 1)); st.add_vertex(a)
	st.set_uv(Vector2(1, 1)); st.add_vertex(b)
	st.set_uv(Vector2(0.5, 0)); st.add_vertex(c)
