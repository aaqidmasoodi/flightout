extends Node3D
## Builds the Flightout test world: sky, sun, ground, runway, hills, jet, camera, HUD.

const SPAWN := Vector3(0.0, 2.0, 1200.0)


func _ready() -> void:
	_setup_input()
	_build_environment()
	_build_ground()

	var aircraft: Node3D = preload("res://scripts/su27_controller.gd").new()
	aircraft.name = "Su27"
	add_child(aircraft)
	aircraft.global_position = SPAWN
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
	env.fog_density = 0.00008
	env.fog_sky_affect = 0.0

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	add_child(sun)


func _mat(c: Color, rough: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _build_ground() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60000.0, 60000.0)
	ground.mesh = plane
	ground.material_override = _mat(Color(0.30, 0.42, 0.22))
	add_child(ground)

	var runway := MeshInstance3D.new()
	var rbox := BoxMesh.new()
	rbox.size = Vector3(45.0, 0.1, 3000.0)
	runway.mesh = rbox
	runway.material_override = _mat(Color(0.17, 0.17, 0.18), 0.9)
	add_child(runway)

	var stripe := BoxMesh.new()
	stripe.size = Vector3(1.0, 0.12, 30.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = stripe
	mm.instance_count = 50
	for i in 50:
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0.0, 0.0, -1470.0 + i * 60.0)))
	var stripes := MultiMeshInstance3D.new()
	stripes.multimesh = mm
	stripes.material_override = _mat(Color(0.95, 0.95, 0.90))
	add_child(stripes)

	# scattered hills so you can feel speed and height
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var hill := SphereMesh.new()
	hill.radius = 1.0
	hill.height = 2.0
	hill.radial_segments = 16
	hill.rings = 8
	var hm := MultiMesh.new()
	hm.transform_format = MultiMesh.TRANSFORM_3D
	hm.mesh = hill
	hm.instance_count = 400
	for i in 400:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(2500.0, 25000.0)
		var r := rng.randf_range(150.0, 900.0)
		var h := rng.randf_range(60.0, 500.0)
		var p := Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		hm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(r, h, r)), p))
	var hills := MultiMeshInstance3D.new()
	hills.multimesh = hm
	hills.material_override = _mat(Color(0.24, 0.34, 0.20))
	add_child(hills)
