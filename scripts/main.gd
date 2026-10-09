extends Node3D
## Flight scene: world, jet, camera, HUD and pause menu. Entered from the main menu's loading screen.

const DEFAULT_AIRCRAFT := "res://data/aircraft/su27.tres"
## Large streamed maps (Kashmir): mountains are worth seeing far away; the haze thins with draw distance so the
## horizon stays soft, as distant ranges fade into the sky's colour (aerial perspective) instead of ending in a line.
const DRAW_LARGE := [
	{"far": 90000.0, "fog": 0.000024},
	{"far": 160000.0, "fog": 0.000015},
	{"far": 260000.0, "fog": 0.0000095},
]
const DRAW := [
	{"far": 22000.0, "fog": 0.00007},
	{"far": 40000.0, "fog": 0.000035},
	{"far": 60000.0, "fog": 0.00002},
]

var _env: Environment
var _sun: DirectionalLight3D
var _sky: Node3D
var _cam: Camera3D
var _world: Node3D


func _on_origin_shifted(_delta: Vector3) -> void:
	_world.position = Vector3(-WorldData.origin_x, 0.0, -WorldData.origin_z)
	if _cam:
		_cam.origin_moved()     # resets its interpolation once it has placed itself in the new frame
	if _origin_shots != "":
		_save_shift_frames()


## Development: `--origin-shots=<folder>` saves the frame before and the frames after every origin shift, to check
## that nothing in view jumps when the floating origin moves.
var _origin_shots := ""
var _last_frame: Image
var _shift_n := 0


func _process(_delta: float) -> void:
	if _origin_shots != "":
		_last_frame = get_viewport().get_texture().get_image()


func _save_shift_frames() -> void:
	var n := _shift_n
	_shift_n += 1
	if _last_frame:
		_last_frame.save_png(_origin_shots.path_join("shift%02d_a.png" % n))
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_origin_shots.path_join("shift%02d_b.png" % n))


func _ready() -> void:
	get_tree().paused = false
	get_viewport().disable_3d = false
	WorldData.load_world()
	WorldData.reset_origin()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--origin-shots="):
			_origin_shots = arg.trim_prefix("--origin-shots=")
	_build_environment()

	var world: Node3D = preload("res://scripts/world/world.gd").new()
	world.name = "World"
	add_child(world)
	# floating origin: the World node (terrain, airbase, forests, lights, anything fixed to the map) sits at minus
	# the scene origin, so its children keep their world coordinates (scripts/world/world_data.gd)
	_world = world
	WorldData.origin_shifted.connect(_on_origin_shifted)

	var aircraft: Node3D = preload("res://scripts/aircraft/aircraft.gd").new()
	aircraft.spec = load("res://data/aircraft/su27.tres")
	aircraft.name = "Su27"
	add_child(aircraft)
	if Game.online:
		# online: parked in our shelter, simulated here and corrected by the server
		aircraft.net_mode = aircraft.NetMode.PREDICTED
		aircraft.slot = Game.client.my_slot
		aircraft.global_transform = preload("res://scripts/world/airbase_layout.gd").parking_slot(Game.client.my_slot)
	else:
		aircraft.global_transform = _start_transform()
	aircraft.spawn = aircraft.global_transform
	aircraft.place(aircraft.spawn)
	if "--air-start" in OS.get_cmdline_user_args():   # development: start flying (with --start-pos / --alt / --start-hdg)
		aircraft.air_start.call_deferred(aircraft.spawn, 230.0)
	if Game.online:
		Game.client.aircraft = aircraft
		Game.client.world_root = self
		Game.client.disconnected.connect(_on_disconnected)

	_cam = preload("res://scripts/chase_camera.gd").new()
	_cam.name = "ChaseCamera"
	_cam.target = aircraft
	add_child(_cam)

	add_child(preload("res://scripts/ui/fps_counter.gd").new())   # the players' frame rate counter (a setting)
	if Game.dev_hud:          # development overlay only (scripts/core/game.gd), never in an exported game
		var hud: CanvasLayer = preload("res://scripts/hud.gd").new()
		hud.aircraft = aircraft
		add_child(hud)

	add_child(preload("res://scripts/ui/pause_menu.gd").new())
	var map: CanvasLayer = preload("res://scripts/ui/map_view.gd").new()
	map.name = "Map"
	map.aircraft = aircraft
	add_child(map)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bench="):       # development: performance run (scripts/dev/bench.gd)
			var bench: Node = preload("res://scripts/dev/bench.gd").new()
			bench.aircraft = aircraft
			bench.cam = _cam
			bench.world = world
			add_child(bench)

	Settings.changed.connect(func(_k, _v): _apply_settings())
	_apply_settings()
	Game.release_cache()
	_dev_capture.call_deferred()
	if "--dev-missile" in OS.get_cmdline_user_args():
		_dev_missiles(aircraft)
	if "--dev-flares" in OS.get_cmdline_user_args():
		_dev_flares(aircraft)
	if "--dev-bandits" in OS.get_cmdline_user_args():
		_dev_bandits(aircraft)
	if "--dev-shade" in OS.get_cmdline_user_args():
		aircraft.hud_shade = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--jitter-log="):   # development: per-frame pose log to hunt view vibration
			var probe: Node = preload("res://scripts/dev/jitter_probe.gd").new()
			probe.path = arg.trim_prefix("--jitter-log=")
			probe.ac = aircraft
			probe.cam = _cam
			add_child(probe)


