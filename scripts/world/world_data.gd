extends Node
## WorldData (autoload): authoritative, render-free description of the map.
## Gameplay, the flight model and (later) a dedicated multiplayer server all query
## the ground through this, so everyone agrees on where the terrain and sea are.
## Coordinates are Godot world space (metres, Y up, map centred on the origin).
##
## Floating origin. The world is far bigger than 32-bit floats can describe precisely (at 350 km a float only
## resolves 3 cm), so nothing is ever simulated or drawn far from (0, 0):
##   world    absolute map coordinates. Every query here (terrain_height, ground_height, is_water, runways,
##            spawns) is in world coordinates. GDScript floats are 64-bit, so plain floats hold them exactly.
##   scene    Godot positions on the client: world minus `origin`. The scene origin follows your own jet (a whole
##            number of ORIGIN_CELL steps), so the jet and the camera always sit within a couple of km of (0, 0).
##            Use scene_ground_height() etc. with node positions. When the origin moves, origin_shifted(delta)
##            fires and everything holding scene positions moves by -delta (the World node, remote jets, tracks).
##   sim      each FlightModel keeps its own local frame (its ox, oz), stepped the same way on the client and
##            the server, so physics keeps millimetre precision anywhere on the map (scripts/sim/flight_model.gd).
## Height (y) is never shifted: it stays metres above sea level everywhere.

signal origin_shifted(delta: Vector3)
const ORIGIN_CELL := 2000.0          # origins are whole multiples of this: exact even as 32-bit floats
var origin_x := 0.0                  # scene origin in world coordinates
var origin_z := 0.0
var _log_origin := "--origin-log" in OS.get_cmdline_user_args()

const HEIGHTMAP_PATH := "res://assets/world/heightmap.r32"
const META_PATH := "res://assets/world/world_meta.json"

var resolution := 1025
var cell_size := 40.0
var half_extent := 20480.0
var sea_level := 0.0
var spawns: Array = []
## Shared atmosphere (ISA, wind, turbulence). Server-owned in multiplayer; driven by Settings for now.
var atmosphere = preload("res://scripts/sim/atmosphere.gd").new()
## Runways: threshold = start of the landing direction, dir = landing direction (unit, flat).
## Runway 36 (from the south, over the sea) is the instrument runway. Runway 18 is visual only:
## the northern mountains block a straight-in approach, so it gets no ILS or PAPI.
var runways: Array = [
	{"name": "36", "threshold": Vector3(0.0, 40.0, 7500.0), "dir": Vector3(0.0, 0.0, -1.0), "length": 3000.0, "width": 45.0, "ils": true},
	{"name": "18", "threshold": Vector3(0.0, 40.0, 4500.0), "dir": Vector3(0.0, 0.0, 1.0), "length": 3000.0, "width": 45.0, "ils": false},
]
const AIM_DISTANCE := 300.0      # touchdown aim point beyond the threshold
const GLIDESLOPE_DEG := 3.0
var loaded := false

var _h := PackedFloat32Array()


var _tiles = null                    # streamed-terrain heights (scripts/world/terrain_heights.gd) when flying a large map


## Airfields of a large map (data/maps/<map>/airfields.json): [{id, name, country, x, z, runways: [{ids, a, b,
## length, width}]}] with a, b the runway ends [x, height, z] in world coordinates.
var airfields: Array = []
var start_airfield := "VISR"
var map_dir := ""                    # res://data/maps/<map> of a large map (chart, airfields)


func _load_airfields(path: String) -> void:
	var d = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if typeof(d) != TYPE_DICTIONARY:
		return
	airfields = d.airfields
	runways = []
	for a in airfields:
		for r in a.runways:
			var A := Vector3(r.a[0], r.a[1], r.a[2])
			var B := Vector3(r.b[0], r.b[1], r.b[2])
			var dir := Vector3(B.x - A.x, 0.0, B.z - A.z).normalized()
			runways.append({"name": String(r.ids[0]), "threshold": A, "dir": dir, "length": float(r.length), "width": float(r.width), "ils": true, "airfield": a.id})
			runways.append({"name": String(r.ids[1]), "threshold": B, "dir": -dir, "length": float(r.length), "width": float(r.width), "ils": true, "airfield": a.id})
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--airfield="):
			start_airfield = arg.trim_prefix("--airfield=").to_upper()


func airfield(id: String) -> Dictionary:
	for a in airfields:
		if String(a.id) == id or String(a.get("icao", "")) == id:
			return a
	return {}


