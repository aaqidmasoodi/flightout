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
const BUDGET_USEC := 2000             # time per frame for putting planted cells into the scene
const MAX_PLANTING := 2               # cells being planted on worker threads at once (leaves cores for the game)
const HIGH_DROP := 6500.0             # above this height over the ground the forest is dropped (trees under a pixel)...
const HIGH_BACK := 5500.0             # ...and planted again below this one (a band, so ridges below don't flip it)
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
var _shadow_pool := {}                 # species -> shadow-only copy of the detailed trees within the shadow distance
var _density := 1.0                   # share of trees planted (graphics/forest_density)
var _high := false                    # camera far above the ground: no forest
# planting runs on worker threads (_plant_data: land cover, terrain heights and tree placement, all pure); the main
# thread only puts the finished cells into the scene (_add_cell)
var _planting := {}                   # cell -> worker task id
var _planted_lock := Mutex.new()
var _planted_done: Array = []         # finished cells waiting to be added (under _planted_lock)
var _gen := 0                         # bumped when every cell is dropped: older results are thrown away
var _near_center := Vector2(INF, INF)
var _near_dirty := false
var _last_cam := Vector2(INF, INF)
var _runways: Array = []              # [centre, along (unit), half length, half width] in map coordinates
var _on := true
var stats := {"proc_us": 0, "near_us": 0, "near_n": 0, "plant_n": 0}
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
		# the detailed pool reaches several hundred metres; shadows are drawn only to the shadow distance, so only the
		# trees that close are drawn into the shadow maps, by a shadow-only copy (below)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.extra_cull_margin = 50.0
		add_child(mmi)
		_near_pool[sp] = mmi
		var smm := MultiMesh.new()
		smm.transform_format = MultiMesh.TRANSFORM_3D
		smm.use_colors = true
		smm.mesh = _meshes[sp][0]
		var smi := MultiMeshInstance3D.new()
		smi.name = "CoverTreesShadow_%s" % sp
		smi.multimesh = smm
		smi.material_override = _near_mat
		smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		smi.extra_cull_margin = 50.0
		add_child(smi)
		_shadow_pool[sp] = smi


func _ready() -> void:
	# after the World node's own settings pass (it sets the shared tree materials for the island's forests)
	Settings.changed.connect(func(k, _v):
		if k in ["graphics/trees", "graphics/draw_distance", "graphics/tree_detail", "graphics/forest_density",
				"graphics/shadows", "graphics/shadow_quality"]:
			_apply_settings(), CONNECT_DEFERRED)
	_apply_settings()


func _apply_settings() -> void:
	_on = bool(Settings.get_value("graphics/trees"))
	var dens: float = Settings.FOREST_DENSITY[clampi(int(Settings.get_value("graphics/forest_density")), 0, 3)]
	if dens != _density:
		_density = dens
		_clear_cells()             # replanted at the new density around the camera
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
	if _high and agl < HIGH_BACK:
		_high = false
		_last_cam = Vector2(INF, INF)
	elif not _high and agl > HIGH_DROP:
		_high = true
		_last_cam = Vector2(INF, INF)
	var reach := 0.0 if _high else _range
	var t0 := Time.get_ticks_usec()
	if cp.distance_to(_last_cam) > 120.0:
		_last_cam = cp
		_refresh(cp, reach)
	# finished cells into the scene (nearest were started first)
	_planted_lock.lock()
	var done := _planted_done
	_planted_done = []
	_planted_lock.unlock()
	for i in done.size():
		var r: Dictionary = done[i]
		var c: Vector2i = r.c
		if _planting.has(c):
			if int(_planting[c]) >= 0:
				WorkerThreadPool.wait_for_task_completion(_planting[c])     # finished: returns at once
			_planting.erase(c)
		if int(r.gen) != _gen or _cells.has(c) or _cell_dist(c, cp) > reach + CELL * 1.5:
			continue                       # dropped meanwhile (out of range, or the forest was replanted)
		if Time.get_ticks_usec() - t0 > BUDGET_USEC:
			# over this frame's budget: the rest waits for the next frame
			_planted_lock.lock()
			_planted_done = done.slice(i) + _planted_done
			_planted_lock.unlock()
			for k in range(i, done.size()):
				var cc: Vector2i = done[k].c
				if not _planting.has(cc):
					_planting[cc] = -1     # (still counted as busy until it is added)
			break
		_add_cell(r)
		stats.plant_n += 1
		if _cell_dist(c, cp) < _near_radius + 250.0:
			_near_dirty = true            # only a cell inside the detailed radius changes the near pool
	# start planting the most wanted cells
	while not _queue.is_empty() and _busy() < MAX_PLANTING:
		var c: Vector2i = _queue.pop_front()
		if not _cells.has(c) and not _planting.has(c) and _cell_dist(c, cp) < reach + CELL:
			_planting[c] = WorkerThreadPool.add_task(_plant_worker.bind(c, _density, _gen))
	stats.proc_us = Time.get_ticks_usec() - t0
	if _near_dirty or cp.distance_to(_near_center) > 150.0:
		var t1 := Time.get_ticks_usec()
		_update_near(cp)
		stats.near_us = Time.get_ticks_usec() - t1
		stats.near_n += 1
	else:
		stats.near_us = 0


