extends Node3D
## Streamed terrain (CDLOD: continuous distance-dependent level of detail).
##
## The map is a quadtree of square tiles built offline by tools/terrain_tiles.py: level 0 is the finest, each level
## up halves the resolution and doubles the tile size. Every frame the quadtree is walked from the root: a tile is
## split into its four children while the camera is within RANGE_K tile sizes of it, so detail is dense under the jet
## and coarse at the horizon, and the triangle count is the same whatever the size of the map.
##
## All tiles are drawn with ONE small grid mesh (PATCH x PATCH quads) through a MultiMesh: each instance is scaled
## to its tile and reads its heights from a layer of a texture array in the vertex shader
## (shaders/terrain_cdlod.gdshader). Near the edge of its range a tile's vertices slide onto the grid of the next
## level up (morphing), so neighbouring tiles of different levels always meet without cracks and nothing pops.
##
## Heights stream from disk: a tile is read only when it is about to be drawn, into a fixed pool of texture layers
## (least recently used ones are recycled). Until a child is loaded its parent keeps drawing, so there are no holes.
##
## Floating origin: this node is NOT under the World node; instances are placed in scene coordinates
## (map minus WorldData origin) every frame, so nearby terrain always has full float precision.

const SHADER := preload("res://shaders/terrain_cdlod.gdshader")
const RANGE_K := 2.6               # split a tile while the camera is closer than this many tile sizes
const MORPH_START := 0.7           # fraction of the next level's range where morphing begins
const POOL := 640                  # texture layers resident
const LOADS_PER_FRAME := 12

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

var _files: Array = []             # per level FileAccess
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
var stats := {"drawn": 0, "resident": 0, "loads": 0}
var _log_stats := "--terrain-stats" in OS.get_cmdline_user_args()


static func available(path: String) -> bool:
	return FileAccess.file_exists(path.path_join("terrain.json"))


func setup(path: String) -> bool:
	dir = path
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
		_files.append(FileAccess.open(dir.path_join("h%d.bin" % lv), FileAccess.READ))
		_minmax.append(FileAccess.get_file_as_bytes(dir.path_join("mm%d.bin" % lv)))
	# texture pool
	var blank := Image.create(ts, ts, false, Image.FORMAT_R16)
	var imgs: Array[Image] = []
	for i in POOL:
		imgs.append(blank)
	_tex = Texture2DArray.new()
	_tex.create_from_images(imgs)
	_key_of.resize(POOL)
	_key_of.fill(-1)
	_used.resize(POOL)
	_used.fill(-1)
	# one patch mesh for every tile
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("heights", _tex)
	material.set_shader_parameter("tile_quads", float(tile_quads))
	material.set_shader_parameter("tile_samples", float(ts))
	material.set_shader_parameter("h_scale", h_scale * 65535.0)
	material.set_shader_parameter("h_offset", h_offset)
	material.set_shader_parameter("debug_lod", "--terrain-lod" in OS.get_cmdline_user_args())
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
			_load(_key(top, i, j))
	return true


## Size of a tile of `level` in metres.
func tile_size(level: int) -> float:
	return tile_quads * spacing * float(1 << level)


static func _key(level: int, i: int, j: int) -> int:
	return (level << 48) | (j << 24) | i


func _height_range(level: int, i: int, j: int) -> Vector2:
	var mm: PackedByteArray = _minmax[level]
	var o := (j * tiles[level].x + i) * 4
	return Vector2(mm.decode_u16(o) * h_scale + h_offset, mm.decode_u16(o + 2) * h_scale + h_offset)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _mm == null:
		return
	_frame += 1
	_cam_map = WorldData.to_world(cam.global_position)
	_planes = cam.get_frustum()
	_draw.clear()
	_wanted.clear()
	var top := levels - 1
	for j in tiles[top].y:
		for i in tiles[top].x:
			_select(top, i, j)
	_stream()
	_build_instances()
	if _log_stats and _frame % 60 == 0:
		print("TERRAIN drawn %d resident %d loads %d  cam %.0f %.0f %.0f" % [stats.drawn, stats.resident, stats.loads, _cam_map.x, _cam_map.y, _cam_map.z])


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
	var mn := Vector3(x0 + i * s - WorldData.origin_x, hr.x - 30.0, z0 + j * s - WorldData.origin_z)
	var mx := Vector3(mn.x + s, hr.y + 30.0, mn.z + s)
	for p: Plane in _planes:
		# the corner furthest against the plane normal: if even that is outside, the whole box is
		var c := Vector3(mn.x if p.normal.x > 0.0 else mx.x, mn.y if p.normal.y > 0.0 else mx.y, mn.z if p.normal.z > 0.0 else mx.z)
		if p.distance_to(c) > 0.0:
			return false
	return true


func _select(level: int, i: int, j: int) -> void:
	if not _visible(level, i, j):
		return
	var d := _distance(level, i, j)
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
			if not _layer_of.has(k):
				ready = false
				_wanted[k] = d
		if ready and not kids.is_empty():
			for kc: Vector2i in kids:
				_select(level - 1, kc.x, kc.y)
			return
	var key := _key(level, i, j)
	if _layer_of.has(key):
		_draw.append([level, i, j, _layer_of[key]])
		_used[_layer_of[key]] = _frame
	else:
		_wanted[key] = d


func _stream() -> void:
	if _wanted.is_empty():
		return
	var keys := _wanted.keys()
	keys.sort_custom(func(a, b): return _wanted[a] < _wanted[b])
	var n := 0
	for k in keys:
		if n >= LOADS_PER_FRAME:
			break
		if _load(k):
			n += 1
	stats.loads += n


func _load(key: int) -> bool:
	if _layer_of.has(key):
		return false
	var level := key >> 48
	var j := (key >> 24) & 0xFFFFFF
	var i := key & 0xFFFFFF
	var layer := _free_layer()
	if layer < 0:
		return false
	var f: FileAccess = _files[level]
	var bytes := ts * ts * 2
	f.seek((j * tiles[level].x + i) * bytes)
	var img := Image.create_from_data(ts, ts, false, Image.FORMAT_R16, f.get_buffer(bytes))
	RenderingServer.texture_2d_update(_tex.get_rid(), img, layer)
	if _key_of[layer] >= 0:
		_layer_of.erase(_key_of[layer])
	_key_of[layer] = key
	_layer_of[key] = layer
	_used[layer] = _frame
	return true


## A free layer, or the least recently drawn one (never one drawn this frame, never a top-level tile).
func _free_layer() -> int:
	var best := -1
	var best_t := _frame
	for l in POOL:
		var k := _key_of[l]
		if k < 0:
			return l
		if (k >> 48) == levels - 1:
			continue
		if _used[l] < best_t:
			best_t = _used[l]
			best = l
	return best


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
