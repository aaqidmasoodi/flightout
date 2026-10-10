extends Node3D
## Streamed terrain (CDLOD: continuous distance-dependent level of detail).
##
## The map is a quadtree of square tiles built offline by tools/build_kashmir.py: level 0 is the finest, each level
## up halves the resolution and doubles the tile size. Every frame the quadtree is walked from the root: a tile is
## split into its four children while the camera is within RANGE_K tile sizes of it, so detail is dense under the jet
## and coarse at the horizon, and the triangle count is the same whatever the size of the map.
##
## All tiles are drawn with ONE small grid mesh (PATCH x PATCH quads) through a MultiMesh: each instance is scaled
## to its tile and reads its heights from a layer of a texture array in the vertex shader
## (shaders/terrain_cdlod.gdshader). Near the edge of its range a tile's vertices slide onto the grid of the next
## level up (morphing), so neighbouring tiles of different levels always meet without cracks and nothing pops.
##
## Heights stream from disk on worker threads: every tile the quadtree wants around the camera is kept resident,
## whichever way you look (only drawing is limited to the view), so turning your head never has to wait for data.
## Tiles live in a fixed pool of texture layers (least recently used ones are recycled). Until a child is loaded its
## parent keeps drawing, so there are never holes.
##
## Floating origin: this node is NOT under the World node; instances are placed in scene coordinates
## (map minus WorldData origin) every frame, so nearby terrain always has full float precision.

const SHADER := preload("res://shaders/terrain_cdlod.gdshader")
const RANGE_K := 2.6               # split a tile while the camera is closer than this many tile sizes
const MORPH_START := 0.7           # fraction of the next level's range where morphing begins
const POOL_SIZE := 2048            # texture layers resident (67 x 67 samples: ~27 MB with land cover)
var POOL := POOL_SIZE              # (development: --terrain-pool=N to test a full pool quickly)
const LOADS_PER_FRAME := 24        # finished tiles uploaded per frame
const MAX_IN_FLIGHT := 48          # tiles being read on worker threads at once

var dir := ""
var meta := {}
var tile_quads := 64
var ts := 67
var levels := 1
var spacing := 40.0
var x0 := 0.0
var z0 := 0.0
var h_scale := 0.25
var h_offset := -500.0
var tiles: Array[Vector2i] = []    # per level: (nx, nz)
var material: ShaderMaterial

var _index: Array = []             # per level PackedByteArray of uint64 tile offsets (compressed format)
var _zstd := false
var _lc_index: Array = []
var _lc_tex: Texture2DArray
var _minmax: Array = []            # per level PackedByteArray (u16 min, max per tile)
var _tex: Texture2DArray
var _layer_of := {}                # tile key -> layer
var _key_of: PackedInt64Array      # layer -> tile key (-1 free)
var _used: PackedInt64Array        # layer -> frame last drawn
var _wanted := {}                  # tile key -> priority (smaller is more urgent)
var _frame := 0
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _draw: Array = []              # [level, i, j] selected this frame
var _cam_map := Vector3.ZERO
var _planes: Array = []
var stats := {"drawn": 0, "resident": 0, "loads": 0, "evict": 0, "evict_split": 0, "proc_us": 0, "needed": 0}
var _log_stats := "--terrain-stats" in OS.get_cmdline_user_args()
var _pending := {}                 # key -> true while a worker reads it
var _done: Array = []              # [key, heights, cover] read by workers, waiting for upload
var _mutex := Mutex.new()
var _tasks: Array[int] = []           # worker tasks started and not yet collected (each must be waited on once)
var _view_far := -1.0
var _shadow_bake: RefCounted          # the mountains' shadows for the whole map (scripts/world/terrain_shadow_bake.gd)
var _curve := 0.0                  # earth_curve shader global (large maps), for culling
var _overview_tex: Texture2D       # kept alive while in use (cast shadows)
var _reached := 0                  # resident tiles the quadtree needs this frame


