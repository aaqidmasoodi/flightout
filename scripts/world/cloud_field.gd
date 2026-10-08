extends Node3D
## 3D cloud field: cumulus built from clusters of camera-facing puffs, in layers at different heights for
## parallax and depth. One MultiMesh draw call. The layout is seeded (same for every client); coverage
## reveals clusters in a fixed order, so weather changes add or remove whole clouds smoothly.

const PUFF_SHADER := preload("res://shaders/cloud_puff.gdshader")
const DECK_SHADER := preload("res://shaders/cloud_deck.gdshader")
const AREA := 36000.0
# layer: base altitude, vertical spread, clusters, puffs per cluster, cluster radius, flatness, puff size
const LAYERS := [
	{"alt": 1450.0, "spread": 380.0, "clusters": 420, "puffs": Vector2i(14, 28), "radius": Vector2(220.0, 620.0), "flat": 0.5, "size": Vector2(240.0, 470.0)},
	{"alt": 3600.0, "spread": 200.0, "clusters": 190, "puffs": Vector2i(10, 18), "radius": Vector2(420.0, 1100.0), "flat": 0.2, "size": Vector2(320.0, 600.0)},
]

var puff_mat: ShaderMaterial
var deck_mat: ShaderMaterial
var clusters: Array = []        # [centre, radius, threshold] for fly-through whiteout
var _deck: MeshInstance3D


func _ready() -> void:
	const SM = preload("res://scripts/world/surface_materials.gd")
	puff_mat = ShaderMaterial.new()
	puff_mat.shader = PUFF_SHADER
	puff_mat.set_shader_parameter("puff_atlas", SM.puff_atlas())
	puff_mat.set_shader_parameter("area_min", Vector2(-AREA, -AREA))
	puff_mat.set_shader_parameter("area_size", Vector2(2.0 * AREA, 2.0 * AREA))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7171
	var puffs := []   # [pos, size, custom]
	for layer in LAYERS:
		for c in int(layer.clusters):
			var centre := Vector3(rng.randf_range(-AREA, AREA), float(layer.alt) + rng.randf_range(0.0, float(layer.spread)), rng.randf_range(-AREA, AREA))
			var radius := rng.randf_range(layer.radius.x, layer.radius.y)
			var threshold := rng.randf()
			clusters.append([centre, radius, threshold])
			var n := rng.randi_range(layer.puffs.x, layer.puffs.y)
			for i in n:
				# puffs fill a squashed dome: wider at the base, rounded on top
				var a := rng.randf() * TAU
				var r := sqrt(rng.randf()) * radius
				# flat base, rounded cauliflower top
				var hy := pow(rng.randf(), 0.7) * radius * float(layer.flat) * (1.0 - 0.7 * (r / radius) * (r / radius))
				var pos := centre + Vector3(cos(a) * r, hy, sin(a) * r)
				var size := rng.randf_range(layer.size.x, layer.size.y) * (1.0 - 0.35 * r / radius)
				var height_f := clampf(hy / maxf(radius * float(layer.flat), 1.0), 0.0, 1.0)
				puffs.append([pos, size, Color(height_f, rng.randf(), rng.randf(), threshold)])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	mm.mesh = q
	mm.instance_count = puffs.size()
	for i in puffs.size():
		var p: Array = puffs[i]
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * float(p[1])), p[0]))
		mm.set_instance_custom_data(i, p[2])
	mm.custom_aabb = AABB(Vector3(-AREA * 2.0, 0.0, -AREA * 2.0), Vector3(AREA * 4.0, 6000.0, AREA * 4.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = puff_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 16384.0
	add_child(mmi)
	# stratus deck (overcast / rain)
	deck_mat = ShaderMaterial.new()
	deck_mat.shader = DECK_SHADER
	deck_mat.set_shader_parameter("noise_tex", SM.sky_clouds())
	_deck = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120000.0, 120000.0)
	_deck.mesh = pm
	_deck.material_override = deck_mat
	_deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_deck.position.y = 1900.0
	add_child(_deck)
	print("Clouds: %d puffs in %d clusters" % [puffs.size(), clusters.size()])


## How deep the camera is inside a visible cloud (0 outside .. 1 in the core).
func inside_amount(cam_pos: Vector3, coverage: float, drift: Vector2) -> float:
	var best := 0.0
	for c in clusters:
		if float(c[2]) > coverage:
			continue
		var centre: Vector3 = c[0]
		var cx := -AREA + fposmod(centre.x + drift.x + AREA, 2.0 * AREA)
		var cz := -AREA + fposmod(centre.z + drift.y + AREA, 2.0 * AREA)
		var r: float = c[1]
		var d := Vector3((cam_pos.x - cx) / r, (cam_pos.y - centre.y - r * 0.15) / (r * 0.45), (cam_pos.z - cz) / r).length()
		best = maxf(best, 1.0 - d)
	return clampf(best * 1.6, 0.0, 1.0)
