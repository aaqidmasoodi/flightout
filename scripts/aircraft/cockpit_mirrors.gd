extends Node
## Rear-view mirrors on the canopy's front arch, as on the Su-27: a wide one across the top of the arch and a long
## narrow one along each side, lower down, mounted on the arch's face towards the pilot (built at run time from the
## arch's shape; they replace the hand-hold pads the cockpit model has there).
##
## How the reflections are made (cheaply, and with real mirror optics):
## * ONE wide picture of the view behind the jet is rendered per frame, from the middle of the canopy arch looking
##   aft, and all three mirrors share it. (DCS draws its mirrors from one reverse-facing view too, but pastes that
##   view onto the glass, so the mirrors ignore your head; one extra view per mirror would cost three times as much.)
## * Each pixel of each mirror then works out where a real mirror sends your line of sight: the ray from your eye to
##   that point, reflected about the glass's normal there (slightly convex glass, as real cockpit mirrors are), and
##   looks that direction up in the shared picture (shaders/cockpit/mirror_glass.gdshader). So moving your head, or
##   opening the canopy the mirrors are mounted on, changes what each mirror shows, exactly as it would.
## * The picture is aimed and sized from the mirrors' actual optics (what the design eye sees in them), only taken
##   while you are in the cockpit, the mirrors are unfolded and at least one is on screen, and it never includes the
##   cockpit interior (that is drawn for the main view only).
##
## Folding: like the HUD sun shade, each mirror swings up on a hinge along its outer edge, out of the way against the
## canopy (key: toggle_mirrors; the graphics setting decides whether they start unfolded, folded on Low and Medium).
## Folded, nothing is rendered for them at all.

const GLASS_SHADER := preload("res://shaders/cockpit/mirror_glass.gdshader")
# the shared picture: from the middle of the arch, looking aft; wide enough for every mirror from any head position
const CAPTURE_FOV := Vector2(130.0, 64.0)     # degrees across, up
const CAPTURE_HEIGHT := [300, 360, 420]      # pixels (display resolution setting: low, medium, full)
const CAPTURE_NEAR := 1.6                    # m: clears the seat and the pilot behind the arch
# the arch's face towards the pilot (aircraft space, z = ARCH_FACE): its band's inner and outer edge, as distances
# from the arch's centre line (x = 0, y = ARCH_Y), by angle from the top (measured from the cockpit model)
const ARCH_Y := 0.9
const ARCH_FACE := -6.258
const ARCH_R := [[0.0, 0.375, 0.462], [12.0, 0.376, 0.467], [24.0, 0.386, 0.478], [36.0, 0.395, 0.488],
	[48.0, 0.409, 0.504], [60.0, 0.425, 0.518], [72.0, 0.445, 0.535], [84.0, 0.47, 0.569]]
const STANDOFF := 0.008                      # glass in front of the arch's face (the housing fills the gap)
const GLASS_THICK := 0.006                   # housing behind the glass
const CORNER := 0.014                        # rounded corners of the glass (m); the housing's are a bezel wider
const BEZEL := 0.005
const CONVEX_R := 1.6                        # m: radius of the glass's curvature
# mirrors: angle from the top of the arch (degrees, + to the right), glass width and height (m), and where the design
# eye sees through its centre (aircraft space: forward -Z, right +X, up +Y). The glass is turned to the angle that
# makes this true (half-way between the eye and that direction), as a pilot sets his mirrors before flight.
# From the eye (0, 1.18, -5.5) the fin tips are about 13 degrees out and 16 up, the wingtips 49 out and 8 down.
const MIRRORS := [
	[0.0, 0.26, 0.075, Vector3(0.0, 0.10, 1.0)],      # both fins and the spine, the sky above and behind
	[-62.0, 0.22, 0.07, Vector3(-0.50, -0.06, 1.0)],  # left: from the left fin out to the left wingtip
	[62.0, 0.22, 0.07, Vector3(0.50, -0.06, 1.0)],    # right: from the right fin out to the right wingtip
]
const FOLD_DEG := 95.0                       # how far a mirror swings up when folded
const FOLD_TIME := 0.6                       # seconds to fold or unfold

