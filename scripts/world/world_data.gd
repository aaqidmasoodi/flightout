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

## The map: Kashmir, streamed from its tiles (tools/build_kashmir.py; assets/kashmir is built locally, about 1 GB,
## and not in git). Airfields, chart and other data that go with it are in data/maps/kashmir.
const TERRAIN_DIR := "res://assets/kashmir"
const MAP_DIR := "res://data/maps/kashmir"
var terrain_dir := TERRAIN_DIR       # `--terrain=<dir>` (development) flies other tiles
var map_dir := MAP_DIR

var cell_size := 32.0                # finest terrain sample spacing (terrain_normal)
var sea_level := -2000.0             # no sea on this map (lakes are part of the ground)
## Shared atmosphere (ISA, wind, turbulence). Server-owned in multiplayer; driven by Settings for now.
var atmosphere = preload("res://scripts/sim/atmosphere.gd").new()
## Runway ends of every airfield: threshold = start of the landing direction, dir = landing direction (unit, flat).
var runways: Array = []
const AIM_DISTANCE := 300.0      # touchdown aim point beyond the threshold
const GLIDESLOPE_DEG := 3.0
var loaded := false


## Drawn curvature of the Earth on large maps: 1 / (2 R'), with R' the radius stretched by standard atmospheric
## refraction (coefficient 0.13, R' = 6371 km / 0.87 = 7323 km), as surveyors use for lines of sight. The ground
## d metres away sits d^2 / (2 R') lower than a flat plane: 0.7 m at 3 km, 68 m at 30 km, 683 m at 100 km.
const EARTH_CURVE := 1.0 / (2.0 * 6371008.8 / 0.87)

var _tiles = null                    # terrain heights from the tiles (scripts/world/terrain_heights.gd)


## Airfields (data/maps/kashmir/airfields.json, tools/build_airfields.py): [{id, name, country, x, z, runways: [{ids, a, b,
## length, width}]}] with a, b the runway ends [x, height, z] in world coordinates.
var airfields: Array = []
var start_airfield := "VISR"


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
	home_airfield = start_airfield


var home_airfield := "VISR"          # where our jet started (the HSI and the MFD map point back to it)


## Scene position of the home airfield (centre), for the instruments.
func home_position() -> Vector3:
	var a := airfield(home_airfield)
	if a.is_empty():
		return to_scene(Vector3.ZERO)
	return to_scene(Vector3(float(a.x), 0.0, float(a.z)))


func airfield(id: String) -> Dictionary:
	for a in airfields:
		if String(a.id) == id or String(a.get("icao", "")) == id:
			return a
	return {}


## Land cover class at a map position on a large map (ESA WorldCover codes, see terrain_heights.gd), else 0.
func land_cover(x: float, z: float) -> int:
	return _tiles.cover(x, z) if _tiles != null else 0


## True once the map is loaded (kept from when there was also a small island map: no sea, far horizons).
func is_large() -> bool:
	return _tiles != null


## Loads the terrain heights and the airfields. Called when a flight starts (and by the server), so the main menu
## stays fast.
func load_world() -> void:
	if loaded:
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):        # development: other tiles
			terrain_dir = arg.trim_prefix("--terrain=")
	var th = preload("res://scripts/world/terrain_heights.gd").new()
	if not th.setup(terrain_dir):
		# Never fly in a broken world (no ground to land on): stop with a clear message.
		push_error("WorldData: map data missing in " + terrain_dir)
		if DisplayServer.get_name() != "headless":
			OS.alert("FlightOut's map data is missing or damaged.\n\nPlease reinstall FlightOut.", "FlightOut")
		get_tree().quit(1)
		return
	_tiles = th
	_load_airfields(map_dir + "/airfields.json")
	# the Earth's curvature, drawn (scenery sinks below a flat plane with distance; physics stay flat)
	RenderingServer.global_shader_parameter_set("earth_curve", EARTH_CURVE)
	loaded = true


## Terrain elevation (metres above sea level), interpolated exactly as the terrain is drawn.
func terrain_height(x: float, z: float) -> float:
	return _tiles.height(x, z) if _tiles != null else 0.0


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
	RenderingServer.global_shader_parameter_set("earth_curve", EARTH_CURVE if is_large() else 0.0)


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


## Offline start: lined up on the start airfield's first runway, 150 m in from its threshold (`--airfield=ICAO`).
func spawn_transform(_index: int = 0) -> Transform3D:
	var a := airfield(start_airfield)
	if a.is_empty() and not airfields.is_empty():
		a = airfields[0]
	if a.is_empty():
		return Transform3D(Basis(), Vector3(0.0, ground_height(0.0, 0.0) + 500.0, 0.0))
	var r: Dictionary = a.runways[0]
	var A := Vector3(r.a[0], 0.0, r.a[2])
	var dir := (Vector3(r.b[0], 0.0, r.b[2]) - A).normalized()
	var p := A + dir * 150.0
	p.y = ground_height(p.x, p.z) + 2.2
	return Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), p)


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
