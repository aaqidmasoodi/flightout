extends Node3D
## Development: a stand-in missile to test smoke trails (`--dev-missile`): launched ahead of the jet, it weaves
## through an S-turn at about Mach 2.5 for 12 s, laying the missile smoke preset, then disappears (its trail stays
## and fades out). Moves in physics ticks with interpolation like a real one would, and follows the floating origin.

var _t := 0.0
var _vel := Vector3.ZERO
const SPEED := 820.0
const LIFE := 12.0
const BURN := 6.0                  # motor burn (smoke) time, like a medium range missile


func launch(from: Transform3D) -> void:
	global_transform = from
	_vel = -from.basis.z * SPEED
	var body := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.1
	c.bottom_radius = 0.1
	c.height = 3.7
	body.mesh = c
	body.rotation.x = PI * 0.5
	add_child(body)
	WorldData.origin_shifted.connect(func(d: Vector3):
		global_position -= d
		reset_physics_interpolation())
	preload("res://scripts/fx/trail.gd").attach(self, Vector3(0.0, 0.0, 1.9), preload("res://scripts/fx/aircraft_trails.gd").SMOKE,
		func(): return 1.0 if _t < BURN else 0.0)


func _physics_process(delta: float) -> void:
	_t += delta
	if _t > LIFE:
		queue_free()
		return
	# weave: the velocity turns left and right (an S), about 15 g
	var turn := sin(_t * 0.9) * 0.18
	_vel = _vel.rotated(Vector3.UP, turn * delta)
	global_position += _vel * delta
	look_at(global_position + _vel, Vector3.UP)
	if "--dev-missile-log" in OS.get_cmdline_user_args() and int(_t * 2.0) != int((_t - delta) * 2.0):
		print("MISSILE t %.1f pos %s vel %s" % [_t, str(global_position.round()), str(_vel.round())])
