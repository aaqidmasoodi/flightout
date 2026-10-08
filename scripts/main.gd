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
	aircraft.global_transform = WorldData.spawn_transform(0)
	aircraft.spawn = aircraft.global_transform
	aircraft.reset()

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


func _apply_settings() -> void:
	_sun.shadow_enabled = bool(Settings.get_value("graphics/shadows"))
	var d: Dictionary = DRAW[clampi(int(Settings.get_value("graphics/draw_distance")), 0, 2)]
	_cam.far = d.far
	_env.fog_density = d.fog


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.40, 0.72)
	sky_mat.sky_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_horizon_color = Color(0.66, 0.76, 0.88)
	sky_mat.ground_bottom_color = Color(0.25, 0.30, 0.25)
	var sky := Sky.new()
	sky.sky_material = sky_mat

	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.68, 0.76, 0.86)
	_env.fog_density = 0.000035
	_env.fog_sky_affect = 0.15
	_env.fog_aerial_perspective = 0.6

	var world_env := WorldEnvironment.new()
	world_env.environment = _env
	add_child(world_env)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = 300.0
	add_child(_sun)
