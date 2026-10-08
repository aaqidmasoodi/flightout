extends Camera3D
## Four views (V cycles): CLOSE chase, FAR chase, ORBIT (DCS-style external: follows position only, never rotates with the jet), COCKPIT.
## Hold right mouse button and drag to look / orbit around. Mouse wheel zooms the chase views.
## The chase rig follows the jet's full orientation through a smoothed quaternion,
## so rolls, loops and inverted flight never flip or snap the camera.

enum View { CLOSE, FAR, ORBIT, COCKPIT }
const VIEW_NAMES := ["CLOSE", "FAR", "ORBIT", "COCKPIT"]
const ORBIT_DISTANCE := 34.0
const OFFSETS := [Vector3(0.0, 3.2, 15.0), Vector3(0.0, 8.0, 42.0)]
const COCKPIT_EYE := Vector3(0.0, 1.36, -5.0)
const SENSITIVITY := 0.005
const RECENTER_DELAY := 1.0
const FOLLOW_SHARPNESS := 5.0   # higher = camera rotates with the jet more tightly
const GROUND_CLEARANCE := 0.9   # metres the lens keeps above the terrain, runway or sea
const GROUND_SOFTNESS := 1.6    # width of the soft cushion, so the camera eases onto the surface instead of hitting a wall
const PROBE_RADIUS := 2.5       # extra height samples around the lens so slopes and grid edges never slice the near plane
const OCCLUSION_STEPS := 10     # samples along the jet to camera line for hills in the way
const STRUCTURE_LAYER := 2      # physics layer bit of buildings the camera must not pass through

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
var _shake_t := 0.0
var _floor := -INF              # smoothed surface height under the lens
var _reach := 1.0               # 0..1 fraction of the boom left after a hill pulls the camera in
## Draw distance from the graphics settings. High up the horizon is far beyond it (about 400 km at
## 45,000 ft), so the far plane stretches with altitude and the sea and cloud deck reach the horizon.
var base_far := 60000.0


func _ready() -> void:
	fov = float(Settings.get_value("display/fov"))
	Settings.changed.connect(func(k, v):
		if k == "display/fov":
			fov = float(v))
	near = 0.05
	far = base_far
	current = true
	doppler_tracking = Camera3D.DOPPLER_TRACKING_PHYSICS_STEP
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
		var sens := SENSITIVITY * float(Settings.get_value("controls/mouse_sensitivity"))
		_yaw -= mm.relative.x * sens
		_pitch -= mm.relative.y * sens
		_idle = 0.0
		if view == View.ORBIT:
			_pitch = clampf(_pitch, deg_to_rad(-85.0), deg_to_rad(85.0))
		elif view == View.COCKPIT:
			_yaw = clampf(_yaw, deg_to_rad(-160.0), deg_to_rad(160.0))
			_pitch = clampf(_pitch, deg_to_rad(-60.0), deg_to_rad(85.0))
		else:
			_yaw = wrapf(_yaw, -PI, PI)
			_pitch = clampf(_pitch, deg_to_rad(-80.0), deg_to_rad(80.0))


func _physics_process(delta: float) -> void:
	if target == null:
		return
	far = clampf(maxf(base_far, (global_position.y - WorldData.sea_level) * 32.0), base_far, 450000.0)
	_shake_t += delta
	if Input.is_action_just_pressed("toggle_view"):
		view = (view + 1) % VIEW_NAMES.size()
		_yaw = 0.0
		_pitch = 0.0
		_first = true
		if view == View.ORBIT:
			# start behind the jet, level with the horizon; from here on it never turns with the jet
			var f := -target.global_transform.basis.z
			_yaw = atan2(-f.x, -f.z)
			_pitch = deg_to_rad(-12.0)

	if not _dragging and view != View.ORBIT:
		_idle += delta
		if _idle > RECENTER_DELAY:
			var k := clampf(delta * 3.0, 0.0, 1.0)
			_yaw = lerp_angle(_yaw, 0.0, k)
			_pitch = lerpf(_pitch, 0.0, k)

	var t := target.global_transform
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	if view == View.COCKPIT:
		var eye: Vector3 = target.spec.cockpit_eye if "spec" in target and target.spec else COCKPIT_EYE
		global_transform = Transform3D(t.basis * look, t * eye)
		_apply_buffet(1.0)
		return
	if view == View.ORBIT:
		# world-aligned: position follows the jet, orientation is yours (horizon always level)
		var orbit_offset := look * Vector3(0.0, 0.0, ORBIT_DISTANCE * _zoom)
		global_position = _keep_above_ground(t.origin, t.origin + orbit_offset, delta)
		look_at(t.origin, Vector3.UP)
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
	global_position = _keep_above_ground(t.origin, t.origin + rig * offset, delta)
	var focus := t.origin + rig * Vector3(0.0, 1.5, -6.0)
	var up := rig.y
	if absf((focus - global_position).normalized().dot(up)) > 0.98:
		up = Vector3.UP if absf((focus - global_position).normalized().y) < 0.98 else rig.z
	look_at(focus, up)
	_apply_buffet(0.5)


## Keeps the lens out of the ground. Instead of clipping, the camera slides along the surface:
## the boom keeps its horizontal direction and only its height is cushioned, so dragging the view
## downward glides the camera across the ground and in under the jet. A hill between the jet and
## the camera pulls the boom in (fast) and lets it back out (slowly) once the line is clear.
func _keep_above_ground(pivot: Vector3, wanted: Vector3, delta: float) -> Vector3:
	if not WorldData.loaded:
		return wanted
	# first settle the wanted point onto the surface, so a boom aimed into the ground glides instead of shrinking
	var w := wanted
	w.y = maxf(w.y, WorldData.ground_height(w.x, w.z) + GROUND_CLEARANCE)
	var boom := w - pivot
	var length := boom.length()
	if length < 0.01:
		return wanted

	# line of sight: march from the jet outward, find the first point that cuts through a hill
	var clear := 1.0
	for i in range(1, OCCLUSION_STEPS):
		var f := float(i) / OCCLUSION_STEPS
		if f * length < 4.0:
			continue
		var q := pivot + boom * f
		if q.y < WorldData.ground_height(q.x, q.z) - 0.5:
			clear = maxf(float(i - 1) / OCCLUSION_STEPS, 4.0 / length)
			break
	# buildings (shelters) on physics layer 2: the boom stops just short of the wall
	var space := get_world_3d().direct_space_state
	if space:
		var ray := PhysicsRayQueryParameters3D.create(pivot, w, STRUCTURE_LAYER)
		ray.hit_back_faces = true
		var hit := space.intersect_ray(ray)
		if not hit.is_empty():
			clear = minf(clear, maxf(((hit.position as Vector3).distance_to(pivot) - 0.8) / length, 0.0))
	var rate := 12.0 if clear < _reach else 1.5
	_reach = clampf(lerpf(_reach, clear, 1.0 - exp(-rate * delta)), 0.0, 1.0)
	var p := pivot + boom * _reach

	# surface under the lens, sampled across a small footprint
	var g := WorldData.ground_height(p.x, p.z)
	for o in [Vector2(PROBE_RADIUS, 0.0), Vector2(-PROBE_RADIUS, 0.0), Vector2(0.0, PROBE_RADIUS), Vector2(0.0, -PROBE_RADIUS)]:
		g = maxf(g, WorldData.ground_height(p.x + o.x, p.z + o.y))
	# rise instantly, settle gently, so passing over a ridge never pops the view down
	if g > _floor or _floor == -INF or absf(g - _floor) > 200.0:
		_floor = g
	else:
		_floor = lerpf(_floor, g, 1.0 - exp(-6.0 * delta))

	# soft floor: identical to the wanted height well above ground, eases onto the cushion near it
	var base := _floor + GROUND_CLEARANCE
	var x := (p.y - base) / GROUND_SOFTNESS
	var lift := GROUND_SOFTNESS * (x if x > 20.0 else log(1.0 + exp(x)))
	p.y = base + lift
	return p


## Airframe buffet near the stall: a fast, small shake of the view (stronger in the cockpit).
func _apply_buffet(scale: float) -> void:
	var b: float = target.buffet if "buffet" in target else 0.0
	if b <= 0.01:
		return
	var amp := 0.006 * b * scale
	rotate_object_local(Vector3.RIGHT, sin(_shake_t * 61.0) * amp + sin(_shake_t * 37.0) * amp * 0.6)
	rotate_object_local(Vector3.UP, sin(_shake_t * 53.0) * amp * 0.7)