var ac: Node3D
var _mirrors: Array = []                     # {pivot, glass, basis (canopy-root space)}
var _root: Node3D                            # the canopy's root: the mirrors (and the picture's camera) move with it
var _material: ShaderMaterial                # one material for all three glasses
var _vp: SubViewport
var _cam: Camera3D
var _capture_local := Transform3D()          # the picture's camera in the canopy root's space
var _on := true
var _fold := 0.0                             # 0 unfolded .. 1 folded (shown)
var _fold_shown := -1.0
var _dev_dir := ""                           # development: --dev-mirror-shot=<dir> saves the shared picture
var _dev_t := 0.0


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
	var made: Array = []
	var to_root := _space(_root).affine_inverse()
	_material = ShaderMaterial.new()
	_material.shader = GLASS_SHADER
	_material.render_priority = 1
	_material.set_shader_parameter("convex_radius", CONVEX_R)
	_material.set_shader_parameter("capture_tan", Vector2(tan(deg_to_rad(CAPTURE_FOV.x * 0.5)), tan(deg_to_rad(CAPTURE_FOV.y * 0.5))))
	for spec in MIRRORS:
		var deg: float = spec[0]
		var size := Vector2(spec[1], spec[2])
		var th := deg_to_rad(deg)
		var radial := Vector3(sin(th), cos(th), 0.0)          # outwards from the arch's centre line
		var tangent := Vector3(cos(th), -sin(th), 0.0)        # along the arch, left to right
		# on the arch's face, in the middle of its band (the glass covers the frame there)
		var on_arch := Vector3(0.0, ARCH_Y, ARCH_FACE) + radial * _arch_r(deg)
		# the glass's normal: half-way between "towards the eye" and "towards what it should show" (the law of reflection)
		var look := (spec[3] as Vector3).normalized()
		var n := ((eye - on_arch).normalized() + look).normalized()
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
		# housing: a slim dark back and bezel, deep enough to reach the arch at the glass's far ends
		var tilt := sqrt(maxf(1.0 - n.z * n.z, 0.0))           # how far the glass is turned from the arch's face
		var depth := STANDOFF + GLASS_THICK + size.x * 0.5 * tilt
		var frame := MeshInstance3D.new()
		frame.mesh = _rounded_box(size.x + BEZEL * 2.0, size.y + BEZEL * 2.0, depth, CORNER + BEZEL)
		frame.set_surface_override_material(0, material_of.call("CP_PaintDark"))
		# the hinge: along the housing's outer edge, at its back; the mirror swings up about it
		var hinge := Vector3(0.0, size.y * 0.5 + BEZEL, -depth)
		var pivot := Node3D.new()
		pivot.transform = Transform3D(rb, rc + rb * hinge)
		_root.add_child(pivot)
		frame.transform = Transform3D(Basis(), Vector3(0.0, 0.0, -(depth * 0.5 + 0.0005)) - hinge)
		var glass := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = size
		glass.mesh = q
		glass.transform = Transform3D(Basis(), Vector3(0.0, 0.0, 0.0005) - hinge)
		glass.set_surface_override_material(0, _material)
		glass.set_instance_shader_parameter("size_m", size)
		glass.set_instance_shader_parameter("corner_m", CORNER)
		for mi in [frame, glass]:
			(mi as MeshInstance3D).layers = layer
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			pivot.add_child(mi)
			made.append(mi)
		_mirrors.append({"pivot": pivot, "glass": glass, "basis": rb})
	# the shared picture: from the middle of the arch, looking straight aft (the way the jet points)
	var centre := Vector3(0.0, ARCH_Y + _arch_r(0.0) * 0.5, ARCH_FACE)
	_capture_local = to_root * Transform3D(Basis.looking_at(Vector3(0.0, 0.0, 1.0), Vector3.UP), centre)
	_vp = SubViewport.new()
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.positional_shadow_atlas_size = 0
	_vp.audio_listener_enable_3d = false
	_vp.use_hdr_2d = true                       # the picture stays in linear light, before tone mapping (see _sync_env)
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.fov = CAPTURE_FOV.y
	_cam.near = CAPTURE_NEAR
	_cam.far = 20000.0                          # follows the main view's (see update)
	_cam.cull_mask = 0xFFFFF & ~layer           # the cockpit interior is drawn for the main view only
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_cam.compositor = Compositor.new()          # no volumetric clouds in the mirrors: they would cost a full pass
	_vp.add_child(_cam)
	_cam.current = true
	_material.set_shader_parameter("reflection", _vp.get_texture())
	_apply_resolution()
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
			ac.set("mirrors_folded", not bool(v))
		elif k == "graphics/display_res":
			_apply_resolution())
	return made


