extends Node
## Rear-view mirrors on the canopy's front arch, as on the Su-27: a wide one under the top of the arch and a long
## narrow one along each upper side, sitting snug against the arch's inner face, built at run time from the arch's
## shape (they replace the hand-hold pads the cockpit model has there).
##
## Each mirror is angled so that, from the design eye point, it shows the view behind the jet (the top one straight
## back and a little up, the side ones back and a little outboard). Its picture is a true planar reflection: a camera
## at your eye reflected in the mirror's plane, looking through exactly the mirror's outline (an off-axis frustum
## whose near plane is the glass), so the image lines up with the frame and shifts as your head moves, like a real
## mirror. The mirrors' pictures are re-rendered in turn, 12 times a second each, and only while you are in the
## cockpit, the mirrors are switched on and the mirror is on screen.

const GLASS_SHADER := preload("res://shaders/cockpit/mirror_glass.gdshader")
const PIXELS_PER_M := 1100.0                 # reflection picture resolution (a 22 cm mirror: 242 pixels)
const RATE_HZ := 12.0                        # per mirror
const FAR := 5000.0
# the arch's inner face (aircraft space): distance from its centre line (x = 0, y = ARCH_Y) by angle from the top
const ARCH_Y := 0.9
const ARCH_Z := -6.30
const ARCH_R := [[0.0, 0.375], [12.0, 0.376], [24.0, 0.386], [36.0, 0.395], [48.0, 0.409], [60.0, 0.424],
	[72.0, 0.445], [84.0, 0.47]]
# mirrors: angle from the top of the arch (degrees, + to the right), glass width and height (m), where it looks
# (aircraft space: forward -Z, right +X, up +Y)
const MIRRORS := [
	[0.0, 0.24, 0.055, Vector3(0.0, 0.12, 1.0)],
	[-52.0, 0.22, 0.05, Vector3(-0.12, 0.08, 1.0)],
	[52.0, 0.22, 0.05, Vector3(0.12, 0.08, 1.0)],
]

var ac: Node3D
var _mirrors: Array = []                     # {glass, viewport, camera, material, centre, x, y, n (canopy-root space), size}
var _root: Node3D                            # the canopy's root: the mirrors move with the canopy
var _acc := 0.0
var _turn := 0
var _on := true
var _dev_dir := ""                           # development: --dev-mirror-shot=<dir> saves each mirror's picture
var _dev_t := 0.0


static func _arch_r(deg: float) -> float:
	var a := absf(deg)
	for i in ARCH_R.size() - 1:
		if a <= float(ARCH_R[i + 1][0]):
			var k := (a - float(ARCH_R[i][0])) / (float(ARCH_R[i + 1][0]) - float(ARCH_R[i][0]))
			return lerpf(float(ARCH_R[i][1]), float(ARCH_R[i + 1][1]), k)
	return float(ARCH_R[-1][1])


## pads: the canopy's hand-hold pads (hidden: the mirrors take their place). eye: design eye point in aircraft space.
## material_of: name -> cockpit material. Returns the meshes made, for the cockpit to draw with its precise transform.
func build(aircraft: Node3D, root: Node3D, pads: MeshInstance3D, eye: Vector3, material_of: Callable, layer: int) -> Array:
	ac = aircraft
	_root = root
	var made: Array = []
	var to_root := _space(_root).affine_inverse()
	for spec in MIRRORS:
		var deg: float = spec[0]
		var size := Vector2(spec[1], spec[2])
		var th := deg_to_rad(deg)
		var radial := Vector3(sin(th), cos(th), 0.0)          # outwards from the arch's centre line
		var tangent := Vector3(cos(th), -sin(th), 0.0)        # along the arch, left to right
		var on_arch := Vector3(0.0, ARCH_Y, ARCH_Z) + radial * _arch_r(deg)
		# a flat glass under a curved arch: its ends touch the arch, its middle sits the arch's sagitta below it
		var half := size.x * 0.5 / _arch_r(deg)
		var sag := _arch_r(deg) * (1.0 - cos(half))
		var mount := on_arch - radial * (size.y * 0.5 + 0.007 + sag)
		# glass normal: halfway between "towards the eye" and "towards what it should show"
		var look := (spec[3] as Vector3).normalized()
		var n := ((eye - mount).normalized() + look).normalized()
		var x := (tangent - n * tangent.dot(n)).normalized()
		var y := n.cross(x).normalized()
		if y.dot(radial) < 0.0:
			x = -x
			y = -y
		var basis := Basis(x, y, n)
		# in the canopy root's space, so the mirrors move with the canopy
		var rb := to_root.basis * basis
		var rc := to_root * mount
		var m := {"centre": rc, "x": rb.x.normalized(), "y": rb.y.normalized(), "n": rb.z.normalized(), "size": size}
		# frame: a thin dark bezel behind the glass
		var frame := MeshInstance3D.new()
		var fb := BoxMesh.new()
		fb.size = Vector3(size.x + 0.012, size.y + 0.012, 0.012)
		frame.mesh = fb
		frame.transform = Transform3D(rb, rc - rb.z.normalized() * 0.0065)
		frame.set_surface_override_material(0, material_of.call("CP_PaintDark"))
		var glass := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = size
		glass.mesh = q
		glass.transform = Transform3D(rb, rc + rb.z.normalized() * 0.0005)
		for mi in [frame, glass]:
			(mi as MeshInstance3D).layers = layer
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_root.add_child(mi)
			made.append(mi)
		# the reflection's own small view of the world
		var vp := SubViewport.new()
		vp.size = Vector2i(maxi(roundi(size.x * PIXELS_PER_M), 16), maxi(roundi(size.y * PIXELS_PER_M), 16))
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.positional_shadow_atlas_size = 0
		vp.audio_listener_enable_3d = false
		add_child(vp)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_FRUSTUM
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.far = FAR
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		cam.compositor = Compositor.new()          # no volumetric clouds in the mirrors: they would cost a full pass
		vp.add_child(cam)
		cam.current = true
		var mat := ShaderMaterial.new()
		mat.shader = GLASS_SHADER
		mat.set_shader_parameter("reflection", vp.get_texture())
		mat.render_priority = 1
		glass.set_surface_override_material(0, mat)
		m.glass = glass
		m.viewport = vp
		m.camera = cam
		m.material = mat
		_mirrors.append(m)
	if pads:
		pads.visible = false                         # the mirrors take the hand-holds' places
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dev-mirror-shot="):
			_dev_dir = arg.trim_prefix("--dev-mirror-shot=")
	_apply_setting()
	Settings.changed.connect(func(k, _v):
		if k == "graphics/mirrors":
			_apply_setting())
	return made