static func available(path: String) -> bool:
	return FileAccess.file_exists(path.path_join("terrain.json"))


func setup(path: String) -> bool:
	dir = path
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain-pool="):
			POOL = maxi(64, arg.trim_prefix("--terrain-pool=").to_int())
	var m = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("terrain.json")))
	if typeof(m) != TYPE_DICTIONARY:
		push_error("Terrain: no layout in " + dir)
		return false
	meta = m
	tile_quads = int(m.tile_quads)
	ts = int(m.tile_samples)
	levels = int(m.levels)
	spacing = float(m.spacing)
	x0 = float(m.x0)
	z0 = float(m.z0)
	h_scale = float(m.h_scale)
	h_offset = float(m.h_offset)
	for lv in levels:
		var t: Array = m.tiles[lv]
		tiles.append(Vector2i(int(t[0]), int(t[1])))
		_minmax.append(FileAccess.get_file_as_bytes(dir.path_join("mm%d.bin" % lv)))
		_index.append(FileAccess.get_file_as_bytes(dir.path_join("i%d.bin" % lv)) if m.get("compression", "") == "zstd" else PackedByteArray())
	_zstd = m.get("compression", "") == "zstd"
	if FileAccess.file_exists(dir.path_join("lc0.bin")):
		for lv in levels:
			_lc_index.append(FileAccess.get_file_as_bytes(dir.path_join("lci%d.bin" % lv)))
	# texture pool
	var blank := Image.create(ts, ts, false, Image.FORMAT_R16)
	var imgs: Array[Image] = []
	for i in POOL:
		imgs.append(blank)
	_tex = Texture2DArray.new()
	_tex.create_from_images(imgs)
	if not _lc_index.is_empty():
		var blank_lc := Image.create(ts, ts, false, Image.FORMAT_R8)
		var lcs: Array[Image] = []
		for i in POOL:
			lcs.append(blank_lc)
		_lc_tex = Texture2DArray.new()
		_lc_tex.create_from_images(lcs)
	_key_of.resize(POOL)
	_key_of.fill(-1)
	_used.resize(POOL)
	_used.fill(-1)
	# one patch mesh for every tile
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("heights", _tex)
	if _lc_tex:
		material.set_shader_parameter("cover", _lc_tex)
	material.set_shader_parameter("tile_quads", float(tile_quads))
	material.set_shader_parameter("tile_samples", float(ts))
	material.set_shader_parameter("h_scale", h_scale * 65535.0)
	material.set_shader_parameter("h_offset", h_offset)
	material.set_shader_parameter("debug_lod", "--terrain-lod" in OS.get_cmdline_user_args())
	material.set_shader_parameter("lite", int(Settings.get_value("graphics/terrain_detail")) == 0)
	Settings.changed.connect(func(k, v):
		if k == "graphics/terrain_detail" and material:
			material.set_shader_parameter("lite", int(v) == 0))
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _patch_mesh(tile_quads)
	_mmi = MultiMeshInstance3D.new()
	_mmi.name = "TerrainTiles"
	_mmi.multimesh = _mm
	_mmi.material_override = material
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mmi.custom_aabb = AABB(Vector3(-1e7, -1e4, -1e7), Vector3(2e7, 3e4, 2e7))   # culled per tile here instead
	_mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_mmi)
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# the coarsest level is always resident: there is always something to draw
	var top := levels - 1
	for j in tiles[top].y:
		for i in tiles[top].x:
			var k := _key(top, i, j)
			_apply(k, _read(k))
	process_priority = 200            # after the camera has moved this frame: culling uses this frame's view
	RenderingServer.global_shader_parameter_set("terrain_shadow", 0.0)
	if meta.has("overview") and FileAccess.file_exists(dir.path_join("overview.bin")):
		_tasks.append(WorkerThreadPool.add_task(_load_overview))
	return true