func _apply_resolution() -> void:
	var h: int = CAPTURE_HEIGHT[clampi(int(Settings.get_value("graphics/display_res")), 0, 2)]
	var aspect := tan(deg_to_rad(CAPTURE_FOV.x * 0.5)) / tan(deg_to_rad(CAPTURE_FOV.y * 0.5))
	_vp.size = Vector2i(roundi(h * aspect), h)


## The picture is rendered with the world's own sky, light and fog, but not tone mapped (no exposure, no curve, no
## glow): the glass hands it to the main view, which tone maps it once along with everything else. Tone mapping it
## twice made the mirrors pale and washed out. The sky system changes the world's environment as the day goes on,
## so the few settings it changes are copied over each time the picture is taken.
var _env: Environment
const ENV_KEYS := [&"background_mode", &"sky", &"ambient_light_source", &"ambient_light_color", &"ambient_light_energy",
	&"ambient_light_sky_contribution", &"reflected_light_source", &"fog_enabled", &"fog_light_color", &"fog_density",
	&"fog_height", &"fog_height_density", &"fog_aerial_perspective", &"fog_sky_affect"]


func _sync_env() -> void:
	var world := _vp.find_world_3d()
	var src: Environment = world.environment if world else null
	if src == null:
		return
	if _env == null:
		_env = Environment.new()
		_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_env.tonemap_exposure = 1.0
		_env.glow_enabled = false
		_env.ssao_enabled = false
		_env.ssr_enabled = false
		_env.ssil_enabled = false
		_env.sdfgi_enabled = false
		_env.volumetric_fog_enabled = false
		_cam.environment = _env
	for key in ENV_KEYS:
		var v = src.get(key)
		if _env.get(key) != v:
			_env.set(key, v)


## The mirrors swung up about their hinges by the fold amount (eased, like the sun shade).
func _show_fold() -> void:
	if _fold == _fold_shown:
		return
	_fold_shown = _fold
	var a := deg_to_rad(FOLD_DEG) * smoothstep(0.0, 1.0, _fold)
	for m in _mirrors:
		(m.pivot as Node3D).transform.basis = (m.basis as Basis) * Basis(Vector3.RIGHT, -a)
	var was := _on
	_on = _fold < 0.999
	if _on != was:
		_material.set_shader_parameter("live", _on)


## Every frame from the cockpit: folds or unfolds the mirrors, and renders the shared picture when it is needed.
func update(inside: bool, cam: Camera3D, delta: float) -> void:
	if _mirrors.is_empty():
		return
	var want := 1.0 if ac.get("mirrors_folded") else 0.0
	if _fold != want:
		_fold = move_toward(_fold, want, delta / FOLD_TIME)
		_show_fold()
	if not _on or not inside or cam == null:
		return
	var seen := false
	for m in _mirrors:
		var g := (m.glass as Node3D).global_position
		if cam.is_position_in_frustum(g):
			seen = true
			break
	if not seen:
		return
	# the picture's camera, fixed to the canopy of the jet as it is drawn this frame (interpolated)
	var air: Transform3D = ac.get_global_transform_interpolated() if ac.is_physics_interpolated_and_enabled() else ac.global_transform
	air.basis = air.basis.orthonormalized()
	var t := air * _space(_root) * _capture_local
	_cam.global_transform = t
	_cam.far = cam.far                          # as far as you can see out of the canopy (the terrain far below)
	_sync_env()
	# world direction -> the picture camera's own axes (its rows are the camera's axes)
	_material.set_shader_parameter("capture_basis", t.basis.orthonormalized().transposed())
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if _dev_dir != "":
		_dev_t += delta
		if _dev_t > 2.8:
			var img := _vp.get_texture().get_image()
			if img:
				img.convert(Image.FORMAT_RGBAF)
				img.linear_to_srgb()
				img.convert(Image.FORMAT_RGBA8)
				img.save_png(_dev_dir.path_join("mirror_capture.png"))
			_dev_dir = ""


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