func _apply_setting() -> void:
	_on = bool(Settings.get_value("graphics/mirrors"))
	for m in _mirrors:
		(m.material as ShaderMaterial).set_shader_parameter("live", _on)
		if not _on:
			(m.viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED


## Every frame from the cockpit: renders one mirror's reflection when its turn is due.
func update(inside: bool, cam: Camera3D, delta: float) -> void:
	if not _on or not inside or cam == null or _mirrors.is_empty():
		return
	if _dev_dir != "":
		_dev_t += delta
		if _dev_t > 2.8:
			for i in _mirrors.size():
				var img := ((_mirrors[i].viewport as SubViewport).get_texture()).get_image()
				if img:
					img.save_png(_dev_dir.path_join("mirror_%d.png" % i))
			_dev_dir = ""
	_acc += delta
	if _acc < 1.0 / (RATE_HZ * _mirrors.size()):
		return
	_acc = 0.0
	# take turns, skipping a mirror that is off screen (looking down at the panel, or behind you)
	for _i in _mirrors.size():
		_turn = (_turn + 1) % _mirrors.size()
		var m: Dictionary = _mirrors[_turn]
		var g := (m.glass as Node3D).global_position
		if cam.is_position_in_frustum(g) or cam.global_position.distance_to(g) < 0.12:
			_place(m, cam.global_position)
			(m.viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
			return


## The reflection camera: at the eye reflected in the glass's plane, looking square through the glass, its frustum
## cut to exactly the glass (near plane = the glass).
func _place(m: Dictionary, eye: Vector3) -> void:
	# the jet as drawn this frame (interpolated), then the glass in it: the same numbers the cockpit is drawn with
	var air: Transform3D = ac.get_global_transform_interpolated() if ac.is_physics_interpolated_and_enabled() else ac.global_transform
	air.basis = air.basis.orthonormalized()
	var r := air * _space(_root)
	var c: Vector3 = r * (m.centre as Vector3)
	var x: Vector3 = (r.basis * (m.x as Vector3)).normalized()
	var y: Vector3 = (r.basis * (m.y as Vector3)).normalized()
	var n: Vector3 = (r.basis * (m.n as Vector3)).normalized()
	var d := (eye - c).dot(n)
	if d < 0.01:
		return                                   # behind the glass (cannot happen from the seat)
	var virtual_eye := eye - n * (2.0 * d)
	var cb := Basis(-x, y, -n)                   # right-handed; the picture comes out mirrored (flipped in the shader)
	var cam := m.camera as Camera3D
	cam.global_transform = Transform3D(cb, virtual_eye)
	var o := c - virtual_eye
	cam.set_frustum((m.size as Vector2).y, Vector2(o.dot(-x), o.dot(y)), d, FAR)


## A node's transform relative to the aircraft root (small numbers only).
func _space(n: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != null and p != ac:
		var p3 := p as Node3D
		if p3:
			t = p3.transform * t
		p = p.get_parent()
	return t
