extends Node3D
## Visual world of the Kashmir map: streamed terrain (scripts/world/terrain_streamer.gd), the airfields' runways
## and lights, and forests planted from the land cover (scripts/world/cover_forest.gd). Pure presentation:
## gameplay queries go through WorldData. This node sits at minus the floating origin, so its children keep map
## coordinates.

const TerrainStreamer := preload("res://scripts/world/terrain_streamer.gd")
const SM := preload("res://scripts/world/surface_materials.gd")

var streamer: Node3D
var _tree_mats: Array = []          # [detailed, simple] tree materials, shared by every forest batch


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # static scenery, updated per frame
	var tex: Dictionary = SM.terrain_textures()
	var ts: Node3D = TerrainStreamer.new()
	ts.name = "Terrain"
	if ts.setup(WorldData.terrain_dir):
		ts.material.set_shader_parameter("macro_tex", tex.macro)
		ts.material.set_shader_parameter("detail_tex", tex.detail)
		ts.material.set_shader_parameter("detail_nrm", tex.normal)
		# the sky system keeps the haze uniforms of every material in this list current (aerial perspective)
		SM.add_haze_material(ts.material)
		# a sibling of this node, not a child: it places its tiles in scene coordinates itself (floating origin)
		get_parent().add_child.call_deferred(ts)
		streamer = ts
	var af: Node3D = preload("res://scripts/world/airfields.gd").new()
	af.name = "Airfields"
	add_child(af)
	af.build(WorldData.airfields)
	var lights: Node3D = preload("res://scripts/world/airfield_lights.gd").new()
	lights.name = "AirfieldLights"
	add_child(lights)
	_make_tree_materials()
	var cf: Node3D = preload("res://scripts/world/cover_forest.gd").new()
	cf.name = "CoverForest"
	cf.setup(self)
	add_child(cf)
	Settings.changed.connect(func(k, _v):
		if String(k).begins_with("graphics/"):
			_apply_settings())
	_apply_settings()


func _make_tree_materials() -> void:
	var near_mat := ShaderMaterial.new()
	near_mat.shader = preload("res://shaders/tree.gdshader")
	near_mat.set_shader_parameter("far_set", false)
	var far_mat := near_mat.duplicate() as ShaderMaterial
	far_mat.set_shader_parameter("far_set", true)
	_tree_mats = [near_mat, far_mat]


func _apply_settings() -> void:
	var q: Dictionary = Settings.tree_level()
	for m in _tree_mats:
		(m as ShaderMaterial).set_shader_parameter("min_pixels", float(q.px))
		# forest density is applied when the trees are planted (scripts/world/cover_forest.gd), so thinned-out trees
		# cost nothing at all; the shader's own thinning stays off
		(m as ShaderMaterial).set_shader_parameter("density", 1.0)


var _wind_set := -1.0


func _process(_delta: float) -> void:
	var w := clampf(WorldData.atmosphere.wind_speed / 10.0, 0.15, 1.2)
	if w != _wind_set:
		_wind_set = w
		for m in _tree_mats:
			(m as ShaderMaterial).set_shader_parameter("wind", w)


