extends Node
## Rear-view mirrors on the canopy's front arch, as on the Su-27: a wide one across the top of the arch and a long
## narrow one along each upper side, mounted on the arch itself (on its face towards the pilot, covering the frame),
## built at run time from the arch's shape (they replace the hand-hold pads the cockpit model has there).
##
## Each mirror shows a fixed, set-up view behind the jet, as a pilot adjusts his mirrors before flight: the top one
## straight back over the spine to both fins, each side one back along its own side, from the fin out to the wingtip.
## The pictures are taken from the design eye point and do not move when you look around (only when the jet moves),
## and they are slightly convex (wider than a flat mirror of that size would show) so the wingtips fit in. Only the
## world and the jet's outside are reflected, never the cockpit interior. The pictures are re-rendered in turn, 12
## times a second each, and only while you are in the cockpit, the mirrors are unfolded and the mirror is on screen.
##
## Folding: like the HUD sun shade, each mirror swings up on a hinge along its outer edge, out of the way against the
## canopy (key: toggle_mirrors; the graphics setting decides whether they start unfolded, folded on Low and Medium).
## Folded, nothing is rendered for them at all.

const GLASS_SHADER := preload("res://shaders/cockpit/mirror_glass.gdshader")
const PIXELS_PER_M := 1100.0                 # reflection picture resolution (a 22 cm mirror: 242 pixels)
const RATE_HZ := 12.0                        # per mirror
const FAR := 5000.0
# the arch's face towards the pilot (aircraft space, z = ARCH_FACE): its band's inner and outer edge, as distances
# from the arch's centre line (x = 0, y = ARCH_Y), by angle from the top (measured from the cockpit model)
const ARCH_Y := 0.9
const ARCH_FACE := -6.258
const ARCH_R := [[0.0, 0.375, 0.462], [12.0, 0.376, 0.467], [24.0, 0.386, 0.478], [36.0, 0.395, 0.488],
	[48.0, 0.409, 0.504], [60.0, 0.425, 0.518], [72.0, 0.445, 0.535], [84.0, 0.47, 0.569]]
const STANDOFF := 0.02                       # glass centre in front of the arch's face (the housing fills the gap)
const CORNER := 0.014                        # rounded corners of the glass (m); the housing's are a bezel wider
const BEZEL := 0.006
# mirrors: angle from the top of the arch (degrees, + to the right), glass width and height (m), where it looks
# (aircraft space: forward -Z, right +X, up +Y) and how wide a view it shows (degrees, across).
# From the eye (0, 1.18, -5.5) the fin tips are about 13 degrees out and 16 up, the wingtips 49 out and 8 down.
const MIRRORS := [
	[0.0, 0.26, 0.075, Vector3(0.0, 0.09, 1.0), 46.0],     # both fins and the spine, the sky above and behind
	[-62.0, 0.22, 0.07, Vector3(-0.70, -0.05, 1.0), 60.0], # left: from the left fin out to the left wingtip
	[62.0, 0.22, 0.07, Vector3(0.70, -0.05, 1.0), 60.0],   # right: from the right fin out to the right wingtip
]
const NEAR := 0.35                           # clears the pilot's own head and shoulders
const FOLD_DEG := 95.0                       # how far a mirror swings up when folded
const FOLD_TIME := 0.6                       # seconds to fold or unfold

var ac: Node3D
var _mirrors: Array = []                     # {glass, viewport, camera, material, centre, x, y, n (canopy-root space), size}
var _root: Node3D                            # the canopy's root: the mirrors move with the canopy
var _acc := 0.0
var _turn := 0
var _on := true
var _dev_dir := ""                           # development: --dev-mirror-shot=<dir> saves each mirror's picture
var _dev_t := 0.0
var _eye := Vector3.ZERO                     # design eye point (aircraft space): where the pictures are taken from
var _fold := 0.0                             # 0 unfolded .. 1 folded (shown)
var _fold_shown := -1.0


