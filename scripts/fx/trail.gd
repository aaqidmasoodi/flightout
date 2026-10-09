extends MeshInstance3D
## One trail ribbon behind a moving point: wingtip vortex, vapour, contrail, missile smoke (shaders/trail.gdshader).
##
## Purely visual: it follows what is drawn (the anchor's interpolated transform), never the simulation, so it works the
## same for our jet, remote jets (placed from network snapshots) and anything else that moves, such as missiles.
## The points the emitter passed through are kept in scene coordinates in a small ring texture, and the GPU lays the
## ribbon along them, so the trail keeps the real path flown (turns, S-turns), not the jet's current heading.
## Floating origin: every stored point moves with the scene when the origin shifts. When the anchor goes away (a
## missile hits, a jet leaves) the trail stays where it is and fades out, then frees itself.
##
## Make one with Trail.attach(anchor, local_offset, preset, intensity_fn); presets are dictionaries:
##   lifetime (s), sample (s between stored points), width (m), growth (m/s), fade_in (s), color, opacity, wisp

const SHADER := preload("res://shaders/trail.gdshader")
const SUB := 2                                  # spline steps per stored point

static var _meshes := {}                        # cap -> strip mesh (shared by every trail of that length)
static var _noise: Texture2D

var anchor: Node3D
var offset := Vector3.ZERO                      # emitter in the anchor's own space
var intensity_fn: Callable                      # () -> 0..1, how visible the trail is being laid now
var preset := {}

var _cap := 64
var _img: Image
var _tex: ImageTexture
var _mat: ShaderMaterial
var _head := -1
var _count := 0
var _clock := 0.0
var _acc := 0.0
var _last_on := -1e9                            # clock time the trail last had any intensity
var _orphan := false


## A trail laid by `anchor` at `local_offset` (in the anchor's space). It lives in the scene root, not under the anchor.
static func attach(an: Node3D, local_offset: Vector3, p: Dictionary, fn: Callable) -> Node:
	var t: MeshInstance3D = load("res://scripts/fx/trail.gd").new()
	t.anchor = an
	t.offset = local_offset
	t.preset = p
	t.intensity_fn = fn
	t.name = "Trail"
	var root := an.get_tree().current_scene if an.is_inside_tree() else null
	if root == null:
		root = an.get_tree().root
	root.add_child.call_deferred(t)
	return t


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))   # the vertices are placed in the shader
	_cap = int(ceil(float(preset.get("lifetime", 2.0)) / float(preset.get("sample", 0.05)))) + 3
	mesh = _strip(_cap)
	_img = Image.create(_cap, 2, false, Image.FORMAT_RGBAF)
	_tex = ImageTexture.create_from_image(_img)
	if _noise == null:
		_noise = preload("res://scripts/world/surface_materials.gd").terrain_textures().detail
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("points", _tex)
	_mat.set_shader_parameter("noise_tex", _noise)
	_mat.set_shader_parameter("cap", _cap)
	_mat.set_shader_parameter("lifetime", float(preset.get("lifetime", 2.0)))
	_mat.set_shader_parameter("width0", float(preset.get("width", 0.5)))
	_mat.set_shader_parameter("growth", float(preset.get("growth", 0.5)))
	_mat.set_shader_parameter("fade_in", float(preset.get("fade_in", 0.0)))
	_mat.set_shader_parameter("color", preset.get("color", Color.WHITE))
	_mat.set_shader_parameter("opacity", float(preset.get("opacity", 0.6)))
	_mat.set_shader_parameter("wisp", float(preset.get("wisp", 0.5)))
	material_override = _mat
	visible = false
	WorldData.origin_shifted.connect(_on_origin_shifted)


## The emitter's position as drawn this frame.
func _emitter() -> Vector3:
	var xf: Transform3D = anchor.get_global_transform_interpolated() if anchor.is_physics_interpolated_and_enabled() else anchor.global_transform
	return xf * offset


func _process(delta: float) -> void:
	_clock += delta
	var life := float(preset.get("lifetime", 2.0))
	if not _orphan and (anchor == null or not is_instance_valid(anchor) or not anchor.is_inside_tree()):
		_orphan = true
	var on := 0.0
	var pos: Vector3
	if _orphan:
		if _count == 0 or _clock - _last_on > life:
			queue_free()
			return
		pos = _point(0)                           # no live head any more: the ribbon ends at its newest point
	else:
		pos = _emitter()
		on = clampf(float(intensity_fn.call()) if intensity_fn.is_valid() else 1.0, 0.0, 1.0)
		if on > 0.0:
			_last_on = _clock
	if _clock - _last_on > life:
		# nothing left to show: stop laying points until the trail is wanted again
		visible = false
		_count = 0
		_acc = 0.0
		return
	if not _orphan:
		_acc += delta
		if _count == 0 or _acc >= float(preset.get("sample", 0.05)):
			_acc = 0.0
			_push(pos, on)
	visible = true
	_mat.set_shader_parameter("live", Vector4(pos.x, pos.y, pos.z, on))
	_mat.set_shader_parameter("now", _clock)
	_mat.set_shader_parameter("head", _head)
	_mat.set_shader_parameter("count", _count)


func _push(p: Vector3, on: float) -> void:
	_head = (_head + 1) % _cap
	_count = mini(_count + 1, _cap - 1)
	_img.set_pixel(_head, 0, Color(p.x, p.y, p.z, _clock))
	_img.set_pixel(_head, 1, Color(on, 0.0, 0.0, 0.0))
	_tex.update(_img)


## Stored point n back from the newest (0 = newest).
func _point(n: int) -> Vector3:
	var c := _img.get_pixel((_head - n + _cap) % _cap, 0)
	return Vector3(c.r, c.g, c.b)


func _on_origin_shifted(delta: Vector3) -> void:
	if _count == 0:
		return
	for n in _count:
		var i := (_head - n + _cap) % _cap
		var c := _img.get_pixel(i, 0)
		_img.set_pixel(i, 0, Color(c.r - delta.x, c.g - delta.y, c.b - delta.z, c.a))
	_tex.update(_img)


## Strip mesh: (cap) segments of SUB steps, two vertices per step. UV.x = position along the trail in points.
static func _strip(cap: int) -> ArrayMesh:
	if _meshes.has(cap):
		return _meshes[cap]
	var rows := cap * SUB + 1
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var idx := PackedInt32Array()
	for r in rows:
		var u := float(r) / SUB
		for s in [-1.0, 1.0]:
			v.append(Vector3.ZERO)
			uv.append(Vector2(u, s))
	for r in rows - 1:
		var a := r * 2
		idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_meshes[cap] = m
	return m