## Land cover class at a map position on a large map (ESA WorldCover codes, see terrain_heights.gd), else 0.
func land_cover(x: float, z: float) -> int:
	return _tiles.cover(x, z) if _tiles != null else 0


## True on a large streamed map (no sea, far horizons).
func is_large() -> bool:
	return _tiles != null


## Loads the heightmap. Called when a flight starts, so the main menu stays fast.
func load_world() -> void:
	if loaded:
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):        # development: fly a streamed large map (no sea, no island)
			var th = preload("res://scripts/world/terrain_heights.gd").new()
			var tdir := arg.trim_prefix("--terrain=")
			if th.setup(tdir):
				_tiles = th
				sea_level = -2000.0
				map_dir = "res://data/maps/%s" % tdir.trim_suffix("/").get_file()
				_load_airfields(map_dir + "/airfields.json")
	var meta_text := FileAccess.get_file_as_string(META_PATH)
	var meta = JSON.parse_string(meta_text)
	if meta is Dictionary:
		resolution = int(meta.get("resolution", resolution))
		cell_size = float(meta.get("cell_size_m", cell_size))
		half_extent = float(meta.get("half_extent_m", half_extent))
		sea_level = float(meta.get("sea_level_m", sea_level))
		if _tiles != null:
			sea_level = -2000.0
		spawns = meta.get("spawns", [])
	_h = FileAccess.get_file_as_bytes(HEIGHTMAP_PATH).to_float32_array()
	loaded = _h.size() == resolution * resolution and meta is Dictionary
	if not loaded:
		# Never fly in a broken world (flat ground, no forests, falling through runways): stop with a clear message.
		push_error("WorldData: world data missing or damaged (meta %s, %d height values)" % [str(meta is Dictionary), _h.size()])
		OS.alert("FlightOut's world data is missing or damaged.\n\nPlease reinstall FlightOut.", "FlightOut")
		get_tree().quit(1)


## Terrain elevation (can be below sea level), bilinear between grid samples.
func terrain_height(x: float, z: float) -> float:
	if _tiles != null:
		return _tiles.height(x, z)
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


# ---------------- floating origin ----------------
## Moves the scene origin to world (x, z) (rounded to ORIGIN_CELL). Everything that holds scene positions
## listens to origin_shifted and moves by -delta.
func set_origin(x: float, z: float) -> void:
	x = snappedf(x, ORIGIN_CELL)
	z = snappedf(z, ORIGIN_CELL)
	if x == origin_x and z == origin_z:
		return
	var delta := Vector3(x - origin_x, 0.0, z - origin_z)
	origin_x = x
	origin_z = z
	RenderingServer.global_shader_parameter_set("world_origin", Vector2(origin_x, origin_z))
	if _log_origin:
		print("ORIGIN %.0f %.0f" % [origin_x, origin_z])
	origin_shifted.emit(delta)


## Back to the map centre with no notifications (a new flight builds its scene from scratch).
func reset_origin() -> void:
	origin_x = 0.0
	origin_z = 0.0
	RenderingServer.global_shader_parameter_set("world_origin", Vector2.ZERO)


func to_world(scene_pos: Vector3) -> Vector3:
	return Vector3(scene_pos.x + origin_x, scene_pos.y, scene_pos.z + origin_z)


func to_scene(world_pos: Vector3) -> Vector3:
	return Vector3(world_pos.x - origin_x, world_pos.y, world_pos.z - origin_z)


## Ground under a scene position (node coordinates).
func scene_ground_height(x: float, z: float) -> float:
	return ground_height(x + origin_x, z + origin_z)


func scene_is_water(x: float, z: float) -> bool:
	return is_water(x + origin_x, z + origin_z)


func is_water(x: float, z: float) -> bool:
	return terrain_height(x, z) < sea_level


