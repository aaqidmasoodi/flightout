extends Camera3D
## Three views (V cycles): CLOSE chase, FAR chase, COCKPIT.
## Hold right mouse button and drag to look / orbit around. Mouse wheel zooms the chase views.
## The chase rig follows the jet's full orientation through a smoothed quaternion,
## so rolls, loops and inverted flight never flip or snap the camera.

enum View { CLOSE, FAR, COCKPIT }
const VIEW_NAMES := ["CLOSE", "FAR", "COCKPIT"]
const OFFSETS := [Vector3(0.0, 3.2, 15.0), Vector3(0.0, 8.0, 42.0)]
const COCKPIT_EYE := Vector3(0.0, 1.36, -5.0)
const SENSITIVITY := 0.005
const RECENTER_DELAY := 1.0
const FOLLOW_SHARPNESS := 5.0   # higher = camera rotates with the jet more tightly

var target: Node3D
var view: int = View.CLOSE
var view_name: String:
	get: return VIEW_NAMES[view]

var _yaw := 0.0
var _pitch := 0.0
var _zoom := 1.0
var _dragging := false
var _idle := 0.0
var _rig := Quaternion.IDENTITY
var _first := true


func _ready() -> void:
	fov = 70.0
	near = 0.05
	far = 60000.0
	current = true
	process_physics_priority = 10


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * 0.9, 0.4, 3.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom * 1.1, 0.4, 3.0)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * SENSITIVITY
		_pitch -= mm.relative.y * SENSITIVITY
		_idle = 0.0
		if view == View.COCKPIT:
			_yaw = clampf(_yaw, deg_to_rad(-160.0), deg_to_rad(160.0))
			_pitch = clampf(_pitch, deg_to_rad(-60.0), deg_to_rad(85.0))
		else:
			_yaw = wrapf(_yaw, -PI, PI)
			_pitch = clampf(_pitch, deg_to_rad(-80.0), deg_to_rad(80.0))


func _physics_process(delta: float) -> void:
	if target == null:
		return
	if Input.is_action_just_pressed("toggle_view"):
		view = (view + 1) % 3
		_yaw = 0.0
		_pitch = 0.0
		_first = true

	if not _dragging:
		_idle += delta
		if _idle > RECENTER_DELAY:
			var k := clampf(delta * 3.0, 0.0, 1.0)
			_yaw = lerp_angle(_yaw, 0.0, k)
			_pitch = lerpf(_pitch, 0.0, k)

	var t := target.global_transform
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	if view == View.COCKPIT:
		global_transform = Transform3D(t.basis * look, t * COCKPIT_EYE)
		return

	# smoothed follow of the jet's full orientation (slerp never flips, unlike look_at with world up)
	var jet_q := t.basis.get_rotation_quaternion()
	if _first:
		_rig = jet_q
		_first = false
	else:
		if _rig.dot(jet_q) < 0.0:
			jet_q = -jet_q
		_rig = _rig.slerp(jet_q, 1.0 - exp(-FOLLOW_SHARPNESS * delta)).normalized()
	var rig := Basis(_rig) * look
	var offset: Vector3 = OFFSETS[view] * _zoom
	global_position = t.origin + rig * offset
	var focus := t.origin + rig * Vector3(0.0, 1.5, -6.0)
	look_at(focus, rig.y)
