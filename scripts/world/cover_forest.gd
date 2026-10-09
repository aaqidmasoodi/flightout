extends Node3D
## Trees of a large map, planted from its land cover (ESA WorldCover, tools/build_landcover.py) around the camera:
## forests where the cover says tree cover, scattered trees in shrubland and wetland, rows of poplars and chinars
## among the fields and villages. Conifers (deodar, pine, fir) on the mountainsides, broadleaves and poplars on the
## valley floors, nothing above the treeline or on runways.
##
## The map is cut into cells; cells within the tree range are planted (a few per frame, nearest first) as one
## simple-tree batch per species, and dropped again behind you. Close to the camera a detailed, shadow-casting pool
## takes over, exactly like the island's forests (shaders/tree.gdshader fades between the two).
## A child of the World node: it works in map coordinates and moves with the floating origin.

const CELL := 512.0
const STEP := 32.0                    # one land cover sample
const TREELINE := 3700.0
const NEAR_MAX := 650.0                # detailed, shadow-casting trees inside this distance at most
const BUDGET_USEC := 3500             # planting time per frame
const RANGES := [3200.0, 4500.0, 6000.0]
const CORE := 0.35                    # share of trees drawn out to the full range; the rest only out to FILL_RANGE
const FILL_RANGE := 0.5               # of the range (farther out the canopy colour of the terrain fills in)
# trees per sample (32 x 32 m) by land cover class
const DENSITY := {10: 2.1, 20: 0.3, 30: 0.03, 40: 0.09, 50: 0.25, 90: 0.35}

var world: Node3D                     # scripts/world/world.gd (tree meshes and materials)
var _meshes := {}                     # species -> [detailed mesh, simple mesh]
var _near_mat: ShaderMaterial
var _far_mat: ShaderMaterial
var _cells := {}                      # Vector2i -> {"nodes": [MultiMeshInstance3D], "trees": {species: [[Transform3D, Color]]}}
var _queue: Array[Vector2i] = []
var _range := 5000.0
var _near_radius := 1100.0
var _near_pool := {}
var _near_center := Vector2(INF, INF)
var _near_dirty := false
var _last_cam := Vector2(INF, INF)
var _runways: Array = []              # [centre, along (unit), half length, half width] in map coordinates
var _on := true
var planted := 0                      # trees in the planted cells (development: --terrain-stats)


func setup(w: Node3D) -> void:
	world = w
	_near_mat = w._tree_mats[0]
	_far_mat = w._tree_mats[1]
	_meshes = {
		"conifer": [w._conifer_mesh(true), w._conifer_mesh(false)],
		"broadleaf": [w._broadleaf_mesh(true), w._broadleaf_mesh(false)],
	}
	for a in WorldData.airfields:
		for r in a.runways:
			var A := Vector2(r.a[0], r.a[2])
			var B := Vector2(r.b[0], r.b[2])
			_runways.append([(A + B) * 0.5, (B - A).normalized(), A.distance_to(B) * 0.5 + 400.0, float(r.width) * 0.5 + 140.0])
	for sp in _meshes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _meshes[sp][0]
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "CoverTreesNear_%s" % sp
		mmi.multimesh = mm
		mmi.material_override = _near_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mmi.extra_cull_margin = 2000.0
		add_child(mmi)
		_near_pool[sp] = mmi


func _ready() -> void:
	# after the World node's own settings pass (it sets the shared tree materials for the island's forests)
	Settings.changed.connect(func(_k, _v): _apply_settings(), CONNECT_DEFERRED)
	_apply_settings()


func _apply_settings() -> void:
	_on = bool(Settings.get_value("graphics/trees"))
	visible = _on
	_range = RANGES[clampi(int(Settings.get_value("graphics/draw_distance")), 0, 2)]
	# the detailed trees cast shadows into every shadow cascade: in forests this dense, keep them close
	_near_radius = minf(float(Settings.tree_level().near), NEAR_MAX)
	for m in [_near_mat, _far_mat]:
		m.set_shader_parameter("near_radius", _near_radius)
	for c in _cells:
		for n in _cells[c].nodes:
			(n as GeometryInstance3D).visibility_range_end = _range * (1.0 if n.has_meta("core") else FILL_RANGE)
	_last_cam = Vector2(INF, INF)
	_near_center = Vector2(INF, INF)


