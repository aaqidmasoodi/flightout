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
	_sky.draw_fog = d.fog


func _build_environment() -> void:
	_sky = preload("res://scripts/world/sky_system.gd").new()
	_sky.name = "Sky"
	add_child(_sky)
	_env = _sky.env
	_sun = _sky.sun
