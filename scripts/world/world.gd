extends Node3D
## Visual world: terrain chunks (from Blender), procedural terrain shading,
## ocean, and forests. Pure presentation, gameplay queries go through WorldData.

const WORLD_SCENE := "res://assets/world/world.glb"
const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const OCEAN_SHADER := preload("res://shaders/ocean.gdshader")
const TREE_VISIBLE_RANGE := 6500.0
const AIRBASE_EXCLUSION := Rect2(-200.0, 4100.0, 1000.0, 3800.0)   # x, z, w, d

var forest_mask: Image
var _ocean: MeshInstance3D
var _forests: Array[MultiMeshInstance3D] = []
var _forests_far: Array[MultiMeshInstance3D] = []
var _tree_mats: Array = []
var _trees := {}            # species -> [[Transform3D, Color], ...]
var _tree_grid := {}        # species -> {Vector2i cell: PackedInt32Array of indices}
var _near_pool := {}        # species -> MultiMeshInstance3D (detailed, shadow-casting)
var _near_center := Vector2(INF, INF)
const GRID := 250.0
var _tree_near := TREE_NEAR
const TREE_RANGES := [4000.0, 7000.0, 11000.0]
const TREE_NEAR := 1100.0           # detailed (shadow-casting) trees inside this distance, simple ones beyond
const DENSITY_RES := 512            # forest density map resolution (80 m texels)


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # static scenery, updated per frame
	var world: Node3D = load(WORLD_SCENE).instantiate()
	world.name = "Map"
	add_child(world)
	_sharpen_textures(world)
	_procedural_runway(world, preload("res://scripts/world/surface_materials.gd").terrain_textures())
	# the airbase's shelters, lanes and props are built from AirbaseLayout (shared with the server)
	for n in world.find_children("Shelter_*", "Node3D", true, false):
		(n as Node3D).visible = false
	var airbase: Node3D = preload("res://scripts/world/airbase.gd").new()
	airbase.name = "Airbase"
	airbase.map = world
	add_child(airbase)

	forest_mask = _make_forest_density()
	var tex: Dictionary = preload("res://scripts/world/surface_materials.gd").terrain_textures()
	var tmat := ShaderMaterial.new()
	tmat.shader = TERRAIN_SHADER
	tmat.set_shader_parameter("forest_density", ImageTexture.create_from_image(forest_mask))
	tmat.set_shader_parameter("macro_tex", tex.macro)
	tmat.set_shader_parameter("detail_tex", tex.detail)
	tmat.set_shader_parameter("detail_nrm", tex.normal)
	tmat.set_shader_parameter("map_half_extent", WorldData.half_extent)
	# the seabed takes the sea's distance haze too (the sky system updates every material in this list)
	preload("res://scripts/world/surface_materials.gd").ocean_materials.append(tmat)
	for n in world.find_children("Terrain_*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.material_override = tmat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_build_ocean()
	_build_forests()
	var lights: Node3D = preload("res://scripts/world/airfield_lights.gd").new()
	lights.name = "AirfieldLights"
	add_child(lights)
	Settings.changed.connect(func(_k, _v): _apply_settings())
	_apply_settings()


func _apply_settings() -> void:
	var on := bool(Settings.get_value("graphics/trees"))
	var r: float = TREE_RANGES[clampi(int(Settings.get_value("graphics/draw_distance")), 0, 2)]
	for f in _forests:
		f.visible = on
	for f in _forests_far:
		f.visible = on
		f.visibility_range_end = r
	var q: Dictionary = Settings.tree_level()
	_tree_near = float(q.near)
	for m in _tree_mats:
		(m as ShaderMaterial).set_shader_parameter("near_radius", _tree_near)
		(m as ShaderMaterial).set_shader_parameter("min_pixels", float(q.px))
		(m as ShaderMaterial).set_shader_parameter("density", float(Settings.FOREST_DENSITY[clampi(int(Settings.get_value("graphics/forest_density")), 0, 3)]))
	_near_center = Vector2(INF, INF)


func _process(_delta: float) -> void:
	_process_trees_wind()
	# keep the ocean centred under the camera; the shader works in world space, so it never swims
	var cam := get_viewport().get_camera_3d()
	if cam and _ocean:
		_ocean.global_position = Vector3(snappedf(cam.global_position.x, 100.0), WorldData.sea_level, snappedf(cam.global_position.z, 100.0))


## Forest density (0..1) for the whole map, from the real terrain: dense woods on hillsides, groves and lone trees
## in the lowlands, thinning to a treeline; none on steep rock, beaches or the airbase. The terrain shader paints
## forest floor from this same map, and the trees are placed from it, so they always agree.
func _make_forest_density() -> Image:
	var regions := FastNoiseLite.new()
	regions.seed = 4242
	regions.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	regions.frequency = 1.0 / 3200.0
	regions.fractal_octaves = 3
	var patches := FastNoiseLite.new()
	patches.seed = 977
	patches.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	patches.frequency = 1.0 / 650.0
	patches.fractal_octaves = 2
	var he := WorldData.half_extent
	var cell := 2.0 * he / DENSITY_RES
	var img := Image.create(DENSITY_RES, DENSITY_RES, false, Image.FORMAT_L8)
	for j in DENSITY_RES:
		for i in DENSITY_RES:
			var x := -he + (i + 0.5) * cell
			var z := -he + (j + 0.5) * cell
			var h := WorldData.terrain_height(x, z)
			var d := 0.0
			if h > 12.0 and h < 1180.0 and not AIRBASE_EXCLUSION.has_point(Vector2(x, z)):
				var alt := smoothstep(12.0, 60.0, h) * (1.0 - smoothstep(780.0, 1150.0, h))
				var nrm := WorldData.terrain_normal(x, z)
				var flat_ok := 1.0 - smoothstep(0.18, 0.32, 1.0 - nrm.y)   # thinning out on steep slopes
				var r := regions.get_noise_2d(x, z) * 0.5 + 0.5
				var pt := patches.get_noise_2d(x, z) * 0.5 + 0.5
				var forest := smoothstep(0.48, 0.66, r * 0.72 + pt * 0.28)
				var groves := smoothstep(0.62, 0.78, pt) * 0.35          # small groves outside the big forests
				d = clampf(maxf(forest, groves) * alt * flat_ok + 0.03 * alt * flat_ok, 0.0, 1.0)
			img.set_pixel(i, j, Color(d, d, d))
	return img


func _forest_value(x: float, z: float) -> float:
	var he := WorldData.half_extent
	var u := clampi(int((x + he) / (2.0 * he) * DENSITY_RES), 0, DENSITY_RES - 1)
	var v := clampi(int((z + he) / (2.0 * he) * DENSITY_RES), 0, DENSITY_RES - 1)
	return forest_mask.get_pixel(u, v).r


func _build_ocean() -> void:
	_ocean = MeshInstance3D.new()
	_ocean.name = "Ocean"
	var pm := PlaneMesh.new()
	pm.size = Vector2(900000.0, 900000.0)   # reaches the horizon even from 45,000 ft
	_ocean.mesh = pm
	_ocean.material_override = preload("res://scripts/world/surface_materials.gd").ocean()
	_ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ocean)


