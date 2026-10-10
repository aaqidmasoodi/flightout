extends RefCounted
## Ground height from the streamed terrain tiles (tools/build_kashmir.py), for the simulation and the server.
##
## Reads the finest level only, a tile at a time (decompressed tiles are cached), and interpolates exactly as the
## renderer triangulates its grid (scripts/world/terrain_streamer.gd: diagonals alternate per quad), so the ground
## the wheels roll on is the ground you see under the jet. Works without a GPU (dedicated server).
##
## Safe to use from several threads (the forest plants on worker threads): the caches are behind a lock, and reads
## that miss the cache use the calling thread's own file handle. prefetch() reads the tiles around and ahead of a
## point on a worker thread, so the simulation (120 times a second) finds its ground already in memory instead of
## stopping to read the disk.

const CACHE := 1024                 # tiles kept decompressed (about 9 kB each)
const PREFETCH_R := 1               # tiles each side of the predicted point

var tq := 64
var ts := 67
var spacing := 32.0
var x0 := 0.0
var z0 := 0.0
var h_scale := 0.25
var h_offset := -500.0
var nx := 0
var nz := 0
var _file: FileAccess
var _index := PackedByteArray()
var _zstd := false
var _cache := {}
var _order: Array[int] = []
var _cfile: FileAccess              # land cover tiles (tools/build_landcover.py), same layout, one byte per sample
var _cindex := PackedByteArray()
var _ccache := {}
var _corder: Array[int] = []
var _dir := ""
var _lock := Mutex.new()
var _prefetching := false
var _prefetch_task := -1


func setup(dir: String) -> bool:
	var m = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("terrain.json")))
	if typeof(m) != TYPE_DICTIONARY:
		return false
	tq = int(m.tile_quads)
	ts = int(m.tile_samples)
	spacing = float(m.spacing)
	x0 = float(m.x0)
	z0 = float(m.z0)
	h_scale = float(m.h_scale)
	h_offset = float(m.h_offset)
	nx = int(m.tiles[0][0])
	nz = int(m.tiles[0][1])
	_zstd = m.get("compression", "") == "zstd"
	_dir = dir
	_file = FileAccess.open(dir.path_join("h0.bin"), FileAccess.READ)
	if _zstd:
		_index = FileAccess.get_file_as_bytes(dir.path_join("i0.bin"))
	if m.has("landcover") and FileAccess.file_exists(dir.path_join("lc0.bin")):
		_cfile = FileAccess.open(dir.path_join("lc0.bin"), FileAccess.READ)
		_cindex = FileAccess.get_file_as_bytes(dir.path_join("lci0.bin"))
	return _file != null


func has_cover() -> bool:
	return _cfile != null


## Land cover class (ESA WorldCover code: 10 tree cover, 20 shrubland, 30 grassland, 40 cropland, 50 built-up,
## 60 bare, 70 snow and ice, 80 water, 90 wetland, 100 moss) of the sample nearest to (x, z); 0 when unknown.
func cover(x: float, z: float) -> int:
	if _cfile == null:
		return 0
	var gx := clampi(int(round((x - x0) / spacing)), 0, nx * tq)
	var gz := clampi(int(round((z - z0) / spacing)), 0, nz * tq)
	var ti := mini(gx / tq, nx - 1)
	var tj := mini(gz / tq, nz - 1)
	var d := _ctile(ti, tj)
	if d.size() != ts * ts:
		return 0
	return d[(gz - tj * tq + 1) * ts + (gx - ti * tq + 1)]


func _ctile(i: int, j: int) -> PackedByteArray:
	var n := j * nx + i
	_lock.lock()
	var hit = _ccache.get(n)
	_lock.unlock()
	if hit != null:
		return hit
	var a := _cindex.decode_u64(n * 8)
	var b := _cindex.decode_u64(n * 8 + 8)
	var f := FileAccess.open(_dir.path_join("lc0.bin"), FileAccess.READ) if OS.get_thread_caller_id() != OS.get_main_thread_id() else _cfile
	_lock.lock()          # (the shared handle seeks: one reader at a time)
	f.seek(a)
	var raw := f.get_buffer(b - a)
	_lock.unlock()
	var data := raw.decompress(ts * ts, FileAccess.COMPRESSION_ZSTD)
	_lock.lock()
	if not _ccache.has(n):
		_ccache[n] = data
		_corder.append(n)
		if _corder.size() > CACHE:
			_ccache.erase(_corder.pop_front())
	_lock.unlock()
	return data