func _on_disconnected(reason: String) -> void:
	Game.set_meta("menu_notice", reason)
	Game.goto_menu()


## Runway by default. `--slot=N` (1..16) starts parked in that shelter, as multiplayer will.
func _start_transform() -> Transform3D:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--slot="):
			var n := clampi(arg.trim_prefix("--slot=").to_int(), 1, 16)
			return preload("res://scripts/world/airbase_layout.gd").parking_slot(n - 1)
	var t := WorldData.spawn_transform(0)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--alt="):   # development: start high (metres), to check the sky and cloud deck
			t.origin.y = arg.trim_prefix("--alt=").to_float()
		elif arg.begins_with("--start-pos="):   # development: start at map position x,z (metres), on the ground
			var xz := arg.trim_prefix("--start-pos=").split(",")
			t.origin.x = xz[0].to_float()
			t.origin.z = xz[1].to_float()
			t.origin.y = WorldData.ground_height(t.origin.x, t.origin.z) + 2.2
		elif arg.begins_with("--start-hdg="):
			t.basis = Basis(Vector3.UP, deg_to_rad(-arg.trim_prefix("--start-hdg=").to_float()))
	return t


func _apply_settings() -> void:
	_sun.shadow_enabled = bool(Settings.get_value("graphics/shadows"))
	var d: Dictionary = (DRAW_LARGE if WorldData.is_large() else DRAW)[clampi(int(Settings.get_value("graphics/draw_distance")), 0, 2)]
	_cam.base_far = d.far
	_sky.draw_fog = d.fog


func _build_environment() -> void:
	_sky = preload("res://scripts/world/sky_system.gd").new()
	_sky.name = "Sky"
	add_child(_sky)
	_env = _sky.env
	_sun = _sky.sun


## Development: `--shots=<folder>` renders a set of views (camera cfg `view,yaw,pitch,zoom` per shot via
## `--views=a;b;c`, optional `--hour=`) to PNGs and quits. Lets tooling check visuals without a human.
func _dev_capture() -> void:
	var folder := ""
	var views := PackedStringArray()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			folder = arg.trim_prefix("--shots=")
		elif arg.begins_with("--views="):
			views = arg.trim_prefix("--views=").split(";")
		elif arg.begins_with("--hour="):
			WorldData.time_of_day = arg.trim_prefix("--hour=").to_float()
		elif arg.begins_with("--conditions="):     # dev: 0 clear .. 4 fog, 5 rain
			WorldData.conditions = arg.trim_prefix("--conditions=").to_int()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dev-weather-shot="):   # development: the Weather tab as seen in flight
			await get_tree().create_timer(6.0).timeout
			for n in get_children():
				if n.has_method("_open_settings"):
					n.open()
					n._open_settings()
					await get_tree().process_frame
					var tabs := n.find_children("*", "TabContainer", true, false)
					if not tabs.is_empty():
						var tc := tabs[0] as TabContainer
						for i in tc.get_tab_count():
							if tc.get_tab_title(i) == "WEATHER":
								tc.current_tab = i
			await get_tree().create_timer(1.5).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(arg.trim_prefix("--dev-weather-shot="))
			get_tree().quit()
	if folder.is_empty():
		return
	var wait := 5.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot-delay="):
			wait = arg.trim_prefix("--shot-delay=").to_float()
	await get_tree().create_timer(wait).timeout
	if "--watch-remote" in OS.get_cmdline_user_args():
		var rem := get_tree().get_first_node_in_group("remote_aircraft")
		if rem:
			_cam.target = rem
	for i in views.size():
		var v := views[i].split(",")
		_cam.view = v[0].to_int()
		_cam._first = true
		_cam._yaw = deg_to_rad(v[1].to_float()) if v.size() > 1 else 0.0
		_cam._pitch = deg_to_rad(v[2].to_float()) if v.size() > 2 else 0.0
		_cam._zoom = v[3].to_float() if v.size() > 3 else 1.0
		_cam._ck_zoom = v[4].to_float() if v.size() > 4 else 1.0
		_cam._idle = -1000.0
		if "--spin" in OS.get_cmdline_user_args():
			# swing the view fast for a second before the capture: shows any smearing behind moving objects
			var tt := 0.0
			await get_tree().create_timer(1.5).timeout
			while tt < 1.0:
				await get_tree().process_frame
				tt += get_process_delta_time()
				_cam._yaw += get_process_delta_time() * 2.5
		else:
			await get_tree().create_timer(2.5).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(folder.path_join("shot_%d.png" % i))
		var burst := 3 if "--burst" in OS.get_cmdline_user_args() else 0
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--burst="):
				burst = arg.trim_prefix("--burst=").to_int()
		if burst > 0:
			# development: consecutive frames, to measure flicker
			for k in burst:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(folder.path_join("shot_%d_%d.png" % [i, k]))
	get_tree().quit()


