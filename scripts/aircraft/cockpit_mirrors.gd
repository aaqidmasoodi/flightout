extends Node
## Rear-view mirrors on the canopy's front arch, upper left and right (as on the Su-27), built at run time where the
## cockpit model has its hand-hold pads (which they replace).
##
## Each mirror is angled so that, from the design eye point, it shows the view behind the jet and a little outboard.
## Its picture is a true planar reflection: a camera at your eye reflected in the mirror's plane, looking through
## exactly the mirror's outline (an off-axis frustum whose near plane is the glass), so the image lines up with the
## frame and shifts as your head moves, like a real mirror. Each mirror's picture is re-rendered 15 times a second,
## the two taking turns, and only while you are in the cockpit, the mirrors are switched on and one is on screen.

const GLASS_SHADER := preload("res://shaders/cockpit/mirror_glass.gdshader")
const SIZE := Vector2(0.16, 0.075)           # glass, metres (width x height)
const PICTURE := Vector2i(256, 120)          # reflection picture, pixels (the glass's shape)
const RATE_HZ := 15.0                        # per mirror
const STANDOFF := 0.035                      # glass in front of the arch's inner face, metres
const FAR := 5000.0
# where each mirror looks (aircraft space: forward -Z, right +X, up +Y): behind, a little outboard and up
const LOOK_AFT := Vector3(0.0, 0.05, 1.0)
const LOOK_OUT := 0.3

var ac: Node3D
var _mirrors: Array = []                     # {glass, housing, stalk, viewport, camera, centre, x, y, n (canopy-root space)}
var _root: Node3D                            # the canopy's root: the mirrors move with the canopy
var _acc := 0.0
var _turn := 0
var _on := true
var _mat_off: ShaderMaterial


## pads: the canopy's hand-hold pad mesh (two boxes, left and right). eye: design eye point in aircraft space.
## material_of: name -> cockpit material. Returns the meshes made, for the cockpit to draw with its precise transform.
func build(aircraft: Node3D, root: Node3D, pads: MeshInstance3D, eye: Vector3, material_of: Callable, layer: int) -> Array:
	ac = aircraft
	_root = root
	var made: Array = []
	var vs: PackedVector3Array = pads.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var to_root := _space(_root).affine_inverse() * _space(pads)
	var eye_root := _space(_root).affine_inverse() * eye
	for side in [-1.0, 1.0]:
		var pts := PackedVector3Array()
		for v in vs:
			var p := to_root * v
			if signf(p.x) == side:
				pts.append(p)
		if pts.size() < 8:
			continue
		var fit := _box_axes(pts)
		var centre: Vector3 = fit[0]
		var inward: Vector3 = fit[3]                     # the pad's thin axis, turned to face the cockpit
		if inward.dot(eye_root - centre) < 0.0:
			inward = -inward
		var mount := centre + inward * STANDOFF
		# glass normal: halfway between "towards the eye" and "towards what it should show", so the eye sees that view
		var look := (LOOK_AFT + Vector3(side * LOOK_OUT, 0.0, 0.0)).normalized()
		var look_root := (_space(_root).basis.inverse() * look).normalized()
		var n := ((eye_root - mount).normalized() + look_root).normalized()
		var up_root := (_space(_root).basis.inverse() * Vector3.UP).normalized()
		var x := up_root.cross(n).normalized()
		var y := n.cross(x).normalized()
		var basis := Basis(x, y, n)
		var m := {"centre": mount, "x": x, "y": y, "n": n}
		# housing: a shallow dark frame behind the glass, on a short stalk from the arch
		var housing := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(SIZE.x + 0.014, SIZE.y + 0.014, 0.018)
		housing.mesh = hb
		housing.transform = Transform3D(basis, mount - n * 0.0095)
		housing.material_override = null
		housing.set_surface_override_material(0, material_of.call("CP_SteelDark"))
		var stalk := MeshInstance3D.new()
		var sb := CylinderMesh.new()
		var stalk_len := maxf((mount - centre).length() - 0.01, 0.01)
		sb.top_radius = 0.007
		sb.bottom_radius = 0.009
		sb.height = stalk_len
		stalk.mesh = sb
		var axis := (mount - centre).normalized()
		var sx := axis.cross(x).normalized() if absf(axis.dot(x)) < 0.95 else axis.cross(y).normalized()
		stalk.transform = Transform3D(Basis(sx, axis, sx.cross(axis)), centre + axis * (stalk_len * 0.5))
		stalk.set_surface_override_material(0, material_of.call("CP_SteelDark"))
		var glass := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = SIZE
		glass.mesh = q
		glass.transform = Transform3D(basis, mount + n * 0.0005)
		for mi in [housing, stalk, glass]:
			(mi as MeshInstance3D).layers = layer
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_root.add_child(mi)
			made.append(mi)
		# the reflection's own small view of the world
		var vp := SubViewport.new()
		vp.size = PICTURE
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
	if not _mirrors.is_empty():
		pads.visible = false                         # the mirrors take the hand-holds' places
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
	cam.set_frustum(SIZE.y, Vector2(o.dot(-x), o.dot(y)), d, FAR)


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


## Centre and axes of a box-shaped point set: [centre, longest axis, middle axis, shortest axis].
static func _box_axes(pts: PackedVector3Array) -> Array:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	# covariance, then its axes by power iteration (the pads are clean boxes, this converges at once)
	var xx := 0.0; var xy := 0.0; var xz := 0.0; var yy := 0.0; var yz := 0.0; var zz := 0.0
	for p in pts:
		var d := p - c
		xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
		yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
	var cov := Basis(Vector3(xx, xy, xz), Vector3(xy, yy, yz), Vector3(xz, yz, zz))
	var a1 := _dominant(cov, Vector3(1, 0.3, 0.2))
	# the thinnest axis: the dominant one of (trace - cov), whose largest eigenvalue belongs to cov's smallest
	var t := xx + yy + zz
	var inv := Basis(Vector3(t - xx, -xy, -xz), Vector3(-xy, t - yy, -yz), Vector3(-xz, -yz, t - zz))
	var a3 := _dominant(inv, Vector3(0.2, 0.3, 1.0))
	a3 = (a3 - a1 * a3.dot(a1)).normalized()
	var a2 := a3.cross(a1).normalized()
	return [c, a1, a2, a3]


static func _dominant(m: Basis, start: Vector3) -> Vector3:
	var v := start.normalized()
	for i in 400:
		var w := m * v
		if w.length() < 1e-12:
			break
		v = w.normalized()
	return v