func _process(_delta: float) -> void:
	if not _on:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cp3 := to_local(cam.global_position)      # map coordinates
	var cp := Vector2(cp3.x, cp3.z)
	# trees are not worth planting for a camera far above them (they would be under a pixel)
	var agl := cp3.y - WorldData.terrain_height(cp.x, cp.y)
	var reach := _range if agl < 6000.0 else 0.0
	if cp.distance_to(_last_cam) > 120.0:
		_last_cam = cp
		_refresh(cp, reach)
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty() and Time.get_ticks_usec() - t0 < BUDGET_USEC:
		var c: Vector2i = _queue.pop_front()
		if not _cells.has(c) and _cell_dist(c, cp) < reach + CELL:
			_plant(c)
			_near_dirty = true
	if _near_dirty or cp.distance_to(_near_center) > 150.0:
		_update_near(cp)


func _cell_dist(c: Vector2i, p: Vector2) -> float:
	var lo := Vector2(c) * CELL
	var q := p.clamp(lo, lo + Vector2(CELL, CELL))
	return q.distance_to(p)


## Drops cells out of range, queues the missing ones nearest first.
func _refresh(cp: Vector2, reach: float) -> void:
	for c in _cells.keys():
		if _cell_dist(c, cp) > reach + CELL * 1.5:
			for n in _cells[c].nodes:
				planted -= (n as MultiMeshInstance3D).multimesh.instance_count
				(n as Node).queue_free()
			_cells.erase(c)
			_near_dirty = true
	_queue.clear()
	if reach <= 0.0:
		return
	var n := int(ceil(reach / CELL)) + 1
	var cc := Vector2i(int(floor(cp.x / CELL)), int(floor(cp.y / CELL)))
	var want: Array = []
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var c := cc + Vector2i(i, j)
			if _cells.has(c):
				continue
			var d := _cell_dist(c, cp)
			if d < reach:
				want.append([d, c])
	want.sort_custom(func(a, b): return a[0] < b[0])
	for w in want:
		_queue.append(w[1])


func _on_runway(p: Vector2) -> bool:
	for r in _runways:
		var d: Vector2 = p - r[0]
		var u: Vector2 = r[1]
		if absf(d.dot(u)) < r[2] and absf(d.x * u.y - d.y * u.x) < r[3]:
			return true
	return false