## The whole map's coarse heightmap (tools/build_overview.py) for the mountains' cast shadows: read on a worker
## thread at the start of the flight, then handed to every terrain shader at once (shader globals).
func _load_overview() -> void:
	var ov: Dictionary = meta.overview
	var w := int(ov.width)
	var h := int(ov.height)
	var f := FileAccess.open(dir.path_join("overview.bin"), FileAccess.READ)
	if f == null:
		return
	var data := f.get_buffer(f.get_length()).decompress(w * h * 2, FileAccess.COMPRESSION_ZSTD)
	if data.size() != w * h * 2:
		push_error("Terrain: overview damaged")
		return
	var img := Image.create_from_data(w, h, false, Image.FORMAT_R16, data)
	_overview_ready.call_deferred(img, ov)


func _overview_ready(img: Image, ov: Dictionary) -> void:
	var tex := ImageTexture.create_from_image(img)
	var s := float(ov.spacing)
	# texel centres sit on the samples: the image spans half a sample beyond the first and last
	var x0 := float(ov.x0) - s * 0.5
	var z0 := float(ov.z0) - s * 0.5
	RenderingServer.global_shader_parameter_set("terrain_overview", tex)
	RenderingServer.global_shader_parameter_set("overview_rect", Vector4(x0, z0, 1.0 / (img.get_width() * s), 1.0 / (img.get_height() * s)))
	RenderingServer.global_shader_parameter_set("terrain_shadow", 0.0 if "--no-terrain-shadow" in OS.get_cmdline_user_args() else 1.0)
	_overview_tex = tex
	# the cloud layers are measured from the ground of the region (scripts/world/cloud_ground.gd)
	preload("res://scripts/world/cloud_ground.gd").build(img, float(ov.x0), float(ov.z0), s)
	_shadow_bake = preload("res://scripts/world/terrain_shadow_bake.gd").new()
	if not _shadow_bake.setup(tex, Vector4(x0, z0, 1.0 / (img.get_width() * s), 1.0 / (img.get_height() * s)), s):
		_shadow_bake = null
	print("TERRAIN overview %d x %d loaded (cast shadows)" % [img.get_width(), img.get_height()])


## Size of a tile of `level` in metres.
func tile_size(level: int) -> float:
	return tile_quads * spacing * float(1 << level)


static func _key(level: int, i: int, j: int) -> int:
	return (level << 48) | (j << 24) | i


func _height_range(level: int, i: int, j: int) -> Vector2:
	var mm: PackedByteArray = _minmax[level]
	var o := (j * tiles[level].x + i) * 4
	return Vector2(mm.decode_u16(o) * h_scale + h_offset, mm.decode_u16(o + 2) * h_scale + h_offset)


## Another view that needs the terrain this frame (the cockpit mirrors' picture, looking aft): tiles in it are drawn
## too, not only the ones in the main camera's view. Set by that view each frame it renders, before this runs.
static var _extra_planes: Array[Plane] = []
static var _extra_frame := -1
var _planes2: Array[Plane] = []


static func add_view(planes: Array[Plane]) -> void:
	_extra_planes = planes
	_extra_frame = Engine.get_process_frames()


func _process(_delta: float) -> void:
	if _shadow_bake:
		_shadow_bake.update()
	var cam := get_viewport().get_camera_3d()
	if cam == null or _mm == null:
		return
	var t0 := Time.get_ticks_usec()
	_frame += 1
	_cam_map = WorldData.to_world(cam.global_position)
	_planes = cam.get_frustum()
	_planes2 = _extra_planes if _extra_frame == Engine.get_process_frames() else ([] as Array[Plane])
	_curve = WorldData.EARTH_CURVE if WorldData.is_large() else 0.0
	if cam.far != _view_far:
		_view_far = cam.far
		material.set_shader_parameter("view_far", cam.far)      # the aerial perspective closes in on the far plane
	_draw.clear()
	_wanted.clear()
	_reached = 0
	var top := levels - 1
	for j in tiles[top].y:
		for i in tiles[top].x:
			_select(top, i, j, true)
	_stream()
	_build_instances()
	stats.proc_us = Time.get_ticks_usec() - t0
	stats.needed = _reached
	stats.wanted = _wanted.size()
	if _log_stats and _frame % 60 == 0:
		print("TERRAIN drawn %d needed %d wanted %d resident %d loads %d  cam %.0f %.0f %.0f" % [stats.drawn, stats.needed, stats.wanted, stats.resident, stats.loads, _cam_map.x, _cam_map.y, _cam_map.z])