# ---------------- tree meshes (vertex colours, soft foliage normals) ----------------
## Layered conifer: trunk plus jagged tiers. Normals point out from the crown axis, so the foliage is lit softly.
func _conifer_mesh(detailed: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(st, 0.32, 2.6 if detailed else 2.0, 6 if detailed else 4)
	var tiers := [[1.6, 7.2, 3.3], [4.4, 10.4, 2.6], [7.4, 13.2, 1.9], [10.2, 15.4, 1.1]] if detailed else [[1.6, 15.0, 3.2]]
	var seg := 10 if detailed else 6
	for t in tiers.size():
		var tier: Array = tiers[t]
		var y0: float = tier[0]
		var y1: float = tier[1]
		var r: float = tier[2]
		var shade := lerpf(0.7, 1.0, float(t) / maxf(tiers.size() - 1, 1))
		var base_col := Color(0.045, 0.11, 0.05) * shade
		var tip_col := Color(0.08, 0.17, 0.07) * shade
		for k in seg:
			var a0 := TAU * k / seg
			var a1 := TAU * (k + 1) / seg
			var jag0 := r * (1.0 if k % 2 == 0 else 0.78)
			var jag1 := r * (1.0 if (k + 1) % 2 == 0 else 0.78)
			var p0 := Vector3(cos(a0) * jag0, y0 + (0.0 if k % 2 == 0 else 0.35), sin(a0) * jag0)
			var p1 := Vector3(cos(a1) * jag1, y0 + (0.0 if (k + 1) % 2 == 0 else 0.35), sin(a1) * jag1)
			var top := Vector3(0, y1, 0)
			_soft_tri(st, [p0, top, p1], [base_col, tip_col, base_col], Vector3(0, y0 + (y1 - y0) * 0.3, 0))
			_soft_tri(st, [p1, Vector3(0, y0 + 0.4, 0), p0], [base_col * 0.6, base_col * 0.6, base_col * 0.6], Vector3(0, y0 + 2.0, 0))
	var mesh := st.commit()
	return mesh


## Broadleaf: trunk plus a crown of a few overlapping blobs.
func _broadleaf_mesh(detailed: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_trunk(st, 0.38, 4.2, 6 if detailed else 4)
	var blobs := [[Vector3(0, 7.2, 0), 3.4], [Vector3(1.6, 6.2, 0.9), 2.5], [Vector3(-1.4, 6.5, -1.1), 2.6], [Vector3(0.2, 8.9, -0.4), 2.2]] if detailed else [[Vector3(0, 7.2, 0), 3.9]]
	for bl in blobs:
		var c: Vector3 = bl[0]
		var r: float = bl[1]
		_blob(st, c, r * 1.15, Color(0.1, 0.2, 0.055), Color(0.05, 0.11, 0.035), false)
	return st.commit()


func _trunk(st: SurfaceTool, r: float, h: float, seg: int) -> void:
	var col := Color(0.22, 0.16, 0.1)
	for k in seg:
		var a0 := TAU * k / seg
		var a1 := TAU * (k + 1) / seg
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		var q0 := Vector3(cos(a0) * r * 0.6, h, sin(a0) * r * 0.6)
		var q1 := Vector3(cos(a1) * r * 0.6, h, sin(a1) * r * 0.6)
		_soft_tri(st, [p0, q0, p1], [col, col, col], Vector3(0, 0, 0), true)
		_soft_tri(st, [p1, q0, q1], [col, col, col], Vector3(0, 0, 0), true)


## Low-poly sphere (icosahedron, optionally subdivided once) squashed slightly, with spherical normals.
func _blob(st: SurfaceTool, c: Vector3, r: float, top_col: Color, bottom_col: Color, subdivide: bool) -> void:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
		Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var tris := []
	for tri in f:
		var a: Vector3 = (v[tri[0]] as Vector3).normalized()
		var b: Vector3 = (v[tri[1]] as Vector3).normalized()
		var d: Vector3 = (v[tri[2]] as Vector3).normalized()
		if subdivide:
			var ab := (a + b).normalized(); var bd := (b + d).normalized(); var da := (d + a).normalized()
			tris.append_array([[a, ab, da], [ab, b, bd], [da, bd, d], [ab, bd, da]])
		else:
			tris.append([a, b, d])
	for tri in tris:
		var pts := []
		var cols := []
		for p in tri:
			var q: Vector3 = p
			var wob := 1.0 + 0.12 * sin(q.x * 7.0 + q.z * 5.0)
			pts.append(c + Vector3(q.x * r * wob, q.y * r * 0.82 * wob, q.z * r * wob))
			cols.append(bottom_col.lerp(top_col, clampf(q.y * 0.5 + 0.5, 0.0, 1.0)))
		_soft_tri(st, pts, cols, c)


## Adds a triangle whose normals point away from `centre` (soft, rounded lighting for foliage).
func _soft_tri(st: SurfaceTool, pts: Array, cols: Array, centre: Vector3, flat := false) -> void:
	var face := ((pts[1] as Vector3) - (pts[0] as Vector3)).cross((pts[2] as Vector3) - (pts[0] as Vector3)).normalized()
	for k in 3:
		var p: Vector3 = pts[k]
		var nrm := face
		if not flat:
			var radial := p - centre
			radial.y *= 0.6
			nrm = (radial.normalized() * 0.75 + face * 0.25 + Vector3.UP * 0.2).normalized()
		st.set_color(cols[k])
		st.set_normal(nrm)
		st.add_vertex(p)
