extends RefCounted
## Ground height from the streamed terrain tiles (tools/build_kashmir.py), for the simulation and the server.
##
## Reads the finest level only, a tile at a time (decompressed tiles are cached), and interpolates exactly as the
## renderer triangulates its grid (scripts/world/terrain_streamer.gd: diagonals alternate per quad), so the ground
## the wheels roll on is the ground you see under the jet. Works without a GPU (dedicated server).

const CACHE := 256

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
	_file = FileAccess.open(dir.path_join("h0.bin"), FileAccess.READ)
	if _zstd:
		_index = FileAccess.get_file_as_bytes(dir.path_join("i0.bin"))
	return _file != null


## Map extent in world coordinates: Rect2(x, z, width, depth).
func extent() -> Rect2:
	return Rect2(x0, z0, nx * tq * spacing, nz * tq * spacing)


func _tile(i: int, j: int) -> PackedByteArray:
	var n := j * nx + i
	if _cache.has(n):
		return _cache[n]
	var bytes := ts * ts * 2
	var data: PackedByteArray
	if _zstd:
		var a := _index.decode_u64(n * 8)
		var b := _index.decode_u64(n * 8 + 8)
		_file.seek(a)
		data = _file.get_buffer(b - a).decompress(bytes, FileAccess.COMPRESSION_ZSTD)
	else:
		_file.seek(n * bytes)
		data = _file.get_buffer(bytes)
	_cache[n] = data
	_order.append(n)
	if _order.size() > CACHE:
		_cache.erase(_order.pop_front())
	return data


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