## Distance from the camera (map coordinates) to a tile's box.
func _distance(level: int, i: int, j: int) -> float:
	var s := tile_size(level)
	var hr := _height_range(level, i, j)
	var ax := x0 + i * s
	var az := z0 + j * s
	var dx := maxf(maxf(ax - _cam_map.x, 0.0), _cam_map.x - (ax + s))
	var dz := maxf(maxf(az - _cam_map.z, 0.0), _cam_map.z - (az + s))
	var dy := maxf(maxf(hr.x - _cam_map.y, 0.0), _cam_map.y - hr.y)
	return sqrt(dx * dx + dy * dy + dz * dz)


func _visible(level: int, i: int, j: int) -> bool:
	var s := tile_size(level)
	var hr := _height_range(level, i, j)
	# a margin around the box: the view can turn a little between this test and the frame being drawn
	var m := s * 0.15 + 30.0
	# the curvature drop (terrain shader) lowers far tiles: extend the box down by the drop at its far corner
	var far_x := maxf(absf(x0 + i * s - _cam_map.x), absf(x0 + (i + 1) * s - _cam_map.x))
	var far_z := maxf(absf(z0 + j * s - _cam_map.z), absf(z0 + (j + 1) * s - _cam_map.z))
	var drop := (far_x * far_x + far_z * far_z) * _curve
	var mn := Vector3(x0 + i * s - WorldData.origin_x - m, hr.x - m - drop, z0 + j * s - WorldData.origin_z - m)
	var mx := Vector3(mn.x + s + 2.0 * m, hr.y + m, mn.z + s + 2.0 * m)
	return _box_in(_planes, mn, mx) or (not _planes2.is_empty() and _box_in(_planes2, mn, mx))


static func _box_in(planes: Array, mn: Vector3, mx: Vector3) -> bool:
	for p: Plane in planes:
		# the corner furthest against the plane normal: if even that is outside, the whole box is
		var c := Vector3(mn.x if p.normal.x > 0.0 else mx.x, mn.y if p.normal.y > 0.0 else mx.y, mn.z if p.normal.z > 0.0 else mx.z)
		if p.distance_to(c) > 0.0:
			return false
	return true


## Walks the quadtree. Every tile it reaches is kept resident; `vis` (in the view) decides drawing only.
## Every resident tile it passes through is marked in use, split ones too: a split tile is still needed (it draws
## again as soon as you move away, and its children are only kept while it is). Leaving split tiles unmarked let the
## pool recycle them first once it was full, and the whole patch under them dropped to a coarse ancestor for a few
## frames until they were read back in: the flicker after flying for a while.
func _select(level: int, i: int, j: int, vis: bool) -> void:
	if vis:
		vis = _visible(level, i, j)
	var key := _key(level, i, j)
	var layer: int = _layer_of.get(key, -1)
	if layer >= 0:
		_used[layer] = _frame
		_reached += 1
	var d := _distance(level, i, j)
	var prio := d if vis else d * 4.0 + 1e6          # what you can see loads first
	if level > 0 and d < RANGE_K * tile_size(level):
		# split: only once every child that exists is loaded (until then this tile keeps drawing)
		var ready := true
		var kids: Array = []
		for c in 4:
			var ci := i * 2 + (c & 1)
			var cj := j * 2 + (c >> 1)
			if ci >= tiles[level - 1].x or cj >= tiles[level - 1].y:
				continue
			kids.append(Vector2i(ci, cj))
			var k := _key(level - 1, ci, cj)
			var kl: int = _layer_of.get(k, -1)
			if kl < 0:
				ready = false
				_wanted[k] = prio
			else:
				_used[kl] = _frame          # keep the loaded siblings while the last ones arrive
		if ready and not kids.is_empty():
			for kc: Vector2i in kids:
				_select(level - 1, kc.x, kc.y, vis)
			return
	if layer >= 0:
		if vis:
			_draw.append([level, i, j, layer])
	else:
		_wanted[key] = prio