## Approximate surface normal from the heightmap.
func terrain_normal(x: float, z: float) -> Vector3:
	var e := cell_size
	var hx := terrain_height(x + e, z) - terrain_height(x - e, z)
	var hz := terrain_height(x, z + e) - terrain_height(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func spawn_transform(index: int = 0) -> Transform3D:
	if is_large():
		# lined up on the first runway of the start airfield, 150 m in from its threshold
		var a := airfield(start_airfield)
		if a.is_empty() and not airfields.is_empty():
			a = airfields[0]
		if not a.is_empty():
			var r: Dictionary = a.runways[0]
			var A := Vector3(r.a[0], 0.0, r.a[2])
			var dir := (Vector3(r.b[0], 0.0, r.b[2]) - A).normalized()
			var p := A + dir * 150.0
			p.y = ground_height(p.x, p.z) + 2.2
			return Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), p)
	if spawns.is_empty():
		return Transform3D(Basis(), Vector3(0.0, 42.0, 7350.0))
	var s: Dictionary = spawns[index % spawns.size()]
	var p: Array = s.get("godot_pos", [0.0, 42.0, 7350.0])
	var basis := Basis(Vector3.UP, deg_to_rad(-float(s.get("heading_deg", 0.0))))
	return Transform3D(basis, Vector3(p[0], p[1], p[2]))


## ILS-style guidance to the runway the aircraft is lined up for (empty if none).
## loc_dev > 0: aircraft is right of the centreline. gs_dev > 0: aircraft is above the glideslope.
## `pos` is a scene position.
func approach_guidance(scene_pos: Vector3, heading: Vector3) -> Dictionary:
	var pos := to_world(scene_pos)
	var best := {}
	var best_dist := INF
	for r in runways:
		if not r.get("ils", false):
			continue
		var dir: Vector3 = r.dir
		var aim: Vector3 = r.threshold + dir * AIM_DISTANCE
		var d := pos - aim
		var along := -d.dot(dir)
		if along < 150.0 or along > 25000.0:
			continue
		var right := dir.cross(Vector3.UP).normalized()
		var lateral := d.dot(right)
		var loc := atan2(lateral, along)
		if absf(loc) > deg_to_rad(35.0):
			continue
		var h2 := Vector2(heading.x, heading.z)
		if h2.length() < 0.1 or h2.normalized().dot(Vector2(dir.x, dir.z)) < 0.5:
			continue
		var height := pos.y - 2.0 - aim.y
		var gs := atan2(height, along)
		if along < best_dist:
			best_dist = along
			best = {"name": r.name, "dist": along, "loc_dev": rad_to_deg(loc), "gs_dev": rad_to_deg(gs) - GLIDESLOPE_DEG, "height": height}
	return best


## Time of day (hours, 0..24) and how fast it runs; sky conditions. Owned by the server in multiplayer.
var time_of_day := 13.5
var time_scale := 0.0          # game seconds per real second: 0 frozen, 1 real time, 60 = an hour per minute
var conditions := 1            # 0 clear, 1 scattered, 2 broken, 3 overcast, 4 fog, 5 rain
const TIME_SCALES := [0.0, 1.0, 60.0]

const WIND_SPEEDS := [0.0, 5.0, 10.0, 15.0]          # calm, light (10 kt), moderate (20 kt), strong (30 kt)
const TURBULENCE := [0.0, 0.3, 0.6, 1.0]


func _ready() -> void:
	Settings.changed.connect(func(k, _v):
		if String(k).begins_with("weather/"):
			apply_weather())
	apply_weather()


## Online, the server owns weather and time; local weather settings are ignored until you leave.
var server_weather := false

func set_server_weather(w: Dictionary) -> void:
	server_weather = true
	atmosphere.wind_from_deg = w.wind_from
	atmosphere.wind_speed = w.wind_speed
	atmosphere.turbulence = w.turbulence
	atmosphere.seed = w.seed
	time_of_day = w.time
	time_scale = w.time_scale
	conditions = clampi(w.conditions, 0, 5)


func clear_server_weather() -> void:
	if server_weather:
		server_weather = false
		apply_weather()


func apply_weather() -> void:
	if server_weather:
		return
	atmosphere.wind_speed = WIND_SPEEDS[clampi(int(Settings.get_value("weather/wind")), 0, 3)]
	atmosphere.wind_from_deg = float(Settings.get_value("weather/wind_from"))
	atmosphere.turbulence = TURBULENCE[clampi(int(Settings.get_value("weather/turbulence")), 0, 3)]
	time_of_day = fposmod(float(Settings.get_value("weather/time")), 24.0)
	time_scale = TIME_SCALES[clampi(int(Settings.get_value("weather/time_flow")), 0, 2)]
	conditions = clampi(int(Settings.get_value("weather/conditions")), 0, 5)


func _process(delta: float) -> void:
	if time_scale > 0.0 and not get_tree().paused:
		time_of_day = fposmod(time_of_day + delta * time_scale / 3600.0, 24.0)