## Development: targets for the radar and situation displays, ahead of the start position, plus an AWACS
## (datalink source) far behind, so radar (filled) and datalink-only (open) contacts can both be seen.
func _dev_bandits(aircraft: Node3D) -> void:
	var Bandit = preload("res://scripts/dev/dev_bandit.gd")
	var start: Transform3D = aircraft.global_transform
	var fwd: Vector3 = -start.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP)
	# [metres ahead, metres right, altitude, speed, heading offset deg, team, turn rate]
	var list := [[30000.0, -6000.0, 4000.0, 230.0, 180.0, "red", 0.0], [42000.0, 9000.0, 6500.0, 250.0, 200.0, "red", 0.0],
		[55000.0, 2000.0, 3000.0, 210.0, 150.0, "red", 0.02], [70000.0, -20000.0, 8000.0, 240.0, 90.0, "red", 0.0],
		[20000.0, 15000.0, 2500.0, 200.0, 0.0, "blue", 0.0], [140000.0, 30000.0, 7000.0, 230.0, 180.0, "red", 0.0]]
	for i in list.size():
		var e: Array = list[i]
		var b: Node3D = Bandit.new()
		b.name = "DevBandit%d" % i
		get_node("World").add_child(b)          # fixed to the map, so it moves with the floating origin
		b.global_position = start.origin + fwd * float(e[0]) + right * float(e[1])
		b.global_position.y = float(e[2])
		var dir := fwd.rotated(Vector3.UP, -deg_to_rad(float(e[4])))
		b.velocity = dir * float(e[3])
		b.team = e[5]
		b.callsign = "BANDIT %d" % (i + 1) if e[5] == "red" else "FRIENDLY"
		b.turn_rate = float(e[6])
	var awacs := Node3D.new()
	awacs.name = "DevAWACS"
	get_node("World").add_child(awacs)
	awacs.global_position = start.origin - fwd * 60000.0 + Vector3.UP * 9000.0
	awacs.set_meta("datalink_range", 400000.0)
	awacs.add_to_group("awacs")
	if "--dev-radar" in OS.get_cmdline_user_args():
		aircraft.press_switch.call_deferred("toggle_radar")


## Development: a stand-in missile every 14 s from just ahead of the jet, weaving, to look at smoke trails.
func _dev_missiles(ac: Node3D) -> void:
	while is_inside_tree():
		await get_tree().create_timer(4.0).timeout
		var m: Node3D = preload("res://scripts/dev/dev_missile.gd").new()
		add_child(m)
		var xf: Transform3D = ac.global_transform
		# off to the right and climbing a little, so it crosses the view ahead
		var b := xf.basis * Basis(Vector3.UP, deg_to_rad(-25.0)) * Basis(Vector3.RIGHT, deg_to_rad(4.0))
		m.launch(Transform3D(b, xf.origin - xf.basis.z * 40.0 - xf.basis.y * 2.0))
		await get_tree().create_timer(10.0).timeout


## Development: a pair of flares every 3 s from the tail (the dispensers sit on the Su-27's tail boom).
func _dev_flares(ac: Node3D) -> void:
	while is_inside_tree():
		await get_tree().create_timer(3.0).timeout
		var xf: Transform3D = ac.global_transform
		for side in [-1.0, 1.0]:
			var f: Node3D = preload("res://scripts/fx/flare.gd").new()
			add_child(f)
			var kick: Vector3 = xf.basis * Vector3(side * 12.0, 14.0, 0.0)
			f.launch(xf * Vector3(side * 0.9, 0.6, 6.5), Vector3(ac.velocity) + kick)
