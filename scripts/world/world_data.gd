extends Node
## WorldData (autoload): authoritative, render-free description of the map.
## Gameplay, the flight model and (later) a dedicated multiplayer server all query
## the ground through this, so everyone agrees on where the terrain and sea are.
## Coordinates are Godot world space (metres, Y up, map centred on the origin).

const HEIGHTMAP_PATH := "res://assets/world/heightmap.r32"
const META_PATH := "res://assets/world/world_meta.json"

var resolution := 1025
var cell_size := 40.0
var half_extent := 20480.0
var sea_level := 0.0
var spawns: Array = []
var loaded := false

var _h := PackedFloat32Array()


func _enter_tree() -> void:
	var meta_text := FileAccess.get_file_as_string(META_PATH)
	var meta = JSON.parse_string(meta_text)
	if meta is Dictionary:
		resolution = int(meta.get("resolution", resolution))
		cell_size = float(meta.get("cell_size_m", cell_size))
		half_extent = float(meta.get("half_extent_m", half_extent))
		sea_level = float(meta.get("sea_level_m", sea_level))
		spawns = meta.get("spawns", [])
	_h = FileAccess.get_file_as_bytes(HEIGHTMAP_PATH).to_float32_array()
	loaded = _h.size() == resolution * resolution
	if not loaded:
		push_error("WorldData: heightmap missing or wrong size (%d values)" % _h.size())


## Terrain elevation (can be below sea level), bilinear between grid samples.
func terrain_height(x: float, z: float) -> float:
	if not loaded:
		return 0.0
	var col := (x + half_extent) / cell_size
	var row := (half_extent - z) / cell_size
	if col < 0.0 or row < 0.0 or col >= resolution - 1 or row >= resolution - 1:
		return -75.0
	var c0 := int(col)
	var r0 := int(row)
	var fx := col - c0
	var fz := row - r0
	var i := r0 * resolution + c0
	var a := lerpf(_h[i], _h[i + 1], fx)
	var b := lerpf(_h[i + resolution], _h[i + resolution + 1], fx)
	return lerpf(a, b, fz)


## Height of whatever you would hit: terrain or the sea surface.
func ground_height(x: float, z: float) -> float:
	return maxf(terrain_height(x, z), sea_level)


func is_water(x: float, z: float) -> bool:
	return terrain_height(x, z) < sea_level


## Approximate surface normal from the heightmap.
func terrain_normal(x: float, z: float) -> Vector3:
	var e := cell_size
	var hx := terrain_height(x + e, z) - terrain_height(x - e, z)
	var hz := terrain_height(x, z + e) - terrain_height(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func spawn_transform(index: int = 0) -> Transform3D:
	if spawns.is_empty():
		return Transform3D(Basis(), Vector3(0.0, 42.0, 7350.0))
	var s: Dictionary = spawns[index % spawns.size()]
	var p: Array = s.get("godot_pos", [0.0, 42.0, 7350.0])
	var basis := Basis(Vector3.UP, deg_to_rad(-float(s.get("heading_deg", 0.0))))
	return Transform3D(basis, Vector3(p[0], p[1], p[2]))