func _plant(c: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(c) ^ 0x5eed
	var o := Vector2(c) * CELL
	var trees := {"conifer": [], "broadleaf": []}
	var near_runway := false
	for r in _runways:
		if (r[0] as Vector2).distance_to(o + Vector2(CELL, CELL) * 0.5) < float(r[2]) + CELL:
			near_runway = true
	var n := int(CELL / STEP)
	for j in n:
		for i in n:
			var sx := o.x + (i + 0.5) * STEP
			var sz := o.y + (j + 0.5) * STEP
			var cls := WorldData.land_cover(sx, sz)
			var dens: float = DENSITY.get(cls, 0.0)          # (the tree shader thins them for lower settings)
			if dens <= 0.0:
				continue
			var count := int(dens + rng.randf())
			for t in count:
				var x := sx + rng.randf_range(-0.5, 0.5) * STEP
				var z := sz + rng.randf_range(-0.5, 0.5) * STEP
				if near_runway and _on_runway(Vector2(x, z)):
					continue
				var h := WorldData.terrain_height(x, z)
				if h > TREELINE + rng.randf_range(-250.0, 150.0):
					continue
				_add_tree(trees, rng, cls, Vector3(x, h, z), o)
	var nodes: Array = []
	for key in ["conifer:core", "conifer:fill", "broadleaf:core", "broadleaf:fill"]:
		var sp: String = String(key).get_slice(":", 0)
		var core: bool = String(key).ends_with("core")
		var list: Array = []
		for k in (trees[sp] as Array).size():
			# every tree's share is fixed by its place in the cell, so a cell always plants the same forest
			if (fposmod(float(k) * 0.618034, 1.0) < CORE) == core:
				list.append(trees[sp][k])
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _meshes[sp][1]
		mm.instance_count = list.size()
		for k in list.size():
			var e: Array = list[k]
			var xf: Transform3D = e[0]
			xf.origin -= Vector3(o.x, 0.0, o.y)          # relative to the cell: small numbers
			mm.set_instance_transform(k, xf)
			mm.set_instance_color(k, e[1])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = Vector3(o.x, 0.0, o.y)
		mmi.material_override = _far_mat
		mmi.visibility_range_end = _range if core else _range * FILL_RANGE
		mmi.visibility_range_end_margin = 600.0 if core else 400.0
		if core:
			mmi.set_meta("core", true)
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		nodes.append(mmi)
		planted += list.size()
	_cells[c] = {"nodes": nodes, "trees": trees}


func _add_tree(trees: Dictionary, rng: RandomNumberGenerator, cls: int, p: Vector3, _o: Vector2) -> void:
	var h := p.y
	# conifers up the mountainsides, broadleaves (chinar, walnut, willow) and poplars on the valley floors
	var conifer_p := clampf(smoothstep(1750.0, 2300.0, h), 0.0, 1.0)
	if cls == 10:
		conifer_p = maxf(conifer_p, 0.25)
	elif cls == 40 or cls == 50:
		conifer_p *= 0.3
	var conifer := rng.randf() < conifer_p
	var sp := "conifer" if conifer else "broadleaf"
	var s := rng.randf_range(0.95, 1.55)
	var sy := s * rng.randf_range(0.88, 1.18)
	var sxz := s
	if conifer:
		s *= 1.0 + 0.25 * smoothstep(2000.0, 2800.0, h)                  # tall deodar and fir forests
		sy = s * rng.randf_range(0.95, 1.25)
		sxz = s
	elif (cls == 40 or cls == 50 or cls == 90) and rng.randf() < 0.6:
		# Lombardy poplars along the fields, canals and villages: tall and slender
		sxz = s * rng.randf_range(0.36, 0.46)
		sy = s * rng.randf_range(1.45, 1.8)
	var lean := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.05))
	var basis := (lean * Basis(Vector3.UP, rng.randf() * TAU)).scaled(Vector3(sxz, sy, sxz))
	var tint := Color.from_hsv(rng.randf_range(-0.03, 0.04), rng.randf_range(0.0, 0.22), rng.randf_range(0.78, 1.08))
	if conifer:
		tint = tint * Color(0.85, 0.92, 0.9)                              # darker, bluer needles
	elif rng.randf() < 0.06:
		tint = Color(1.25, 0.95, 0.5)                                     # a chinar turning
	(trees[sp] as Array).append([Transform3D(basis, Vector3(p.x, h - 0.4, p.z)), tint])


## Refills the detailed near pools from the planted cells around the camera.
func _update_near(cp: Vector2) -> void:
	_near_dirty = false
	_near_center = cp
	var r := _near_radius + 250.0
	var r2 := r * r
	for sp in _near_pool:
		var picked: Array = []
		for c in _cells:
			if _cell_dist(c, cp) > r:
				continue
			for e in _cells[c].trees[sp]:
				var o: Vector3 = (e[0] as Transform3D).origin
				if Vector2(o.x - cp.x, o.z - cp.y).length_squared() < r2:
					picked.append(e)
		var mm: MultiMesh = (_near_pool[sp] as MultiMeshInstance3D).multimesh
		mm.instance_count = picked.size()
		for k in picked.size():
			mm.set_instance_transform(k, picked[k][0])
			mm.set_instance_color(k, picked[k][1])
