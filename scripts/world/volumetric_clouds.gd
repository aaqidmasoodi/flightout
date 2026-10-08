@tool
extends CompositorEffect
## Volumetric clouds as a compositor effect, in three GPU passes:
##   1. march   (half resolution): raymarch the cloud volume; colour + cloud start/end distances
##   2. resolve (half resolution): temporal accumulation with reprojection and neighbourhood variance clipping
##   3. composite (full resolution): depth-aware upsample; each pixel trims the clouds to what lies in front of it
## The sky system sets the public parameters every frame from the time of day and weather.

const UBO_FLOATS := 100         # 3 mat4 + 13 vec4

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
var light_steps := 3
var height_variation := 450.0   # metres the layer base and the cloud tops wander across the map
var hor_toward := Color(0.6, 0.7, 0.8)   # sky colour at the horizon towards the sun (aerial perspective)
var hor_away := Color(0.6, 0.7, 0.8)
var sun_xz := Vector2(0.0, -1.0)
var history_weight := 0.95      # temporal accumulation (motion-adaptive clipping keeps it from smearing)

var _rd: RenderingDevice
var _pipes := {}                # name -> [shader, pipeline]
var _repeat_sampler := RID()
var _clamp_sampler := RID()
var _point_sampler := RID()
var _ubo := RID()
var _raw_color := RID()
var _raw_depth := RID()
var _hist_color := [RID(), RID()]
var _hist_depth := [RID(), RID()]
var _half_size := Vector2i.ZERO
var _full_size := Vector2i.ZERO
var _cur := 0
var _prev_vp := Projection()
var _has_history := false
var _noise := {}
var _frame := 0
var _prev_wind := Vector2.ZERO


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return   # headless (dedicated server): nothing to render
	RenderingServer.call_on_render_thread(_setup)


func _setup() -> void:
	for n in ["march", "resolve", "composite"]:
		var sh := _rd.shader_create_from_spirv((load("res://shaders/clouds_%s.glsl" % n) as RDShaderFile).get_spirv())
		_pipes[n] = [sh, _rd.compute_pipeline_create(sh)]
	_repeat_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT, RenderingDevice.SAMPLER_FILTER_LINEAR)
	_clamp_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, RenderingDevice.SAMPLER_FILTER_LINEAR)
	_point_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, RenderingDevice.SAMPLER_FILTER_NEAREST)
	_ubo = _rd.uniform_buffer_create(UBO_FLOATS * 4)


func _sampler(rep: int, filt: int) -> RID:
	var s := RDSamplerState.new()
	s.min_filter = filt
	s.mag_filter = filt
	s.mip_filter = filt
	s.repeat_u = rep
	s.repeat_v = rep
	s.repeat_w = rep
	return _rd.sampler_create(s)


## Called from the main thread once the noise textures have generated.
func set_noise_textures(textures: Dictionary) -> void:
	var rids := {}
	for k in textures:
		rids[k] = RenderingServer.texture_get_rd_texture((textures[k] as Texture).get_rid())
	_noise = rids


func _all_targets() -> Array:
	return [_raw_color, _raw_depth, _hist_color[0], _hist_color[1], _hist_depth[0], _hist_depth[1]]


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		var rids: Array = [_raw_color, _raw_depth, _hist_color[0], _hist_color[1], _hist_depth[0], _hist_depth[1],
			_repeat_sampler, _clamp_sampler, _point_sampler, _ubo]
		for k in _pipes:
			rids.append(_pipes[k][1])
			rids.append(_pipes[k][0])
		for r in rids:
			if (r as RID).is_valid():
				_rd.free_rid(r)


func _target(fmt: int, size: Vector2i) -> RID:
	var f := RDTextureFormat.new()
	f.format = fmt
	f.width = size.x
	f.height = size.y
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return _rd.texture_create(f, RDTextureView.new())


func _ensure_targets(size: Vector2i) -> void:
	var hs := Vector2i(maxi((size.x + 1) / 2, 1), maxi((size.y + 1) / 2, 1))
	if hs == _half_size and _raw_color.is_valid():
		return
	for r in _all_targets():
		if (r as RID).is_valid():
			_rd.free_rid(r)
	var rgba := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var rg := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	_raw_color = _target(rgba, hs)
	_raw_depth = _target(rg, hs)
	for i in 2:
		_hist_color[i] = _target(rgba, hs)
		_hist_depth[i] = _target(rg, hs)
	_half_size = hs
	_has_history = false


