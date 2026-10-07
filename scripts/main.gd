extends Node3D
## Builds the Flightout test world: sky, sun, ground, runway, hills, jet, camera, HUD.



func _ready() -> void:
	_setup_input()
	_build_environment()

	var world: Node3D = preload("res://scripts/world/world.gd").new()
	world.name = "World"
	add_child(world)

	var aircraft: Node3D = preload("res://scripts/su27_controller.gd").new()
	aircraft.name = "Su27"
	add_child(aircraft)
	aircraft.global_transform = WorldData.spawn_transform(0)
	aircraft.spawn = aircraft.global_transform

	var cam: Camera3D = preload("res://scripts/chase_camera.gd").new()
	cam.name = "ChaseCamera"
	cam.target = aircraft
	add_child(cam)

	var hud: CanvasLayer = preload("res://scripts/hud.gd").new()
	hud.aircraft = aircraft
	add_child(hud)


func _add_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _setup_input() -> void:
	_add_keys("pitch_up", [KEY_S, KEY_DOWN])
	_add_keys("pitch_down", [KEY_W, KEY_UP])
	_add_keys("roll_left", [KEY_A, KEY_LEFT])
	_add_keys("roll_right", [KEY_D, KEY_RIGHT])
	_add_keys("yaw_left", [KEY_Q])
	_add_keys("yaw_right", [KEY_E])
	_add_keys("throttle_up", [KEY_SHIFT])
	_add_keys("throttle_down", [KEY_CTRL])
	_add_keys("toggle_gear", [KEY_G])
	_add_keys("toggle_canopy", [KEY_C])
	_add_keys("toggle_airbrake", [KEY_B])
	_add_keys("toggle_flaps", [KEY_F])
	_add_keys("toggle_radar", [KEY_R])
	_add_keys("toggle_radome", [KEY_T])
	_add_keys("toggle_view", [KEY_V])
	_add_keys("reset", [KEY_BACKSPACE])
	_add_keys("wheel_brake", [KEY_SPACE])


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.40, 0.72)
	sky_mat.sky_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_bottom_color = Color(0.25, 0.30, 0.25)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.68, 0.76, 0.86)
	env.fog_density = 0.000035
	env.fog_sky_affect = 0.15
	env.fog_aerial_perspective = 0.6

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	add_child(sun)
