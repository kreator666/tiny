class_name BuildingMeshFactory
extends RefCounted
## 程序化建筑网格：blueprint 部件蓝图（优先）+ 盒体+坡顶通用模板（回退）。
## blueprint：data/building_meshes.json 每种建筑 5~15 个部件 {shape,size,offset,tex}，
## 按 billboard 原画轮廓定制（水井=井栏+立柱+攒尖顶、市集=开敞摊棚、酒楼=两层楼阁等）。
##   shape ∈ box/prism(双坡棱柱,屋脊沿X)/pyramid(四坡攒尖)/cylinder(竖直圆柱)/
##           ramp(楔形,后高前低)/plane(竖直薄片)；offset=[x,y底,z]（x/z 中心、y 底面高）。
##   tex = "base"/"wall"/"roof"（该建筑 facade 贴图）/ facade 贴图名 / null（取色纯色）。
## surface 组织（4 个，序号恒定，幽灵材质按实际 surface 数适配）：
##   0 基座 / 1 墙身 / 2 屋顶（facade 贴图 × 取色 tint，明度提升版）/ 3 取色纯色（顶点色）。
## 回退路径（无 blueprint）：基座 + 墙身 + 屋顶变体（gable/hip/pyramid/thick_thatch）+ 功能附件，
## 3 个 surface（0/1/2）。贴图缺失/加载失败回退纯色，取色失败回退宋风默认色，均不崩溃。
## 四方向 90° 旋转、use_meshes=false 立牌模式、建造预览（幽灵=同款网格+半透明材质）由渲染层统一处理。