## Map extent in world coordinates: Rect2(x, z, width, depth).
func extent() -> Rect2:
	return Rect2(x0, z0, nx * tq * spacing, nz * tq * spacing)


func _tile(i: int, j: int) -> PackedByteArray:
	var n := j * nx + i
	_lock.lock()
	var hit = _cache.get(n)
	_lock.unlock()
	if hit != null:
		return hit
	return _load_tile(n, null)


## Reads and decompresses height tile n and caches it. `f`: a file handle of the caller's own (worker threads), or
## null for the shared one (then the read happens under the lock).
func _load_tile(n: int, f: FileAccess) -> PackedByteArray:
	var bytes := ts * ts * 2
	var shared := f == null
	if shared:
		f = _file
		_lock.lock()
	var raw: PackedByteArray
	if _zstd:
		var a := _index.decode_u64(n * 8)
		var b := _index.decode_u64(n * 8 + 8)
		f.seek(a)
		raw = f.get_buffer(b - a)
	else:
		f.seek(n * bytes)
		raw = f.get_buffer(bytes)
	if shared:
		_lock.unlock()
	var data := raw.decompress(bytes, FileAccess.COMPRESSION_ZSTD) if _zstd else raw
	_lock.lock()
	if not _cache.has(n):
		_cache[n] = data
		_order.append(n)
		if _order.size() > CACHE:
			_cache.erase(_order.pop_front())
	_lock.unlock()
	return data


## Reads the tiles around (x, z) on a worker thread, if they are not in memory yet. Call it with where the jet will be
## in a second or two; at most one read is in flight, and the call returns at once.
func prefetch(x: float, z: float) -> void:
	if _prefetching or _file == null:
		return
	var ti := clampi(int((x - x0) / (spacing * tq)), 0, nx - 1)
	var tj := clampi(int((z - z0) / (spacing * tq)), 0, nz - 1)
	var want := PackedInt32Array()
	_lock.lock()
	for dj in range(-PREFETCH_R, PREFETCH_R + 1):
		for di in range(-PREFETCH_R, PREFETCH_R + 1):
			var i := ti + di
			var j := tj + dj
			if i >= 0 and i < nx and j >= 0 and j < nz and not _cache.has(j * nx + i):
				want.append(j * nx + i)
	_lock.unlock()
	if want.is_empty():
		return
	if _prefetch_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_prefetch_task)     # (finished: _prefetching is false)
	_prefetching = true
	_prefetch_task = WorkerThreadPool.add_task(_prefetch_worker.bind(want))


func _prefetch_worker(want: PackedInt32Array) -> void:
	var f := FileAccess.open(_dir.path_join("h0.bin"), FileAccess.READ)
	if f:
		for n in want:
			_load_tile(n, f)
	_prefetching = false


## Waits for a prefetch in flight (leaving the map).
func finish() -> void:
	if _prefetch_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_prefetch_task)
		_prefetch_task = -1


func height(x: float, z: float) -> float:
	var gx := clampf((x - x0) / spacing, 0.0, nx * tq - 0.001)
	var gz := clampf((z - z0) / spacing, 0.0, nz * tq - 0.001)
	var qx := int(gx)
	var qz := int(gz)
	var fx := gx - qx
	var fz := gz - qz
	var ti := qx / tq
	var tj := qz / tq
	var d := _tile(ti, tj)
	if d.size() != ts * ts * 2:
		return 0.0
	var lx := qx - ti * tq + 1          # + 1: the tile's border sample
	var lz := qz - tj * tq + 1
	var o := (lz * ts + lx) * 2
	var ha := d.decode_u16(o) * h_scale + h_offset
	var hb := d.decode_u16(o + 2) * h_scale + h_offset
	var hc := d.decode_u16(o + ts * 2) * h_scale + h_offset
	var hd := d.decode_u16(o + ts * 2 + 2) * h_scale + h_offset
	if (qx + qz) % 2 == 0:
		# diagonal a-d
		if fx >= fz:
			return ha + (hb - ha) * fx + (hd - hb) * fz
		return ha + (hc - ha) * fz + (hd - hc) * fx
	# diagonal b-c
	if fx + fz <= 1.0:
		return ha + (hb - ha) * fx + (hc - ha) * fz
	return hd + (hc - hd) * (1.0 - fx) + (hb - hd) * (1.0 - fz)