func _stream() -> void:
	_collect_tasks()
	# upload what the workers have finished
	_mutex.lock()
	var ready := _done.slice(0, LOADS_PER_FRAME)
	_done = _done.slice(LOADS_PER_FRAME)
	_mutex.unlock()
	if not ready.is_empty():
		_collect_free_layers()
	for r in ready:
		_pending.erase(r[0])
		if _apply(r[0], r):
			stats.loads += 1
	# start reading the most wanted tiles (only while the pool has room for them: tiles in use are never recycled)
	if _wanted.is_empty() or _reached + _pending.size() >= POOL or _pending.size() >= MAX_IN_FLIGHT:
		return
	var keys := _wanted.keys()
	keys.sort_custom(func(a, b): return _wanted[a] < _wanted[b])
	for k in keys:
		if _pending.size() >= MAX_IN_FLIGHT:
			break
		if _pending.has(k) or _layer_of.has(k):
			continue
		_pending[k] = true
		_tasks.append(WorkerThreadPool.add_task(_worker.bind(k)))


## Finished worker tasks are waited on (which returns at once) so the pool can release them.
func _collect_tasks() -> void:
	var i := 0
	while i < _tasks.size():
		if WorkerThreadPool.is_task_completed(_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_tasks[i])
			_tasks.remove_at(i)
		else:
			i += 1


## Leaving the flight: the workers still reading tiles call back into this node, so they must finish first.
func _exit_tree() -> void:
	if _shadow_bake:
		_shadow_bake.release()
		_shadow_bake = null
	for id in _tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()


func _worker(key: int) -> void:
	var r := _read(key)
	_mutex.lock()
	_done.append(r)
	_mutex.unlock()


## Reads and decompresses one tile (heights and land cover). Safe on any thread: opens its own file handles.
func _read(key: int) -> Array:
	var level := key >> 48
	var j := (key >> 24) & 0xFFFFFF
	var i := key & 0xFFFFFF
	var n := j * tiles[level].x + i
	var bytes := ts * ts * 2
	var data := PackedByteArray()
	var f := FileAccess.open(dir.path_join("h%d.bin" % level), FileAccess.READ)
	if f:
		if _zstd:
			var idx: PackedByteArray = _index[level]
			var a := idx.decode_u64(n * 8)
			var b := idx.decode_u64(n * 8 + 8)
			f.seek(a)
			data = f.get_buffer(b - a).decompress(bytes, FileAccess.COMPRESSION_ZSTD)
		else:
			f.seek(n * bytes)
			data = f.get_buffer(bytes)
	var lc := PackedByteArray()
	if not _lc_index.is_empty():
		var lf := FileAccess.open(dir.path_join("lc%d.bin" % level), FileAccess.READ)
		if lf:
			var li: PackedByteArray = _lc_index[level]
			var la := li.decode_u64(n * 8)
			var lb := li.decode_u64(n * 8 + 8)
			lf.seek(la)
			lc = lf.get_buffer(lb - la).decompress(ts * ts, FileAccess.COMPRESSION_ZSTD)
	return [key, data, lc]