# 造型参数（tools/gen_3d_buildings.py 生成 data/building_meshes.json 覆盖；键缺失时用此默认表）
const DEFAULT_PARAMS := {
	"hut": {"roof_style": "gable", "body_frac": 0.50,
		"tex_roof": "facade/roof_thatch.png", "tex_wall": "facade/hut_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": []},
	"tilehouse": {"roof_style": "gable", "body_frac": 0.55,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/tilehouse_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": []},
	"mill": {"roof_style": "gable", "body_frac": 0.55,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/mill_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": []},
	"grocer": {"roof_style": "gable", "body_frac": 0.55,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/grocer_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["awning"]},
	"market": {"roof_style": "gable", "body_frac": 0.65,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/market_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["awning"]},
	"winery": {"roof_style": "gable", "body_frac": 0.55,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/winery_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["jars"]},
	"oilpress": {"roof_style": "thick_thatch", "body_frac": 0.50,
		"tex_roof": "facade/roof_thatch.png", "tex_wall": "facade/oilpress_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["chimney"]},
	"loom": {"roof_style": "flat", "body_frac": 0.85,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/loom_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["rack"]},
	"restaurant": {"roof_style": "gable", "body_frac": 0.70,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/restaurant_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["banner_pole"]},
	"well": {"roof_style": "pyramid", "body_frac": 0.45,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/well_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["well_ring"]},
	"clinic": {"roof_style": "gable", "body_frac": 0.55,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/clinic_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["plaque"]},
	"repair": {"roof_style": "flat", "body_frac": 0.85,
		"tex_roof": "facade/roof_tile.png", "tex_wall": "facade/repair_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["woodpile"]},
	"woodcutter": {"roof_style": "thick_thatch", "body_frac": 0.55,
		"tex_roof": "facade/roof_thatch.png", "tex_wall": "facade/woodcutter_wall.png", "tex_base": "facade/base_stone.png",
		"attachments": ["woodpile"]},
}

# 贴图取色区带（v 从贴图顶部起算 UV 比例；取色参考，几何 UV 恒为 0~1 整图铺面）
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
const SURFACE_PLAIN := 3  # 取色纯色部件（tex=null）：顶点色作 albedo，无贴图

const GHOST_ALPHA := 0.6  # 放置预览（幽灵）不透明度

var params: Dictionary = {}  # 由渲染层注入（data/building_meshes.json，可空）
var _mesh_cache := {}
var _color_cache := {}  # btype -> [基座, 墙身, 屋顶]（surface 序）
var _mat_cache := {}
var _facade_tex_cache := {}
var _ghost_mat_cache := {}


## 取（或生成）某建筑类型的低模网格（3 surface）；def 需含 mesh_size [w,h,d]（单位：格）
func get_mesh(btype: String, def: Dictionary) -> ArrayMesh:
	if _mesh_cache.has(btype):
		return _mesh_cache[btype]
	var mesh := _build_mesh(btype, def)
	_mesh_cache[btype] = mesh
	return mesh


## 每 surface 的立面材质：facade 贴图 × 取色 tint（明度提升版，D 修正）；surface 3 纯色+顶点色
func get_material(btype: String, surface: int, tint: Color, def: Dictionary) -> StandardMaterial3D:
	var key := "%s:%d:%s" % [btype, surface, str(tint)]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mat := StandardMaterial3D.new()
	if surface == SURFACE_PLAIN:
		mat.albedo_color = tint
		mat.vertex_color_use_as_albedo = true
	else:
		var colors: Array = _colors(btype, def)
		mat.albedo_color = _lifted(colors[surface] as Color) * tint
		var tex := _facade_tex(btype, surface)
		if tex != null:
			mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_mat_cache[key] = mat
	return mat


## D 修正：tint 明度向白提升（保留色相，亮度提到 0.85+），避免贴图×tint 相乘发闷
func _lifted(c: Color) -> Color:
	var lum := c.get_luminance()
	if lum >= 0.85:
		return c
	return c.lerp(Color.WHITE, clampf((0.85 - lum) / 0.85, 0.0, 0.8))


## 放置预览用半透明材质克隆（保留 facade 贴图与提升后 tint，ALPHA 混合），按类型缓存复用；
## surface 数与实体网格一致（blueprint 4 个 / 回退 3 个）
func get_ghost_materials(btype: String, def: Dictionary) -> Array:
	if _ghost_mat_cache.has(btype):
		return _ghost_mat_cache[btype]
	var mats: Array = []
	var mesh := get_mesh(btype, def)
	for si in mesh.get_surface_count():
		var src := get_material(btype, si, Color.WHITE, def)
		var m := StandardMaterial3D.new()
		m.albedo_texture = src.albedo_texture
		m.albedo_color = Color(src.albedo_color.r, src.albedo_color.g, src.albedo_color.b, GHOST_ALPHA)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.texture_filter = src.texture_filter
		m.vertex_color_use_as_albedo = src.vertex_color_use_as_albedo
		mats.append(m)
	_ghost_mat_cache[btype] = mats
	return mats


## surface -> 立面贴图字段映射（tex_base/tex_wall/tex_roof），按文件名缓存加载
const SURFACE_TEX_KEY := {SURFACE_BASE: "tex_base", SURFACE_BODY: "tex_wall", SURFACE_ROOF: "tex_roof"}


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
			if c.a < 0.5:
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
	var bp: Variant = _param(btype, "blueprint", null)
	if bp is Array and not bp.is_empty():
		return _build_blueprint(btype, def, bp)
	return _build_box_template(btype, def)


## 盒体+坡顶通用模板（blueprint 缺失时的回退路径；surface 0 基座 / 1 墙身+附件 / 2 屋顶）
func _build_box_template(btype: String, def: Dictionary) -> ArrayMesh:
	var ms: Array = def["mesh_size"]
	var size := Vector3(float(ms[0]), float(ms[1]), float(ms[2]))
	var style := str(_param(btype, "roof_style", "gable"))
	var body_frac := float(_param(btype, "body_frac", 0.55))
	var base_h := mini(0.08, size.y * 0.1)
	var has_roof_mass := style != "flat"
	var body_h := (size.y - base_h) * (body_frac if has_roof_mass else 0.9)
	if style == "flat":
		body_h = size.y - base_h - 0.06
	var roof_h := size.y - base_h - body_h
	var mesh := ArrayMesh.new()
	# surface 0：基座平台（贴地）
	var st_base := SurfaceTool.new()
	st_base.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_box_at(st_base, Vector3(size.x, base_h, size.z), Vector3(0, base_h * 0.5, 0))
	st_base.generate_normals()
	st_base.commit(mesh)
	# surface 1：墙身 + 功能附件（挂墙/贴地类）
	var st_body := SurfaceTool.new()
	st_body.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bx := size.x * 0.94
	var bz := size.z * 0.94
	_add_box_at(st_body, Vector3(bx, body_h, bz), Vector3(0, base_h + body_h * 0.5, 0))
	for att in (_param(btype, "attachments", []) as Array):
		match str(att):
			"awning":
				_attach_awning(st_body, size, base_h, body_h)
			"banner_pole":
				_attach_banner_pole(st_body, bx, bz, base_h + body_h)
			"jars":
				_attach_jars(st_body, base_h, bz)
			"woodpile":
				_attach_woodpile(st_body, base_h, bz)
			"plaque":
				_attach_plaque(st_body, base_h, body_h, bz)
			"rack":
				_attach_rack(st_body, base_h, body_h, bx, bz)
			"well_ring":
				_attach_well_ring(st_body, base_h)
	st_body.generate_normals()
	st_body.commit(mesh)
	# surface 2：屋顶（变体）+ 屋上附件
	var st_roof := SurfaceTool.new()
	st_roof.begin(Mesh.PRIMITIVE_TRIANGLES)
	match style:
		"gable":
			_add_prism(st_roof, size.x * 0.58, size.z * 0.58, base_h + body_h, roof_h)
		"hip":
			_add_hip(st_roof, size.x * 0.60, size.z * 0.60, base_h + body_h, roof_h)
		"pyramid":
			_add_pyramid(st_roof, size.x * 0.62, size.z * 0.62, base_h + body_h, roof_h)
		"thick_thatch":
			_add_frustum(st_roof, size.x * 0.75, size.z * 0.75, size.x * 0.26, size.z * 0.26,
				base_h + body_h, roof_h)
		_:
			_add_box_at(st_roof, Vector3(size.x, 0.06, size.z), Vector3(0, size.y - 0.03, 0))
	for att2 in (_param(btype, "attachments", []) as Array):
		if str(att2) == "chimney":
			_attach_chimney(st_roof, size, roof_h)
	st_roof.generate_normals()
	st_roof.commit(mesh)
	for si in mesh.get_surface_count():
		mesh.surface_set_material(si, get_material(btype, si, Color.WHITE, def))
	mesh.resource_name = btype
	return mesh


# ---------- blueprint 部件蓝图解释器 ----------

## 遍历 blueprint 部件生成几何入同一 ArrayMesh 的 4 个 surface（0 基座 / 1 墙身 / 2 屋顶 / 3 取色纯色）；
## 部件：{shape, size:[x,y,z], offset:[x,y底,z], tex}，tex 解析不到贴图角色时进纯色 surface
func _build_blueprint(btype: String, def: Dictionary, bp: Array) -> ArrayMesh:
	var sts: Array = []
	var used: Array = []
	for i in 4:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		sts.append(st)
		used.append(false)
	for part_v in bp:
		var part: Dictionary = part_v
		var shape := str(part.get("shape", "box"))
		var size_a: Array = part.get("size", [0.2, 0.2, 0.2])
		var off_a: Array = part.get("offset", [0, 0, 0])
		var s := Vector3(float(size_a[0]), float(size_a[1]), float(size_a[2]))
		var o := Vector3(float(off_a[0]), float(off_a[1]), float(off_a[2]))
		var si := _part_surface(btype, part)
		var st: SurfaceTool = sts[si]
		used[si] = true
		if si == SURFACE_PLAIN:
			st.set_color(_plain_color(btype, def, shape))
		match shape:
			"prism":
				_add_prism(st, s.x / 2.0, s.z / 2.0, o.y, s.y)
			"pyramid":
				_add_pyramid(st, s.x / 2.0, s.z / 2.0, o.y, s.y)
			"cylinder":
				_add_cylinder(st, s.x / 2.0, s.y, Vector3(o.x, o.y + s.y / 2.0, o.z))
			"ramp":
				_add_ramp(st, s, o)
			"plane":
				_add_plane(st, s.x, s.y, o)
			_:
				_add_box_at(st, s, Vector3(o.x, o.y + s.y / 2.0, o.z))
	# 空 surface 补零面积退化三角形占位，保持 0/1/2/3 序号恒定（材质/幽灵按序号对位）
	for i in 4:
		if not used[i]:
			_tri(sts[i], Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
	var mesh := ArrayMesh.new()
	for st2 in sts:
		st2.generate_normals()
		st2.commit(mesh)
	for si2 in mesh.get_surface_count():
		mesh.surface_set_material(si2, get_material(btype, si2, Color.WHITE, def))
	mesh.resource_name = btype
	return mesh


## 部件 -> surface：tex="base"/"wall"/"roof" 关键字，或与该建筑三张 facade 贴图名比对；
## null 或未匹配 -> 取色纯色 surface 3
func _part_surface(btype: String, part: Dictionary) -> int:
	var tex: Variant = part.get("tex", null)
	if tex == null:
		return SURFACE_PLAIN
	var t := str(tex)
	match t:
		"base":
			return SURFACE_BASE
		"wall":
			return SURFACE_BODY
		"roof":
			return SURFACE_ROOF
	if t == str(_param(btype, "tex_base", "")):
		return SURFACE_BASE
	if t == str(_param(btype, "tex_wall", "")):
		return SURFACE_BODY
	if t == str(_param(btype, "tex_roof", "")):
		return SURFACE_ROOF
	return SURFACE_PLAIN


## 纯色部件取色：屋顶形（prism/pyramid）取屋顶色，其余取墙身色（均明度提升）
func _plain_color(btype: String, def: Dictionary, shape: String) -> Color:
	var colors: Array = _colors(btype, def)
	var idx := SURFACE_ROOF if shape == "prism" or shape == "pyramid" else SURFACE_BODY
	return _lifted(colors[idx] as Color)


# ---------- 屋顶变体 ----------

## 双坡屋顶：屋脊沿 X 轴，两坡面 + 山墙三角
func _add_prism(st: SurfaceTool, hx: float, hz: float, y_eave: float, h: float) -> void:
	var apex := y_eave + h
	_quad(st, Vector3(-hx, y_eave, hz), Vector3(hx, y_eave, hz), Vector3(hx, apex, 0), Vector3(-hx, apex, 0))
	_quad(st, Vector3(hx, y_eave, -hz), Vector3(-hx, y_eave, -hz), Vector3(-hx, apex, 0), Vector3(hx, apex, 0))
	_tri(st, Vector3(hx, y_eave, -hz), Vector3(hx, y_eave, hz), Vector3(hx, apex, 0))
	_tri(st, Vector3(-hx, y_eave, hz), Vector3(-hx, y_eave, -hz), Vector3(-hx, apex, 0))


## 四坡（歇山近似）：短屋脊 + 前后坡 + 两垂脊三角
func _add_hip(st: SurfaceTool, hx: float, hz: float, y_eave: float, h: float) -> void:
	var apex := y_eave + h
	var rx := hx * 0.45
	_quad(st, Vector3(-hx, y_eave, hz), Vector3(hx, y_eave, hz), Vector3(rx, apex, 0), Vector3(-rx, apex, 0))
	_quad(st, Vector3(hx, y_eave, -hz), Vector3(-hx, y_eave, -hz), Vector3(-rx, apex, 0), Vector3(rx, apex, 0))
	_tri(st, Vector3(hx, y_eave, hz), Vector3(hx, y_eave, -hz), Vector3(rx, apex, 0))
	_tri(st, Vector3(-hx, y_eave, -hz), Vector3(-hx, y_eave, hz), Vector3(-rx, apex, 0))


## 攒尖顶：四坡汇于中点
func _add_pyramid(st: SurfaceTool, hx: float, hz: float, y_eave: float, h: float) -> void:
	var apex := Vector3(0, y_eave + h, 0)
	_tri(st, Vector3(-hx, y_eave, hz), Vector3(hx, y_eave, hz), apex)
	_tri(st, Vector3(hx, y_eave, -hz), Vector3(-hx, y_eave, -hz), apex)
	_tri(st, Vector3(hx, y_eave, hz), Vector3(hx, y_eave, -hz), apex)
	_tri(st, Vector3(-hx, y_eave, -hz), Vector3(-hx, y_eave, hz), apex)


## 厚檐方锥（梯形草顶）：大出挑收分 + 顶面小平台
func _add_frustum(st: SurfaceTool, hxo: float, hzo: float, hxi: float, hzi: float,
		y_eave: float, h: float) -> void:
	var y1 := y_eave + h
	_quad(st, Vector3(-hxo, y_eave, hzo), Vector3(hxo, y_eave, hzo), Vector3(hxi, y1, hzi), Vector3(-hxi, y1, hzi))
	_quad(st, Vector3(hxo, y_eave, -hzo), Vector3(-hxo, y_eave, -hzo), Vector3(-hxi, y1, -hzi), Vector3(hxi, y1, -hzi))
	_quad(st, Vector3(hxo, y_eave, hzo), Vector3(hxo, y_eave, -hzo), Vector3(hxi, y1, -hzi), Vector3(hxi, y1, hzi))
	_quad(st, Vector3(-hxo, y_eave, -hzo), Vector3(-hxo, y_eave, hzo), Vector3(-hxi, y1, hzi), Vector3(-hxi, y1, -hzi))
	_quad(st, Vector3(-hxi, y1, hzi), Vector3(hxi, y1, hzi), Vector3(hxi, y1, -hzi), Vector3(-hxi, y1, -hzi))


# ---------- 功能附件（低模，纳入对应 surface 随建筑旋转） ----------

## 布篷：门口斜挑方篷（双面材质）
func _attach_awning(st: SurfaceTool, size: Vector3, base_h: float, body_h: float) -> void:
	var hz := size.z * 0.94 / 2.0
	var y := base_h + body_h * 0.78
	var w := size.x * 0.72
	var drop := body_h * 0.16
	var out := 0.36
	_quad(st, Vector3(-w / 2, y, hz - 0.05), Vector3(w / 2, y, hz - 0.05),
		Vector3(w / 2, y - drop, hz + out), Vector3(-w / 2, y - drop, hz + out))


## 幌杆：檐下水平横杆（幌子 Sprite3D 由渲染层另挂）
func _attach_banner_pole(st: SurfaceTool, bx: float, bz: float, y_eave: float) -> void:
	_add_box_at(st, Vector3(bx * 0.85, 0.05, 0.05), Vector3(0, y_eave - 0.12, bz / 2 + 0.14))


## 坛堆：门侧 2~3 个小陶坛（圆柱）
func _attach_jars(st: SurfaceTool, base_h: float, bz: float) -> void:
	_add_cylinder(st, 0.13, 0.30, Vector3(0.32, base_h + 0.15, bz / 2 + 0.16))
	_add_cylinder(st, 0.11, 0.24, Vector3(0.56, base_h + 0.12, bz / 2 + 0.14))
	_add_cylinder(st, 0.09, 0.20, Vector3(0.44, base_h + 0.38, bz / 2 + 0.15))


## 烟囱：屋上细高盒
func _attach_chimney(st: SurfaceTool, size: Vector3, roof_h: float) -> void:
	_add_box_at(st, Vector3(0.16, 0.55, 0.16), Vector3(size.x * 0.26, size.y - roof_h * 0.3, -size.z * 0.16))


## 柴堆/木料堆：门侧三层收分盒
func _attach_woodpile(st: SurfaceTool, base_h: float, bz: float) -> void:
	var x := -0.34
	_add_box_at(st, Vector3(0.52, 0.14, 0.26), Vector3(x, base_h + 0.07, bz / 2 + 0.14))
	_add_box_at(st, Vector3(0.40, 0.13, 0.22), Vector3(x, base_h + 0.20, bz / 2 + 0.13))
	_add_box_at(st, Vector3(0.26, 0.12, 0.18), Vector3(x, base_h + 0.32, bz / 2 + 0.12))


## 牌匾：门楣小盒
func _attach_plaque(st: SurfaceTool, base_h: float, body_h: float, bz: float) -> void:
	_add_box_at(st, Vector3(0.38, 0.20, 0.05), Vector3(0, base_h + body_h * 0.82, bz / 2 + 0.03))


## 晾布杆：门框两侧立杆 + 横杆
func _attach_rack(st: SurfaceTool, base_h: float, body_h: float, bx: float, bz: float) -> void:
	var y0 := base_h
	var y1 := base_h + body_h * 0.9
	var x := bx / 2 + 0.10
	_add_box_at(st, Vector3(0.05, y1 - y0, 0.05), Vector3(-x, (y0 + y1) / 2, bz / 2 + 0.12))
	_add_box_at(st, Vector3(0.05, y1 - y0, 0.05), Vector3(x, (y0 + y1) / 2, bz / 2 + 0.12))
	_add_box_at(st, Vector3(x * 2 + 0.05, 0.05, 0.05), Vector3(0, y1, bz / 2 + 0.12))


## 石栏圈：井口矮圆环（外壁 + 内壁 + 顶面环）
func _attach_well_ring(st: SurfaceTool, base_h: float) -> void:
	_add_ring(st, 0.34, 0.24, 0.28, Vector3(0, base_h + 0.14, 0), 10)


# ---------- 基础几何 ----------

func _add_box_at(st: SurfaceTool, size: Vector3, c: Vector3) -> void:
	var hx := size.x / 2.0
	var hz := size.z / 2.0
	var y0 := c.y - size.y / 2.0
	var y1 := c.y + size.y / 2.0
	_quad(st, Vector3(c.x - hx, y0, c.z + hz), Vector3(c.x + hx, y0, c.z + hz), Vector3(c.x + hx, y1, c.z + hz), Vector3(c.x - hx, y1, c.z + hz))
	_quad(st, Vector3(c.x + hx, y0, c.z - hz), Vector3(c.x - hx, y0, c.z - hz), Vector3(c.x - hx, y1, c.z - hz), Vector3(c.x + hx, y1, c.z - hz))
	_quad(st, Vector3(c.x + hx, y0, c.z + hz), Vector3(c.x + hx, y0, c.z - hz), Vector3(c.x + hx, y1, c.z - hz), Vector3(c.x + hx, y1, c.z + hz))
	_quad(st, Vector3(c.x - hx, y0, c.z - hz), Vector3(c.x - hx, y0, c.z + hz), Vector3(c.x - hx, y1, c.z + hz), Vector3(c.x - hx, y1, c.z - hz))
	_quad(st, Vector3(c.x - hx, y1, c.z + hz), Vector3(c.x + hx, y1, c.z + hz), Vector3(c.x + hx, y1, c.z - hz), Vector3(c.x - hx, y1, c.z - hz))


## 圆柱侧面（seg 段）
func _add_cylinder(st: SurfaceTool, r: float, h: float, c: Vector3, seg := 8) -> void:
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var p0 := c + Vector3(cos(a0) * r, -h / 2, sin(a0) * r)
		var p1 := c + Vector3(cos(a1) * r, -h / 2, sin(a1) * r)
		_quad(st, p0, p1, p1 + Vector3(0, h, 0), p0 + Vector3(0, h, 0))


## 圆环井栏：外壁 + 内壁 + 顶面环带
func _add_ring(st: SurfaceTool, r_out: float, r_in: float, h: float, c: Vector3, seg := 10) -> void:
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var o0 := Vector3(cos(a0), 0, sin(a0))
		var o1 := Vector3(cos(a1), 0, sin(a1))
		# 外壁
		_quad(st, c + o0 * r_out + Vector3(0, -h / 2, 0), c + o1 * r_out + Vector3(0, -h / 2, 0),
			c + o1 * r_out + Vector3(0, h / 2, 0), c + o0 * r_out + Vector3(0, h / 2, 0))
		# 内壁
		_quad(st, c + o1 * r_in + Vector3(0, -h / 2, 0), c + o0 * r_in + Vector3(0, -h / 2, 0),
			c + o0 * r_in + Vector3(0, h / 2, 0), c + o1 * r_in + Vector3(0, h / 2, 0))
		# 顶面环带
		_quad(st, c + o0 * r_in + Vector3(0, h / 2, 0), c + o0 * r_out + Vector3(0, h / 2, 0),
			c + o1 * r_out + Vector3(0, h / 2, 0), c + o1 * r_in + Vector3(0, h / 2, 0))


## 楔形（后高前低）：底面 + 后壁 + 斜面 + 两侧三角（布篷/棚顶/料堆）
func _add_ramp(st: SurfaceTool, s: Vector3, o: Vector3) -> void:
	var x0 := o.x - s.x / 2.0
	var x1 := o.x + s.x / 2.0
	var y0 := o.y
	var y1 := o.y + s.y
	var z0 := o.z - s.z / 2.0  # 后（高侧）
	var z1 := o.z + s.z / 2.0  # 前（低侧）
	_quad(st, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1))
	_quad(st, Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0))
	_quad(st, Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0))
	_tri(st, Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z0))
	_tri(st, Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0))


## 竖直薄片：XY 平面双面四边形（布幔/门脸/布匹；CULL_DISABLED 自带双面）
func _add_plane(st: SurfaceTool, w: float, h: float, o: Vector3) -> void:
	var x0 := o.x - w / 2.0
	var x1 := o.x + w / 2.0
	_quad(st, Vector3(x0, o.y, o.z), Vector3(x1, o.y, o.z),
		Vector3(x1, o.y + h, o.z), Vector3(x0, o.y + h, o.z))


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