func _build_forests() -> void:
	var near_mat := ShaderMaterial.new()
	near_mat.shader = preload("res://shaders/tree.gdshader")
	near_mat.set_shader_parameter("far_set", false)
	near_mat.set_shader_parameter("near_radius", TREE_NEAR)
	var far_mat := near_mat.duplicate() as ShaderMaterial
	far_mat.set_shader_parameter("far_set", true)
	_tree_mats = [near_mat, far_mat]
	var meshes := {
		"conifer": [_conifer_mesh(true), _conifer_mesh(false)],
		"broadleaf": [_broadleaf_mesh(true), _broadleaf_mesh(false)],
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var species_noise := FastNoiseLite.new()
	species_noise.seed = 31
	species_noise.frequency = 1.0 / 1500.0
	var he := WorldData.half_extent
	var cell := 2.0 * he / DENSITY_RES
	const CHUNKS := 8
	var chunk := 2.0 * he / CHUNKS
	var buckets := {}       # far batches: "cx_cz_species" -> [[Transform3D, Color], ...]
	var total := 0
	for sp in ["conifer", "broadleaf"]:
		_trees[sp] = []
		_tree_grid[sp] = {}
	for j in DENSITY_RES:
		for i in DENSITY_RES:
			var d := forest_mask.get_pixel(i, j).r
			if d < 0.02:
				continue
			var count := int(5.6 * pow(d, 1.25) + rng.randf())
			for t in count:
				var x := -he + (i + rng.randf()) * cell
				var z := -he + (j + rng.randf()) * cell
				var h := WorldData.terrain_height(x, z)
				if h < 10.0:
					continue
				var conifer_p := clampf(smoothstep(220.0, 620.0, h) + species_noise.get_noise_2d(x, z) * 0.45, 0.0, 1.0)
				var sp := "conifer" if rng.randf() < conifer_p else "broadleaf"
				var s := rng.randf_range(0.95, 1.6) * (1.0 + 0.3 * d)
				var lean := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.06))
				var basis := (lean * Basis(Vector3.UP, rng.randf() * TAU)).scaled(Vector3(s, s * rng.randf_range(0.88, 1.18), s))
				var tint := Color.from_hsv(rng.randf_range(-0.03, 0.04), rng.randf_range(0.0, 0.22), rng.randf_range(0.82, 1.12))
				if sp == "broadleaf" and rng.randf() < 0.08:
					tint = Color(1.25, 1.05, 0.55)    # a few yellowing broadleaves
				var xf := Transform3D(basis, Vector3(x, h - 0.4, z))
				var key := "%d_%d_%s" % [clampi(int((x + he) / chunk), 0, CHUNKS - 1), clampi(int((z + he) / chunk), 0, CHUNKS - 1), sp]
				if not buckets.has(key):
					buckets[key] = []
				buckets[key].append([xf, tint])
				# spatial grid for the near pool
				var list: Array = _trees[sp]
				var gk := Vector2i(int(floor(x / GRID)), int(floor(z / GRID)))
				var g: Dictionary = _tree_grid[sp]
				if not g.has(gk):
					g[gk] = PackedInt32Array()
				var arr: PackedInt32Array = g[gk]
				arr.append(list.size())
				g[gk] = arr
				list.append([xf, tint])
				total += 1
	# far: static batches of simple trees (each hides itself inside the near radius)
	for key in buckets:
		var sp: String = String(key).get_slice("_", 2)
		var list: Array = buckets[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[sp][1]
		mm.instance_count = list.size()
		for k in list.size():
			mm.set_instance_transform(k, list[k][0])
			mm.set_instance_color(k, list[k][1])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "TreesFar_%s" % key
		mmi.multimesh = mm
		mmi.material_override = far_mat
		mmi.visibility_range_end = TREE_VISIBLE_RANGE
		mmi.visibility_range_end_margin = 900.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_forests_far.append(mmi)
	# near: one detailed, shadow-casting pool per species, refilled around the camera
	for sp in ["conifer", "broadleaf"]:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[sp][0]
		mm.instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "TreesNear_%s" % sp
		mmi.multimesh = mm
		mmi.material_override = near_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mmi.extra_cull_margin = 2000.0
		add_child(mmi)
		_forests.append(mmi)
		_near_pool[sp] = mmi
	print("World: %d trees" % total)


## Refills the detailed near-tree pools from the spatial grid when the camera has moved far enough.
func _update_near_trees(force: bool = false) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _near_pool.is_empty():
		return
	var cp := cam.global_position
	if not force and Vector2(cp.x, cp.z).distance_to(_near_center) < 150.0:
		return
	_near_center = Vector2(cp.x, cp.z)
	var r := _tree_near + 250.0
	var g0 := Vector2i(int(floor((cp.x - r) / GRID)), int(floor((cp.z - r) / GRID)))
	var g1 := Vector2i(int(floor((cp.x + r) / GRID)), int(floor((cp.z + r) / GRID)))
	for sp in _near_pool:
		var list: Array = _trees[sp]
		var grid: Dictionary = _tree_grid[sp]
		var picked := PackedInt32Array()
		for gx in range(g0.x, g1.x + 1):
			for gz in range(g0.y, g1.y + 1):
				var arr = grid.get(Vector2i(gx, gz))
				if arr != null:
					picked.append_array(arr)
		var mm: MultiMesh = (_near_pool[sp] as MultiMeshInstance3D).multimesh
		mm.instance_count = picked.size()
		for k in picked.size():
			var e: Array = list[picked[k]]
			mm.set_instance_transform(k, e[0])
			mm.set_instance_color(k, e[1])


func _process_trees_wind() -> void:
	for m in _tree_mats:
		(m as ShaderMaterial).set_shader_parameter("wind", clampf(WorldData.atmosphere.wind_speed / 10.0, 0.15, 1.2))
	_update_near_trees()


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


## Textured surfaces from the map (the runway and its markings) use anisotropic filtering, so lines stay sharp when
## seen at the shallow angles typical of a runway; plain mipmapping blurs them within a few hundred metres.
func _sharpen_textures(root_node: Node) -> void:
	for n in root_node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s) as BaseMaterial3D
			if m and m.albedo_texture:
				m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


## The runway markings are drawn procedurally (see runway.gdshader): sharp at every distance, unlike a texture.
func _procedural_runway(root_node: Node, tex: Dictionary) -> void:
	for n in root_node.find_children("Runway", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var aabb := mi.get_aabb()
		var m := ShaderMaterial.new()
		m.shader = preload("res://shaders/runway.gdshader")
		m.set_shader_parameter("detail_tex", tex.detail)
		m.set_shader_parameter("width_m", aabb.size.x)
		m.set_shader_parameter("length_m", aabb.size.z)
		mi.material_override = m