func _cell_dist(c: Vector2i, p: Vector2) -> float:
	var lo := Vector2(c) * CELL
	var q := p.clamp(lo, lo + Vector2(CELL, CELL))
	return q.distance_to(p)


func _clear_cells() -> void:
	_gen += 1
	for c in _cells:
		for n in _cells[c].nodes:
			(n as Node).queue_free()
	_cells.clear()
	_queue.clear()
	planted = 0
	_last_cam = Vector2(INF, INF)
	_near_dirty = true


## Drops cells out of range, queues the missing ones nearest first.
func _refresh(cp: Vector2, reach: float) -> void:
	for c in _cells.keys():
		if _cell_dist(c, cp) > reach + CELL * 1.5:
			for n in _cells[c].nodes:
				planted -= (n as MultiMeshInstance3D).multimesh.instance_count
				(n as Node).queue_free()
			_cells.erase(c)
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


func _busy() -> int:
	var n := 0
	for c in _planting:
		if int(_planting[c]) >= 0:
			n += 1
	return n


func _plant_worker(c: Vector2i, density: float, gen: int) -> void:
	var r := _plant_data(c, density)
	r.gen = gen
	_planted_lock.lock()
	_planted_done.append(r)
	_planted_lock.unlock()


## Leaving the flight: planting workers call back into this node, so they finish first.
func _exit_tree() -> void:
	for c in _planting:
		if int(_planting[c]) >= 0:
			WorkerThreadPool.wait_for_task_completion(_planting[c])
	_planting.clear()


## One cell's trees (any thread): returns its instance buffers, ready to be put into the scene by _add_cell.
func _plant_data(c: Vector2i, density: float) -> Dictionary:
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
				# lower densities keep a fixed subset (by position), so thinning never reshuffles the forest
				if density < 1.0 and fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0) > density:
					continue
				if near_runway and _on_runway(Vector2(x, z)):
					continue
				var h := WorldData.terrain_height(x, z)
				if h > TREELINE + rng.randf_range(-250.0, 150.0):
					continue
				_add_tree(trees, rng, cls, Vector3(x, h, z), o)
	var near := {}
	for sp in trees:
		near[sp] = _buffer(trees[sp], Vector3.ZERO)        # map coordinates, for the detailed pool
	var sets: Array = []
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
		sets.append([sp, core, list.size(), _buffer(list, Vector3(o.x, 0.0, o.y))])     # relative to the cell: small numbers
	return {"c": c, "near": near, "sets": sets}


## Puts a planted cell into the scene (main thread): one MultiMesh per species and share.
func _add_cell(r: Dictionary) -> void:
	var c: Vector2i = r.c
	var o := Vector2(c) * CELL
	var nodes: Array = []
	for st in r.sets:
		var sp: String = st[0]
		var core: bool = st[1]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _meshes[sp][1]
		mm.instance_count = int(st[2])
		mm.buffer = st[3]
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
		planted += int(st[2])
	_cells[c] = {"nodes": nodes, "near": r.near}


## MultiMesh instance data (3x4 transform rows, then RGBA) for a list of [Transform3D, Color], shifted by -offset.
static func _buffer(list: Array, offset: Vector3) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(list.size() * 16)
	var n := 0
	for e in list:
		var t: Transform3D = e[0]
		var c: Color = e[1]
		var o := t.origin - offset
		b[n] = t.basis.x.x; b[n + 1] = t.basis.y.x; b[n + 2] = t.basis.z.x; b[n + 3] = o.x
		b[n + 4] = t.basis.x.y; b[n + 5] = t.basis.y.y; b[n + 6] = t.basis.z.y; b[n + 7] = o.y
		b[n + 8] = t.basis.x.z; b[n + 9] = t.basis.y.z; b[n + 10] = t.basis.z.z; b[n + 11] = o.z
		b[n + 12] = c.r; b[n + 13] = c.g; b[n + 14] = c.b; b[n + 15] = c.a
		n += 16
	return b


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


## Refills the detailed near pools from the planted cells around the camera: whole cells, copied as packed
## buffers (the tree shader itself hands each tree between the detailed and the simple set by its distance).
func _update_near(cp: Vector2) -> void:
	_near_dirty = false
	_near_center = cp
	var r := _near_radius + 250.0
	var sr := 0.0
	if bool(Settings.get_value("graphics/shadows")):
		sr = float(Settings.shadow_level().dist) + 60.0
	for sp in _near_pool:
		_fill(_near_pool[sp], sp, cp, r)
		_fill(_shadow_pool[sp], sp, cp, sr)


## One pool's instances: the detailed trees of the planted cells within `r` of the camera (packed buffers copied
## whole, in native code).
func _fill(mmi: MultiMeshInstance3D, sp: String, cp: Vector2, r: float) -> void:
	var buf := PackedFloat32Array()
	if r > 0.0:
		for c in _cells:
			if _cell_dist(c, cp) < r:
				buf.append_array(_cells[c].near[sp])
	var mm := mmi.multimesh
	mm.instance_count = buf.size() / 16
	if not buf.is_empty():
		mm.buffer = buf