## Puts a read tile into a texture layer (main thread).
func _apply(key: int, r: Array) -> bool:
	if _layer_of.has(key):
		return false
	var data: PackedByteArray = r[1]
	if data.size() != ts * ts * 2:
		push_error("Terrain: tile %d damaged" % key)
		return false
	var layer := _free_layer()
	if layer < 0:
		return false
	RenderingServer.texture_2d_update(_tex.get_rid(), Image.create_from_data(ts, ts, false, Image.FORMAT_R16, data), layer)
	var lc: PackedByteArray = r[2]
	if _lc_tex and lc.size() == ts * ts:
		RenderingServer.texture_2d_update(_lc_tex.get_rid(), Image.create_from_data(ts, ts, false, Image.FORMAT_R8, lc), layer)
	if _key_of[layer] >= 0:
		var old := _key_of[layer]
		stats.evict += 1
		if _has_resident_child(old):
			stats.evict_split += 1        # (development statistics) a tile whose children are in use
		_layer_of.erase(old)
	_key_of[layer] = key
	_layer_of[key] = layer
	_used[layer] = _frame
	return true


func _has_resident_child(key: int) -> bool:
	var level := key >> 48
	if level == 0:
		return false
	var j := (key >> 24) & 0xFFFFFF
	var i := key & 0xFFFFFF
	for c in 4:
		if _layer_of.has(_key(level - 1, i * 2 + (c & 1), j * 2 + (c >> 1))):
			return true
	return false


## Layers that may take a new tile this frame: free ones first, then the least recently used (never one in use
## this frame, never a top-level tile). One pass over the pool per frame instead of one per upload.
var _free: Array = []

func _collect_free_layers() -> void:
	var empty: Array = []
	var old: Array = []
	for l in POOL:
		var k := _key_of[l]
		if k < 0:
			empty.append(l)
		elif (k >> 48) != levels - 1 and _used[l] < _frame:
			old.append(Vector2i(_used[l], l))
	if empty.size() < LOADS_PER_FRAME and not old.is_empty():
		old.sort()                                     # least recently used first
		for v: Vector2i in old.slice(0, LOADS_PER_FRAME - empty.size()):
			empty.append(v.y)
	empty.reverse()
	_free = empty                                      # popped from the back: free layers, then the oldest


func _free_layer() -> int:
	if _free.is_empty():
		_collect_free_layers()
	return _free.pop_back() if not _free.is_empty() else -1


func _build_instances() -> void:
	_mm.instance_count = _draw.size()
	_mm.visible_instance_count = _draw.size()
	for n in _draw.size():
		var e: Array = _draw[n]
		var level: int = e[0]
		var s := tile_size(level)
		var pos := Vector3(x0 + e[1] * s - WorldData.origin_x, 0.0, z0 + e[2] * s - WorldData.origin_z)
		_mm.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3(s, 1.0, s)), pos))
		# morph from this level's grid onto the next level's over the outer part of this level's range
		var r_next := RANGE_K * tile_size(level + 1)
		var m0 := r_next * MORPH_START
		var m1 := r_next * 0.97
		if level == levels - 1:
			m0 = 1e12
			m1 = 2e12
		_mm.set_instance_custom_data(n, Color(float(e[3]), float(level), m0, m1))
	stats.drawn = _draw.size()
	stats.resident = _layer_of.size()


## Grid of q x q quads over [0,1] x [0,1] in XZ. Diagonals alternate so the triangulation has no bias.
static func _patch_mesh(q: int) -> ArrayMesh:
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	for z in q + 1:
		for x in q + 1:
			v.append(Vector3(float(x) / q, 0.0, float(z) / q))
	for z in q:
		for x in q:
			var a := z * (q + 1) + x
			var b := a + 1
			var c := a + q + 1
			var d := c + 1
			if (x + z) % 2 == 0:
				idx.append_array([a, b, d, a, d, c])
			else:
				idx.append_array([a, b, c, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh
