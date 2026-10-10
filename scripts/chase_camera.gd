extends Camera3D
## Four views (V cycles): CLOSE chase, FAR chase, ORBIT (DCS-style external: follows position only, never rotates with the jet), COCKPIT.
## Hold right mouse button and drag to look / orbit around. Mouse wheel zooms the chase views.
## The chase rig follows the jet's full orientation through a smoothed quaternion,
## so rolls, loops and inverted flight never flip or snap the camera.

enum View { CLOSE, FAR, ORBIT, COCKPIT }
const VIEW_NAMES := ["CLOSE", "FAR", "ORBIT", "COCKPIT"]
const ORBIT_DISTANCE := 34.0
const OFFSETS := [Vector3(0.0, 3.2, 15.0), Vector3(0.0, 8.0, 42.0)]
const COCKPIT_EYE := Vector3(0.0, 1.18, -5.5)
const COCKPIT_PITCH := -10.0   # degrees: the default cockpit view looks a little down, over the panel (as in DCS)
const COCKPIT_ZOOM := Vector2(0.16, 1.5)  # cockpit field of view range, times the FOV setting (DCS-style zoom)
const INSPECT_ZOOM := 0.2       # double-click a dial: field of view factor while inspecting it
const INSPECT_RATE := 6.0       # how quickly the head turns and the view zooms to it (higher = faster)
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
var _ck_zoom := 1.0             # cockpit zoom (field of view factor)
var _base_fov := 70.0
var _head := Vector3.ZERO       # (unused: the head's motion is _hm's)
var _hm := preload("res://scripts/camera/head_motion.gd").new()      # head movement under G and seat vibration
var _tracker := preload("res://scripts/camera/head_tracker.gd").new() # OpenTrack head tracking
var _dragging := false
var _idle := 0.0
var _rig := Quaternion.IDENTITY
var _first := true
var _shake_t := 0.0
var _floor := -INF              # smoothed surface height under the lens
var _reach := 1.0               # 0..1 fraction of the boom left after a hill pulls the camera in
var _ck_eye := Vector3.ZERO     # cockpit eye point (aircraft space) for this frame, head sag included
var _ck_look := Basis.IDENTITY  # cockpit head direction (aircraft space)
var _ck_eye_steady := Vector3.ZERO     # the same without the body's motion and the vibration (the torch's hand)
var _ck_look_steady := Basis.IDENTITY
var _seat_eye := Vector3.ZERO   # design eye point for the seat (aircraft space); the head moves around it
var _glide := false             # head animating to a target (double-click inspect, reset)
var _glide_to := Vector3.ZERO   # yaw, pitch, zoom to glide to
var _inspecting := false
var _glide_t := 0.0             # seconds the current glide has run (it always ends within 2 s)
var _before := Vector3.ZERO     # yaw, pitch, zoom before inspecting, to glide back to
## Draw distance from the graphics settings. High up the horizon is far beyond it (about 400 km at
## 45,000 ft), so the far plane stretches with altitude and the sea and cloud deck reach the horizon.
var base_far := 60000.0


func _ready() -> void:
	_base_fov = float(Settings.get_value("display/fov"))
	fov = _base_fov
	Settings.changed.connect(func(k, v):
		if k == "display/fov":
			_base_fov = float(v)
			if view != View.COCKPIT:
				fov = _base_fov)
	near = 0.05
	far = base_far
	current = true
	_apply_head_settings()
	Settings.changed.connect(func(k, _v):
		if String(k).begins_with("cockpit/") or String(k).begins_with("controls/head"):
			_apply_head_settings())
	# placed every rendered frame (_process), so the Doppler effect tracks it per frame too
	doppler_tracking = Camera3D.DOPPLER_TRACKING_IDLE_STEP
	process_physics_priority = 10
	# every view places the camera itself each rendered frame from the jet's interpolated transform (see _process);
	# the engine's own interpolation of the camera would only add a step of lag and, with mouse look applied per
	# physics tick, uneven motion while panning
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if view == View.COCKPIT:
				_wheel_takes_over()
				_ck_zoom = clampf(_ck_zoom * 0.9, COCKPIT_ZOOM.x, COCKPIT_ZOOM.y)
			else:
				_zoom = clampf(_zoom * 0.9, 0.4, 3.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if view == View.COCKPIT:
				_wheel_takes_over()
				_ck_zoom = clampf(_ck_zoom * 1.1, COCKPIT_ZOOM.x, COCKPIT_ZOOM.y)
			else:
				_zoom = clampf(_zoom * 1.1, 0.4, 3.0)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE and view == View.COCKPIT:
			# back to the default view: straight ahead, normal zoom
			_inspecting = false
			_glide_start(0.0, deg_to_rad(COCKPIT_PITCH), 1.0)
		elif mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT and view == View.COCKPIT:
			if _inspecting:
				# second double-click: back to where you were looking
				_inspecting = false
				_glide_start(_before.x, _before.y, _before.z)
			else:
				_inspect(mb.position)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_glide = false
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


var _origin_moved := false


## The floating origin moved during this physics tick (scripts/main.gd).
func origin_moved() -> void:
	_origin_moved = true


func _physics_process(delta: float) -> void:
	_physics_step(delta)
	# (the floating origin: the camera is placed from the jet's interpolated transform every frame, which the jet
	# resets on a shift, so there is nothing of the old frame to carry over)
	_origin_moved = false


func _apply_head_settings() -> void:
	_hm.amount = [0.0, 0.5, 1.0][clampi(int(Settings.get_value("cockpit/head_motion")), 0, 2)]
	_hm.shake_amount = [0.0, 0.5, 1.0][clampi(int(Settings.get_value("cockpit/shake")), 0, 2)]
	_tracker.configure(bool(Settings.get_value("controls/head_tracking")), int(Settings.get_value("controls/head_tracking_port")))


func _physics_step(delta: float) -> void:
	if target == null:
		return
	# the head and the seat's vibration follow your own jet's simulation, every step (in any view, so switching
	# into the cockpit finds the head already where it should be)
	if target.get("cockpit") != null and "fm" in target:
		_hm.physics_step(delta, target.fm)
	far = clampf(maxf(base_far, (global_position.y - maxf(WorldData.sea_level, 0.0)) * 32.0), base_far, 450000.0)
	if Input.is_action_just_pressed("toggle_view"):
		view = (view + 1) % VIEW_NAMES.size()
		_glide = false
		_inspecting = false
		_yaw = 0.0
		_pitch = deg_to_rad(COCKPIT_PITCH) if view == View.COCKPIT else 0.0
		_first = true
		if view == View.ORBIT:
			# start behind the jet, level with the horizon; from here on it never turns with the jet
			var f := -target.global_transform.basis.z
			_yaw = atan2(-f.x, -f.z)
			_pitch = deg_to_rad(-12.0)

	if view != View.COCKPIT:
		return      # outside views are placed every rendered frame in _process
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	if view == View.COCKPIT:
		var eye: Vector3 = target.spec.cockpit_eye if "spec" in target and target.spec else COCKPIT_EYE
		eye.y += clampf(float(Settings.get_value("cockpit/seat_height")), -0.06, 0.06)
		# the eye is fixed in the seat: no head sag or bob. Even a millimetre of eye motion per frame moves
		# the panel 0.7 m away by a pixel or two, and with G noise from turbulence that reads as constant vibration.
		_head = Vector3.ZERO
		near = 0.02
		if not _glide:
			fov = lerpf(fov, _base_fov * _ck_zoom, 1.0 - exp(-12.0 * delta))
		# the transform itself is set every rendered frame in _process, from the jet's interpolated transform
		_seat_eye = eye + _head
		_ck_look = look
		_ck_eye = _seat_eye + head_offset(_yaw, _pitch)
		_place_cockpit()


## Outside views, every rendered frame: from the jet's interpolated transform (what is drawn this frame), with the
## mouse look as it is right now, so dragging the view is as smooth as the display.
func _place_outside(delta: float) -> void:
	# chase views drift back behind the jet; in the cockpit your head stays where you put it
	if not _dragging and view != View.ORBIT:
		_idle += delta
		if _idle > RECENTER_DELAY:
			var k := 1.0 - exp(-3.0 * delta)
			_yaw = lerp_angle(_yaw, 0.0, k)
			_pitch = lerpf(_pitch, 0.0, k)
	var t: Transform3D = target.get_global_transform_interpolated() if target.is_physics_interpolated_and_enabled() else target.global_transform
	t.basis = t.basis.orthonormalized()
	var look := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	near = 0.05
	fov = _base_fov
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


## Double-click anything in the cockpit: the head turns to it and the view zooms right in, eased.
## The clicked pixel's ray, taken into aircraft space, gives the yaw and pitch that centre it.
func _inspect(screen_pos: Vector2) -> void:
	if target == null:
		return
	var ray := project_ray_normal(screen_pos)
	var tb: Basis = target.get_global_transform_interpolated().basis if target.is_physics_interpolated_and_enabled() else target.global_basis
	var l := tb.orthonormalized().inverse() * ray
	var yaw := clampf(atan2(-l.x, -l.z), deg_to_rad(-160.0), deg_to_rad(160.0))
	var pitch := clampf(asin(clampf(l.y, -1.0, 1.0)), deg_to_rad(-60.0), deg_to_rad(85.0))
	_before = Vector3(_yaw, _pitch, _ck_zoom)
	_inspecting = true
	_glide_start(yaw, pitch, INSPECT_ZOOM)


func _glide_start(yaw: float, pitch: float, zoom: float) -> void:
	_glide_to = Vector3(yaw, pitch, clampf(zoom, COCKPIT_ZOOM.x, COCKPIT_ZOOM.y))
	_glide = true
	_glide_t = 0.0


## The mouse wheel always wins: it stops any zoom glide in progress (which would otherwise keep pulling the
## zoom back to its target) and ends the double-click inspection, so the wheel zooms freely from where you are.
func _wheel_takes_over() -> void:
	_glide = false
	_inspecting = false
	fov = clampf(fov, _base_fov * COCKPIT_ZOOM.x, _base_fov * COCKPIT_ZOOM.y)


func _step_glide(delta: float) -> void:
	if not _glide:
		return
	var k := 1.0 - exp(-INSPECT_RATE * delta)
	_glide_t += delta
	_yaw = lerp_angle(_yaw, _glide_to.x, k)
	_pitch = lerpf(_pitch, _glide_to.y, k)
	# zoom in log space so the zoom speed feels even from wide to narrow
	_ck_zoom = exp(lerpf(log(_ck_zoom), log(_glide_to.z), k))
	var arrived := absf(angle_difference(_yaw, _glide_to.x)) < 0.0005 and absf(_pitch - _glide_to.y) < 0.0005 and absf(_ck_zoom - _glide_to.z) < 0.001
	if arrived or _glide_t > 2.0:
		_yaw = _glide_to.x
		_pitch = _glide_to.y
		_ck_zoom = _glide_to.z
		_glide = false


## Cockpit camera: welded to the jet. The cockpit mesh is drawn at the jet's physics-interpolated transform,
## so the eye is placed from exactly the same interpolated transform every rendered frame. Any other source
## (the raw physics transform, or the camera interpolating on its own) differs from the cockpit by a fraction
## of a physics step, and at flying speed that is centimetres of jitter between the panel and your eye,
## which smears every needle and label (and temporal upscalers turn it into ghost trails).
func _process(delta: float) -> void:
	_shake_t += delta
	if target != null and view != View.COCKPIT:
		_place_outside(delta)
		return
	if view == View.COCKPIT and target != null:
		# head direction and zoom are updated per rendered frame too, so looking around and the
		# double-click zoom glide are as smooth as the display allows
		_step_glide(delta)
		# where you look: the mouse look, plus the head tracker's pose when one is sending
		var yaw := _yaw
		var pitch := _pitch
		var roll := 0.0
		var lean := Vector3.ZERO
		_tracker.poll()
		if _tracker.active():
			yaw += deg_to_rad(_tracker.yaw)
			pitch = clampf(pitch + deg_to_rad(_tracker.pitch), deg_to_rad(-89.0), deg_to_rad(89.0))
			roll = deg_to_rad(_tracker.roll)
			lean = _tracker.pos
		# the body: the head moving with the jet under G, and the airframe's vibration through the seat
		var hm: Array = _hm.sample(Engine.get_physics_interpolation_fraction(), _shake_t)
		_ck_look_steady = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, -roll)
		_ck_eye_steady = _seat_eye + head_offset(yaw, pitch) + lean
		_ck_look = Basis.from_euler(hm[1] as Vector3) * _ck_look_steady
		_ck_eye = _ck_eye_steady + (hm[0] as Vector3)
		if _glide:
			fov = _base_fov * _ck_zoom
		_place_cockpit()


## Where the eyes go when the pilot looks around (aircraft space, metres from the design eye point), like a real
## head and body rather than a camera spinning on the spot (DCS-style):
##   - the head turns on the neck, which sits below and behind the eyes, so looking down brings the eyes forward
##     and down, looking aside moves them a few centimetres that way
##   - looking well to the side the body twists and leans: the head moves out toward that side and forward,
##     and looking back it also rises, so you see past the seat's headrest to the consoles behind and the wingtip
##   - looking down at the consoles or the panel the pilot leans forward a little
## A pure function of the view angles: smooth, and the eye stays perfectly still whenever the view does.
static func head_offset(yaw: float, pitch: float) -> Vector3:
	var look := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
	var neck_to_eye := Vector3(0.0, 0.11, -0.07)
	var off := look * neck_to_eye - neck_to_eye
	var ay := absf(rad_to_deg(yaw))
	var side := signf(-yaw)                     # + yaw turns left: lean to the left (-x)
	var twist := smoothstep(35.0, 140.0, ay)
	off.x += side * 0.15 * twist
	off.z += -0.05 * twist + 0.04 * smoothstep(120.0, 160.0, ay)
	off.y += 0.035 * smoothstep(80.0, 150.0, ay)
	var down := smoothstep(20.0, 60.0, -rad_to_deg(pitch))
	off.z += -0.07 * down * (1.0 - 0.6 * twist)
	off.y += -0.02 * down
	off.x = clampf(off.x, -0.2, 0.2)
	return off


func _place_cockpit() -> void:
	var t: Transform3D = target.get_global_transform_interpolated() if target.is_physics_interpolated_and_enabled() else target.global_transform
	global_transform = Transform3D(t.basis.orthonormalized() * _ck_look, t * _ck_eye)
	# the eye's own motion (head under G, seat vibration, head tracking) is in _ck_eye / _ck_look: smooth by
	# construction (scripts/camera/head_motion.gd), and the cockpit is drawn from the same numbers


## Keeps the lens out of the ground. Instead of clipping, the camera slides along the surface:
## the boom keeps its horizontal direction and only its height is cushioned, so dragging the view
## downward glides the camera across the ground and in under the jet. A hill between the jet and
## the camera pulls the boom in (fast) and lets it back out (slowly) once the line is clear.
func _keep_above_ground(pivot: Vector3, wanted: Vector3, delta: float) -> Vector3:
	if not WorldData.loaded:
		return wanted
	# first settle the wanted point onto the surface, so a boom aimed into the ground glides instead of shrinking
	var w := wanted
	w.y = maxf(w.y, WorldData.scene_ground_height(w.x, w.z) + GROUND_CLEARANCE)
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
		if q.y < WorldData.scene_ground_height(q.x, q.z) - 0.5:
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
	var g := WorldData.scene_ground_height(p.x, p.z)
	for o in [Vector2(PROBE_RADIUS, 0.0), Vector2(-PROBE_RADIUS, 0.0), Vector2(0.0, PROBE_RADIUS), Vector2(0.0, -PROBE_RADIUS)]:
		g = maxf(g, WorldData.scene_ground_height(p.x + o.x, p.z + o.y))
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
	# a felt rumble, not a strobe: low enough in frequency that the panel stays readable
	var amp := 0.0045 * b * scale
	rotate_object_local(Vector3.RIGHT, sin(_shake_t * 19.0) * amp + sin(_shake_t * 11.0) * amp * 0.6)
	rotate_object_local(Vector3.UP, sin(_shake_t * 15.0) * amp * 0.7)
