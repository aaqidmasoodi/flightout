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
const TREE_RANGES := [3500.0, 6500.0, 10000.0]


func _ready() -> void:
	var world: Node3D = load(WORLD_SCENE).instantiate()
	world.name = "Map"
	add_child(world)

	forest_mask = _make_forest_mask()
	var tmat := ShaderMaterial.new()
	tmat.shader = TERRAIN_SHADER
	tmat.set_shader_parameter("forest_mask", ImageTexture.create_from_image(forest_mask))
	tmat.set_shader_parameter("map_half_extent", WorldData.half_extent)
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
		f.visibility_range_end = r


func _process(_delta: float) -> void:
	# keep the ocean centred under the camera; the shader works in world space, so it never swims
	var cam := get_viewport().get_camera_3d()
	if cam and _ocean:
		_ocean.global_position = Vector3(snappedf(cam.global_position.x, 100.0), WorldData.sea_level, snappedf(cam.global_position.z, 100.0))


func _make_forest_mask() -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = 4242
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 4
	var img := noise.get_seamless_image(1024, 1024, false, false, 0.1, true)
	img.convert(Image.FORMAT_L8)
	return img


func _forest_value(x: float, z: float) -> float:
	var u := clampi(int((x + WorldData.half_extent) / (2.0 * WorldData.half_extent) * 1024.0), 0, 1023)
	var v := clampi(int((z + WorldData.half_extent) / (2.0 * WorldData.half_extent) * 1024.0), 0, 1023)
	return forest_mask.get_pixel(u, v).r


func _build_ocean() -> void:
	_ocean = MeshInstance3D.new()
	_ocean.name = "Ocean"
	var pm := PlaneMesh.new()
	pm.size = Vector2(140000.0, 140000.0)
	_ocean.mesh = pm
	_ocean.material_override = preload("res://scripts/world/surface_materials.gd").ocean()
	_ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ocean)


func _build_forests() -> void:
	var tree_mesh := _make_tree_mesh()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var chunk := 5120.0
	var per_chunk_tries := 2600
	var total := 0
	var he := WorldData.half_extent
	for cx in 8:
		for cz in 8:
			var x0 := -he + cx * chunk
			var z0 := -he + cz * chunk
			var xforms: Array[Transform3D] = []
			for i in per_chunk_tries:
				var x := x0 + rng.randf() * chunk
				var z := z0 + rng.randf() * chunk
				if AIRBASE_EXCLUSION.has_point(Vector2(x, z)):
					continue
				var h := WorldData.terrain_height(x, z)
				if h < 25.0 or h > 950.0:
					continue
				if _forest_value(x, z) < 0.55:
					continue
				var n := WorldData.terrain_normal(x, z)
				if n.y < 0.85:
					continue
				var s := rng.randf_range(0.8, 1.5)
				var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s))
				xforms.append(Transform3D(b, Vector3(x, h - 0.5, z)))
			if xforms.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = tree_mesh
			mm.instance_count = xforms.size()
			for i in xforms.size():
				mm.set_instance_transform(i, xforms[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Forest_%d_%d" % [cx, cz]
			mmi.multimesh = mm
			mmi.visibility_range_end = TREE_VISIBLE_RANGE
			mmi.visibility_range_end_margin = 800.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			_forests.append(mmi)
			total += xforms.size()
	print("World: %d trees" % total)


func _make_tree_mesh() -> Mesh:
	# conifer: two stacked cones + trunk, merged into one mesh with vertex colours
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_cone(st, 0.0, 2.0, 0.35, 0.3, Color(0.30, 0.22, 0.14))
	_cone(st, 1.8, 9.0, 3.2, 0.0, Color(0.10, 0.20, 0.08))
	_cone(st, 6.0, 13.0, 2.2, 0.0, Color(0.12, 0.24, 0.10))
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mesh.surface_set_material(0, mat)
	return mesh


func _cone(st: SurfaceTool, y0: float, y1: float, r0: float, r1: float, c: Color) -> void:
	var seg := 7
	for k in seg:
		var a0 := TAU * k / seg
		var a1 := TAU * (k + 1) / seg
		var p0 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
		var p1 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
		var q0 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
		var q1 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
		st.set_color(c)
		st.add_vertex(p0); st.add_vertex(q0); st.add_vertex(p1)
		st.add_vertex(p1); st.add_vertex(q0); st.add_vertex(q1)