static func _proj_floats(p: Projection) -> PackedFloat32Array:
	return PackedFloat32Array([p.x.x, p.x.y, p.x.z, p.x.w, p.y.x, p.y.y, p.y.z, p.y.w,
		p.z.x, p.z.y, p.z.z, p.z.w, p.w.x, p.w.y, p.w.z, p.w.w])


static func _xform_floats(t: Transform3D) -> PackedFloat32Array:
	var b := t.basis
	return PackedFloat32Array([b.x.x, b.x.y, b.x.z, 0.0, b.y.x, b.y.y, b.y.z, 0.0,
		b.z.x, b.z.y, b.z.z, 0.0, t.origin.x, t.origin.y, t.origin.z, 1.0])


func _u_image(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


func _u_tex(binding: int, sampler: RID, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(sampler)
	u.add_id(tex)
	return u


func _u_ubo(binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(_ubo)
	return u


func _dispatch(name: String, uniforms: Array, size: Vector2i) -> void:
	var sh: RID = _pipes[name][0]
	var set := UniformSetCacheRD.get_cache(sh, 0, uniforms)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[name][1])
	_rd.compute_list_bind_uniform_set(cl, set, 0)
	_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_end()


func _render_callback(_type: int, render_data: RenderData) -> void:
	if _pipes.size() < 3 or _noise.size() < 5 or coverage <= 0.001:
		_has_history = false
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_ensure_targets(size)
	var sd := render_data.get_render_scene_data()
	var cam_xf := sd.get_cam_transform()
	var proj := sd.get_cam_projection()
	var vp := proj * Projection(cam_xf.affine_inverse())
	_frame += 1
	_cur = 1 - _cur
	var data := PackedFloat32Array()
	data.append_array(_proj_floats(proj.inverse()))
	data.append_array(_xform_floats(cam_xf))
	# the noise offset moves opposite to the clouds; the world-space cloud movement this frame is its negation
	var wind_move := -(wind - _prev_wind) if _has_history else Vector2.ZERO
	_prev_wind = wind
	data.append_array([cam_xf.origin.x, cam_xf.origin.y, cam_xf.origin.z, wind_move.x])
	data.append_array([sun_dir.x, sun_dir.y, sun_dir.z, light_intensity])
	data.append_array([sun_color.r, sun_color.g, sun_color.b, ambient])
	data.append_array([amb_top.r, amb_top.g, amb_top.b, wind_move.y])
	data.append_array([amb_bottom.r, amb_bottom.g, amb_bottom.b, 0.0])
	data.append_array([fog_color.r, fog_color.g, fog_color.b, fog_density])
	data.append_array([base, top, coverage, density])
	data.append_array([stratus, darkness, wind.x, wind.y])
	data.append_array([float(_half_size.x), float(_half_size.y), float(size.x), float(size.y)])
	data.append_array([max_distance, float(_frame % 4096), float(primary_steps), float(light_steps)])
	data.append_array(_proj_floats(_prev_vp))
	data.append_array([1.0 if _has_history else 0.0, history_weight, height_variation, 0.0])
	data.append_array([hor_toward.r, hor_toward.g, hor_toward.b, sun_xz.x])
	data.append_array([hor_away.r, hor_away.g, hor_away.b, sun_xz.y])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)
	for view in buffers.get_view_count():
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		_dispatch("march", [_u_image(0, _raw_color), _u_tex(1, _point_sampler, depth),
			_u_tex(2, _repeat_sampler, _noise.perlin), _u_tex(3, _repeat_sampler, _noise.worley),
			_u_tex(4, _repeat_sampler, _noise.detail), _u_tex(5, _repeat_sampler, _noise.weather),
			_u_ubo(6), _u_image(7, _raw_depth), _u_tex(8, _point_sampler, _noise.blue)], _half_size)
		_dispatch("resolve", [_u_image(0, _hist_color[_cur]), _u_image(1, _hist_depth[_cur]),
			_u_tex(2, _point_sampler, _raw_color), _u_tex(3, _point_sampler, _raw_depth),
			_u_tex(4, _clamp_sampler, _hist_color[1 - _cur]), _u_ubo(6)], _half_size)
		_dispatch("composite", [_u_image(0, color), _u_tex(1, _point_sampler, _hist_color[_cur]),
			_u_tex(2, _point_sampler, _hist_depth[_cur]), _u_tex(3, _point_sampler, depth), _u_ubo(4)], size)
	_prev_vp = vp
	_has_history = true
