@tool
extends CompositorEffect
## Volumetric clouds as a compositor effect: raymarched at half resolution on the GPU, depth-aware (clouds sit
## correctly in front of and behind terrain and aircraft), then upsampled and composited over the HDR scene.
## The sky system sets the public parameters every frame from the time of day and weather.

const UBO_FLOATS := 92          # 3 mat4 + 11 vec4

var sun_dir := Vector3.UP
var light_intensity := 1.0
var sun_color := Color(1, 1, 1)
var ambient := 1.0
var amb_top := Color(0.5, 0.6, 0.7)
var amb_bottom := Color(0.25, 0.27, 0.3)
var fog_color := Color(0.6, 0.7, 0.8)
var fog_density := 0.00003
var base := 1400.0
var top := 2900.0
var coverage := 0.4
var density := 1.0
var stratus := 0.0
var darkness := 0.0
var wind := Vector2.ZERO
var max_distance := 40000.0
var primary_steps := 72
var light_steps := 5
var height_variation := 450.0   # metres the layer base and the cloud tops wander across the map
var history_weight := 0.88      # temporal accumulation (higher = smoother, slower to react)

var _rd: RenderingDevice
var _march_shader := RID()
var _march_pipe := RID()
var _comp_shader := RID()
var _comp_pipe := RID()
var _repeat_sampler := RID()
var _clamp_sampler := RID()
var _ubo := RID()
var _half := [RID(), RID()]     # ping-pong: current result and last frame's (history)
var _half_size := Vector2i.ZERO
var _cur := 0
var _prev_vp := Projection()
var _has_history := false
var _noise := {}                 # name -> RD texture RID
var _frame := 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(_setup)


func _setup() -> void:
	_march_shader = _rd.shader_create_from_spirv((load("res://shaders/clouds_march.glsl") as RDShaderFile).get_spirv())
	_march_pipe = _rd.compute_pipeline_create(_march_shader)
	_comp_shader = _rd.shader_create_from_spirv((load("res://shaders/clouds_composite.glsl") as RDShaderFile).get_spirv())
	_comp_pipe = _rd.compute_pipeline_create(_comp_shader)
	var s := RDSamplerState.new()
	s.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	s.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	s.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_repeat_sampler = _rd.sampler_create(s)
	var c := RDSamplerState.new()
	c.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	c.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	c.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	c.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_clamp_sampler = _rd.sampler_create(c)
	_ubo = _rd.uniform_buffer_create(UBO_FLOATS * 4)


## Called from the main thread once the noise textures have generated.
func set_noise_textures(textures: Dictionary) -> void:
	var rids := {}
	for k in textures:
		rids[k] = RenderingServer.texture_get_rd_texture((textures[k] as Texture).get_rid())
	_noise = rids


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for r in [_march_pipe, _march_shader, _comp_pipe, _comp_shader, _repeat_sampler, _clamp_sampler, _ubo, _half[0], _half[1]]:
			if r.is_valid():
				_rd.free_rid(r)


func _ensure_half(size: Vector2i) -> void:
	var hs := Vector2i(maxi(size.x / 2, 1), maxi(size.y / 2, 1))
	if hs == _half_size and (_half[0] as RID).is_valid():
		return
	for i in 2:
		if (_half[i] as RID).is_valid():
			_rd.free_rid(_half[i])
		var f := RDTextureFormat.new()
		f.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		f.width = hs.x
		f.height = hs.y
		f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		_half[i] = _rd.texture_create(f, RDTextureView.new())
	_half_size = hs
	_has_history = false


static func _proj_floats(p: Projection) -> PackedFloat32Array:
	return PackedFloat32Array([p.x.x, p.x.y, p.x.z, p.x.w, p.y.x, p.y.y, p.y.z, p.y.w,
		p.z.x, p.z.y, p.z.z, p.z.w, p.w.x, p.w.y, p.w.z, p.w.w])


static func _xform_floats(t: Transform3D) -> PackedFloat32Array:
	var b := t.basis
	return PackedFloat32Array([b.x.x, b.x.y, b.x.z, 0.0, b.y.x, b.y.y, b.y.z, 0.0,
		b.z.x, b.z.y, b.z.z, 0.0, t.origin.x, t.origin.y, t.origin.z, 1.0])


func _sampler_uniform(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not _march_pipe.is_valid() or _noise.size() < 4 or coverage <= 0.001:
		_has_history = false
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_ensure_half(size)
	var sd := render_data.get_render_scene_data()
	var cam_xf := sd.get_cam_transform()
	var proj := sd.get_cam_projection()
	var vp := proj * Projection(cam_xf.affine_inverse())
	_frame += 1
	_cur = 1 - _cur
	var cur_tex: RID = _half[_cur]
	var hist_tex: RID = _half[1 - _cur]
	var data := PackedFloat32Array()
	data.append_array(_proj_floats(proj.inverse()))
	data.append_array(_xform_floats(cam_xf))
	data.append_array([cam_xf.origin.x, cam_xf.origin.y, cam_xf.origin.z, 0.0])
	data.append_array([sun_dir.x, sun_dir.y, sun_dir.z, light_intensity])
	data.append_array([sun_color.r, sun_color.g, sun_color.b, ambient])
	data.append_array([amb_top.r, amb_top.g, amb_top.b, 0.0])
	data.append_array([amb_bottom.r, amb_bottom.g, amb_bottom.b, 0.0])
	data.append_array([fog_color.r, fog_color.g, fog_color.b, fog_density])
	data.append_array([base, top, coverage, density])
	data.append_array([stratus, darkness, wind.x, wind.y])
	data.append_array([float(_half_size.x), float(_half_size.y), float(size.x), float(size.y)])
	data.append_array([max_distance, float(_frame), float(primary_steps), float(light_steps)])
	data.append_array(_proj_floats(_prev_vp))
	data.append_array([1.0 if _has_history else 0.0, history_weight, height_variation, 0.0])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		# pass 1: raymarch at half resolution
		var out := RDUniform.new()
		out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		out.binding = 0
		out.add_id(cur_tex)
		var ub := RDUniform.new()
		ub.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		ub.binding = 6
		ub.add_id(_ubo)
		var set1 := UniformSetCacheRD.get_cache(_march_shader, 0, [out, _sampler_uniform(1, _clamp_sampler, depth),
			_sampler_uniform(2, _repeat_sampler, _noise.perlin), _sampler_uniform(3, _repeat_sampler, _noise.worley),
			_sampler_uniform(4, _repeat_sampler, _noise.detail), _sampler_uniform(5, _repeat_sampler, _noise.weather), ub,
			_sampler_uniform(7, _clamp_sampler, hist_tex)])
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _march_pipe)
		_rd.compute_list_bind_uniform_set(cl, set1, 0)
		_rd.compute_list_dispatch(cl, (_half_size.x + 7) / 8, (_half_size.y + 7) / 8, 1)
		_rd.compute_list_end()
		# pass 2: upsample and composite over the scene
		var col := RDUniform.new()
		col.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		col.binding = 0
		col.add_id(color)
		var set2 := UniformSetCacheRD.get_cache(_comp_shader, 0, [col, _sampler_uniform(1, _clamp_sampler, cur_tex)])
		var push := PackedFloat32Array([float(size.x), float(size.y), 0.0, 0.0]).to_byte_array()
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _comp_pipe)
		_rd.compute_list_bind_uniform_set(cl, set2, 0)
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
		_rd.compute_list_end()
	_prev_vp = vp
	_has_history = true
