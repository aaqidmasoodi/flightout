extends Node3D
## Flight scene: world, jet, camera, HUD and pause menu. Entered from the main menu's loading screen.

const DEFAULT_AIRCRAFT := "res://data/aircraft/su27.tres"
const DRAW := [
	{"far": 22000.0, "fog": 0.00007},
	{"far": 40000.0, "fog": 0.000035},
	{"far": 60000.0, "fog": 0.00002},
]

var _env: Environment
var _sun: DirectionalLight3D
var _sky: Node3D
var _cam: Camera3D


func _ready() -> void:
	get_tree().paused = false
	get_viewport().disable_3d = false
	WorldData.load_world()
	_build_environment()

	var world: Node3D = preload("res://scripts/world/world.gd").new()
	world.name = "World"
	add_child(world)

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
	if Game.online:
		Game.client.aircraft = aircraft
		Game.client.world_root = self
		Game.client.disconnected.connect(_on_disconnected)

	_cam = preload("res://scripts/chase_camera.gd").new()
	_cam.name = "ChaseCamera"
	_cam.target = aircraft
	add_child(_cam)

	var hud: CanvasLayer = preload("res://scripts/hud.gd").new()
	hud.aircraft = aircraft
	add_child(hud)

	add_child(preload("res://scripts/ui/pause_menu.gd").new())

	Settings.changed.connect(func(_k, _v): _apply_settings())
	_apply_settings()
	Game.release_cache()
	_dev_capture.call_deferred()


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
	return t


func _apply_settings() -> void:
	_sun.shadow_enabled = bool(Settings.get_value("graphics/shadows"))
	var d: Dictionary = DRAW[clampi(int(Settings.get_value("graphics/draw_distance")), 0, 2)]
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
	get_tree().quit()