## Middle of the arch's band at an angle from the top (metres from its centre line).
static func _arch_r(deg: float) -> float:
	var a := absf(deg)
	for i in ARCH_R.size() - 1:
		if a <= float(ARCH_R[i + 1][0]):
			var k := (a - float(ARCH_R[i][0])) / (float(ARCH_R[i + 1][0]) - float(ARCH_R[i][0]))
			var lo := lerpf(float(ARCH_R[i][1]), float(ARCH_R[i + 1][1]), k)
			var hi := lerpf(float(ARCH_R[i][2]), float(ARCH_R[i + 1][2]), k)
			return (lo + hi) * 0.5
	return (float(ARCH_R[-1][1]) + float(ARCH_R[-1][2])) * 0.5


## pads: the canopy's hand-hold pads (hidden: the mirrors take their place). eye: design eye point in aircraft space.
## material_of: name -> cockpit material. Returns the meshes made, for the cockpit to draw with its precise transform.
func build(aircraft: Node3D, root: Node3D, pads: MeshInstance3D, eye: Vector3, material_of: Callable, layer: int) -> Array:
	ac = aircraft
	_root = root
	_eye = eye
	var made: Array = []
	var to_root := _space(_root).affine_inverse()
	for spec in MIRRORS:
		var deg: float = spec[0]
		var size := Vector2(spec[1], spec[2])
		var th := deg_to_rad(deg)
		var radial := Vector3(sin(th), cos(th), 0.0)          # outwards from the arch's centre line
		var tangent := Vector3(cos(th), -sin(th), 0.0)        # along the arch, left to right
		# on the arch's face, in the middle of its band (the glass covers the frame there)
		var on_arch := Vector3(0.0, ARCH_Y, ARCH_FACE) + radial * _arch_r(deg)
		# glass normal: mostly towards the eye (so you see the whole glass), turned a little towards what it shows
		var look := (spec[3] as Vector3).normalized()
		var n := ((eye - on_arch).normalized() * 3.0 + look).normalized()
		var mount := on_arch + n * STANDOFF
		var x := (tangent - n * tangent.dot(n)).normalized()
		var y := n.cross(x).normalized()
		if y.dot(radial) < 0.0:
			x = -x
			y = -y
		var basis := Basis(x, y, n)
		# in the canopy root's space, so the mirrors move with the canopy
		var rb := to_root.basis * basis
		var rc := to_root * mount
		# the picture's "up" is the glass's own up (as in a real mirror, a tilted mirror shows a tilted slice)
		var m := {"centre": rc, "size": size, "look": look, "up": y, "fov": float(spec[4]), "basis": rb}
		# housing: a dark bezel around and behind the glass, deep enough to reach back to the arch at both ends
		var frame := MeshInstance3D.new()
		var depth := STANDOFF + 0.022
		frame.mesh = _rounded_box(size.x + BEZEL * 2.0, size.y + BEZEL * 2.0, depth, CORNER + BEZEL)
		# the hinge: along the housing's outer edge, halfway back; the mirror swings up about it
		var hinge := Vector3(0.0, size.y * 0.5 + BEZEL, -depth * 0.5)
		var pivot := Node3D.new()
		pivot.transform = Transform3D(rb, rc + rb * hinge)
		_root.add_child(pivot)
		m.pivot = pivot
		frame.transform = Transform3D(Basis(), Vector3(0.0, 0.0, -(depth * 0.5 + 0.0005)) - hinge)
		frame.set_surface_override_material(0, material_of.call("CP_PaintDark"))
		var glass := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = size
		glass.mesh = q
		glass.transform = Transform3D(Basis(), Vector3(0.0, 0.0, 0.0005) - hinge)
		for mi in [frame, glass]:
			(mi as MeshInstance3D).layers = layer
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			pivot.add_child(mi)
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
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.fov = float(spec[4])
		cam.near = NEAR
		cam.far = FAR
		cam.cull_mask = 0xFFFFF & ~layer           # the cockpit interior is drawn for the main view only
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		cam.compositor = Compositor.new()          # no volumetric clouds in the mirrors: they would cost a full pass
		vp.add_child(cam)
		cam.current = true
		var mat := ShaderMaterial.new()
		mat.shader = GLASS_SHADER
		mat.set_shader_parameter("reflection", vp.get_texture())
		mat.set_shader_parameter("size_m", size)
		mat.set_shader_parameter("corner_m", CORNER)
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
	# the setting decides how they start (and folds or unfolds them when it is changed); the key does it in flight
	ac.set("mirrors_folded", not bool(Settings.get_value("graphics/mirrors")))
	_fold = 1.0 if ac.get("mirrors_folded") else 0.0
	_show_fold()
	Settings.changed.connect(func(k, v):
		if k == "graphics/mirrors" and is_instance_valid(ac):
			ac.set("mirrors_folded", not bool(v)))
	return made


