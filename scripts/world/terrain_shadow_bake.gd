extends RefCounted
## The mountains' cast shadows, worked out for the whole map at once on the GPU (shaders/terrain_shadow_bake.glsl)
## whenever the sun has moved by more than a fraction of a degree, instead of being traced from every terrain and
## tree vertex every frame. The result is a map-sized texture the terrain and tree shaders read with one lookup
## (global `terrain_shadow_map`, see shaders/include/terrain_shadow.gdshaderinc).
##
## The terrain streamer owns it (it loads the coarse heightmap the shadows come from); the sky system tells it where
## the sun is (request()).

const SHADER := preload("res://shaders/terrain_shadow_bake.glsl")
const MIN_ANGLE := 0.0026          # radians the sun must move before the shadows are worked out again (0.15 degrees)

static var _wanted := Vector3.UP   # sun direction the sky system wants (set every frame, cheap)

var _rd: RenderingDevice
var _shader := RID()
var _pipe := RID()
var _sampler := RID()
var _out := RID()
var _src := RID()                  # the overview heightmap (an ImageTexture's GPU texture)
var _size := Vector2i.ZERO
var _push := PackedByteArray()
var _baked := Vector3.ZERO         # the sun direction last worked out
var _ready := false
var texture := Texture2DRD.new()


static func request(sun_dir: Vector3) -> void:
	_wanted = sun_dir


## overview: the heightmap texture; rect: x0, z0, 1 / width (m), 1 / depth (m); spacing: metres per texel.
func setup(overview: Texture2D, rect: Vector4, spacing: float) -> bool:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return false
	_size = Vector2i(overview.get_width(), overview.get_height())
	var floats := PackedFloat32Array([0.0, 1.0, 0.0, 0.0, rect.x, rect.y, rect.z, rect.w, float(_size.x), float(_size.y), spacing, 0.0])
	_push = floats.to_byte_array()
	var ov_rid := overview.get_rid()
	RenderingServer.call_on_render_thread(_setup_rd.bind(ov_rid))
	return true


func _setup_rd(ov_rid: RID) -> void:
	_src = RenderingServer.texture_get_rd_texture(ov_rid)
	var spirv := SHADER.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("Terrain shadow bake: shader failed to compile")
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipe = _rd.compute_pipeline_create(_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	f.width = _size.x
	f.height = _size.y
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_out = _rd.texture_create(f, RDTextureView.new())
	texture.texture_rd_rid = _out
	_ready = true


## Called every frame: works the shadows out again once the sun has moved enough (and the first time).
func update() -> void:
	if not _ready:
		return
	var s := _wanted.normalized()
	if _baked != Vector3.ZERO and s.angle_to(_baked) < MIN_ANGLE:
		return
	var first := _baked == Vector3.ZERO
	_baked = s
	var floats := _push.to_float32_array()
	floats[0] = s.x
	floats[1] = s.y
	floats[2] = s.z
	RenderingServer.call_on_render_thread(_bake.bind(floats.to_byte_array()))
	if first:
		# only once there is a result: until then the shaders keep tracing the shadows themselves
		(func():
			RenderingServer.global_shader_parameter_set("terrain_shadow_map", texture)
			RenderingServer.global_shader_parameter_set("terrain_shadow_baked", 1.0)).call_deferred()


func _bake(push: PackedByteArray) -> void:
	if not _src.is_valid():
		return
	var u0 := RDUniform.new()
	u0.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u0.binding = 0
	u0.add_id(_sampler)
	u0.add_id(_src)
	var u1 := RDUniform.new()
	u1.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u1.binding = 1
	u1.add_id(_out)
	var set := UniformSetCacheRD.get_cache(_shader, 0, [u0, u1])
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipe)
	_rd.compute_list_bind_uniform_set(cl, set, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, (_size.x + 7) / 8, (_size.y + 7) / 8, 1)
	_rd.compute_list_end()


static var _placeholder: ImageTexture


## Leaving the flight: the shaders stop reading the map (a 1x1 stand-in takes its place in the global, so nothing
## points at a freed texture), and the GPU resources are released a couple of frames later, once no frame in
## flight uses them any more.
func release() -> void:
	RenderingServer.global_shader_parameter_set("terrain_shadow_baked", 0.0)
	if _placeholder == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RF)
		img.set_pixel(0, 0, Color(1.0, 0.0, 0.0))
		_placeholder = ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set("terrain_shadow_map", _placeholder)
	_ready = false
	if _rd:
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			tree.create_timer(0.25, true, false, true).timeout.connect(func(): RenderingServer.call_on_render_thread(_free_rd))


func _free_rd() -> void:
	for r in [_out, _pipe, _shader, _sampler]:
		if (r as RID).is_valid():
			_rd.free_rid(r)
	_out = RID()
	_pipe = RID()
	_shader = RID()
	_sampler = RID()