## The mirrors swung up about their hinges by the fold amount (eased, like the sun shade).
func _show_fold() -> void:
	if _fold == _fold_shown:
		return
	_fold_shown = _fold
	var a := deg_to_rad(FOLD_DEG) * smoothstep(0.0, 1.0, _fold)
	for m in _mirrors:
		var pv := m.pivot as Node3D
		pv.transform.basis = (m.basis as Basis) * Basis(Vector3.RIGHT, -a)
	var was := _on
	_on = _fold < 0.999
	if _on != was:
		for m in _mirrors:
			(m.material as ShaderMaterial).set_shader_parameter("live", _on)
			if not _on:
				(m.viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED


## Every frame from the cockpit: folds or unfolds the mirrors, and renders one mirror's picture when its turn is due.
func update(inside: bool, cam: Camera3D, delta: float) -> void:
	if _mirrors.is_empty():
		return
	var want := 1.0 if ac.get("mirrors_folded") else 0.0
	if _fold != want:
		_fold = move_toward(_fold, want, delta / FOLD_TIME)
		_show_fold()
	if not _on or not inside or cam == null:
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
			_place(m)
			(m.viewport as SubViewport).render_target_update_mode = SubViewport.UPDATE_ONCE
			return


## The mirror's camera: at the design eye point, looking where the mirror is set to look, fixed to the jet as it is
## drawn this frame (interpolated), so the picture moves only with the jet.
func _place(m: Dictionary) -> void:
	var air: Transform3D = ac.get_global_transform_interpolated() if ac.is_physics_interpolated_and_enabled() else ac.global_transform
	air.basis = air.basis.orthonormalized()
	var local := Transform3D(Basis.looking_at(m.look as Vector3, m.up as Vector3), _eye)
	(m.camera as Camera3D).global_transform = air * local


## A box with rounded corners (seen from the front), centred, its front face towards +Z (clockwise winding: Godot's
## front faces).
static func _rounded_box(w: float, h: float, d: float, r: float) -> ArrayMesh:
	r = minf(r, minf(w, h) * 0.5)
	var ring := PackedVector2Array()
	var corners := [Vector2(w * 0.5 - r, h * 0.5 - r), Vector2(-w * 0.5 + r, h * 0.5 - r),
		Vector2(-w * 0.5 + r, -h * 0.5 + r), Vector2(w * 0.5 - r, -h * 0.5 + r)]
	const SEG := 6
	for c in 4:
		for k in SEG + 1:
			var a := (float(c) + float(k) / SEG) * PI * 0.5
			ring.append((corners[c] as Vector2) + Vector2(cos(a), sin(a)) * r)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := ring.size()
	var zf := d * 0.5
	var zb := -d * 0.5
	for i in n:
		var a2 := ring[i]
		var b2 := ring[(i + 1) % n]
		# front and back caps (fans from the centre)
		st.set_normal(Vector3(0, 0, 1))
		st.add_vertex(Vector3(0, 0, zf)); st.add_vertex(Vector3(b2.x, b2.y, zf)); st.add_vertex(Vector3(a2.x, a2.y, zf))
		st.set_normal(Vector3(0, 0, -1))
		st.add_vertex(Vector3(0, 0, zb)); st.add_vertex(Vector3(a2.x, a2.y, zb)); st.add_vertex(Vector3(b2.x, b2.y, zb))
		# side
		var e := (b2 - a2)
		var sn := Vector3(e.y, -e.x, 0.0).normalized()
		st.set_normal(sn)
		st.add_vertex(Vector3(a2.x, a2.y, zf)); st.add_vertex(Vector3(b2.x, b2.y, zb)); st.add_vertex(Vector3(a2.x, a2.y, zb))
		st.add_vertex(Vector3(a2.x, a2.y, zf)); st.add_vertex(Vector3(b2.x, b2.y, zf)); st.add_vertex(Vector3(b2.x, b2.y, zb))
	return st.commit()


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
