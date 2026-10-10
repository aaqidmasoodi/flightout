@tool
extends CompositorEffect
## The clouds: one cloud model (shaders/include/clouds_common.glslinc) and everything that reads it, on the GPU.
##
## Once, at start (generated, not loaded):
##   noise    the shape (128^3) and detail (64^3) noise volumes, with their mip levels (clouds_noise / clouds_mip)
##   weather  the weather map over the whole map: regional cover, cloud type, height, clustering (clouds_weather);
##            also read back once for the CPU (scripts/world/cloud_weather.gd: rain, the deck, the simulation)
## Every frame, before the opaque pass (`shadow_pass`, its own compositor effect):
##   shadow   the clouds' shadow map in two cascades (clouds_shadow), which the terrain, trees, trails and the
##            clouds themselves sample, and the sunlight reaching the camera (read back: the jets' lighting)
##   far      a band of the far-cloud map (clouds_far): the cloud columns integrated, which the march draws beyond
##            its own range from (a second copy is built while the first is used, then they swap)
## Every frame, before the transparent pass (this effect):
##   march    (half or quarter resolution) the clouds along each pixel's ray, near / mid / far ranges and cirrus
##   resolve  temporal accumulation, reprojected at the cloud's own distance, with variance clipping
##   composite to full resolution, trimmed to each pixel's depth: the overlay (blended over the scene by
##            shaders/cloud_overlay.gdshader) and the cloud layer (the occlusion every later surface uses,
##            shaders/include/cloud_cover.gdshaderinc)
## The sky system sets the public parameters every frame from the time of day and weather.

const UBO_FLOATS := 3 * 16 + 23 * 4 + 12 * 4
const CloudGround = preload("res://scripts/world/cloud_ground.gd")
const CloudWeather = preload("res://scripts/world/cloud_weather.gd")
const SHAPE_N := 128
const DETAIL_N := 64
const WEATHER_N := 1024
const WEATHER_SEED := 808.0       # fixed: every player sees the same clouds
const SH0_N := 512
const SH0_HALF := 25600.0         # cascade 0: 51 km square, 100 m texels
const SH1_N := 256
const SH1_HALF := 204800.0        # cascade 1: 410 km, 1.6 km texels
const SH_ROWS := 4                # each cascade updates a quarter of its rows per frame
const CIRRUS_HEIGHT := 9000.0
const FAR_N := 1024               # the far-cloud maps (clouds_far.glsl): 1024 x 1024 each
const FAR_HALF := [120000.0, 480000.0]   # near: 240 km (234 m texels); wide: 960 km (938 m), to the horizon
const FAR_ROWS := [64, 32]        # rows built per frame: a new near map every 16 frames, wide every 32
const FAR_LOD := [2.3, 4.3]       # the shape noise's level for a texel's footprint

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
var variability := 0.6            # how much the weather map varies the preset across the land (0 uniform)
var cirrus := 0.0                 # cirrus cover high above
var wind := Vector2.ZERO          # map offset of the drifting clouds (m)
var march_end := 34000.0          # the full march (quality); beyond it the far field
var near_end := 9000.0            # the detail erosion (quality)
var primary_steps := 72
var light_steps := 3
var max_iterations := 320         # loop iterations per ray (cheap steps through air included)
var max_dense := 96               # samples inside cloud per ray (the expensive ones)
var resolution_div := 2           # march at 1/2 (or 1/4) of the screen
var active := true                # graphics/volumetric_clouds
## base and top are metres above the ground of the region (scripts/world/cloud_ground.gd): ground_mix 0 measures
## from its floor (valley floors and plains: fog, low cloud), 1 from its mean (decks the mountains rise through)
var ground_mix := 0.5
var height_variation := 450.0     # metres the layer base and the cloud tops wander across the map
var hor_toward := Color(0.6, 0.7, 0.8)   # sky colour at the horizon towards the sun (aerial perspective)
var hor_away := Color(0.6, 0.7, 0.8)
var sun_xz := Vector2(0.0, -1.0)
var history_weight := 0.94
## How fast the detail of the clouds rises through them (m/s): the billows evolve, very slowly. The clouds as a
## whole drift with the wind (`wind`), rigidly.
var evolve_rate := 0.1
var _evolve := 0.0
var _evolve_ms := -1
## The optical depth of cloud between the camera and the sun (read back from the GPU, a frame or two late).
var cam_od := 0.0
var cam_od_valid := false
var shadow_pass: CompositorEffect

var _dbg := false
var _dbg_n := 0
var _dbg_mode := 0          # --clouds-debug=1 / 2: debug views in the march (see clouds_march.glsl)
var _rd: RenderingDevice
var _pipes := {}                # name -> [shader, pipeline]
var _repeat_sampler := RID()
var _clamp_sampler := RID()
var _point_sampler := RID()
var _ubo := RID()
var _shape := RID()
var _detail := RID()
var _weather := RID()
var _generated := false
var _sh := [RID(), RID()]
var _sh_info := RID()
var _sh_centre := [Vector2(INF, INF), Vector2(INF, INF)]
var _sh_phase := 0
var _cam_buf := RID()
# per far map (near, wide), two copies each: one in use while the other is built
var _far := [[RID(), RID()], [RID(), RID()]]
var _far_levels := [[[], []], [[], []]]   # one view per mip level (the build writes level 0, the mip pass the rest)
var _far_front := [0, 0]
var _far_centre := [[Vector2.ZERO, Vector2.ZERO], [Vector2.ZERO, Vector2.ZERO]]   # wind space
var _far_valid := [[false, false], [false, false]]
var _far_row := [0, 0]            # next row of the copy being built
var _cam_pending := false
var _cam_frame := 0
var _no_readback := false     # --clouds-no-readback (development)
var _raw_color := RID()
var _raw_depth := RID()
var _hist_color := [RID(), RID()]
var _hist_depth := [RID(), RID()]
var _half_size := Vector2i.ZERO
var _cur := 0
var _prev_vp := Projection()
var _has_history := false
var _blue := RID()
var _blue_tex: Texture2D
var _blue_rid := RID()
var _frame := 0
var _prev_wind := Vector2.ZERO
var _shift := Vector3.ZERO         # the floating origin moved by this since the last frame: history is in the old frame
var _prev_shape := Vector4.ZERO    # coverage, density, base, top last frame: weather changing -> trust history less
var _layer := RID()             # full resolution: r transmittance, g cloud front, b cloud back (km)
var _layer_size := Vector2i.ZERO
var layer_texture := Texture2DRD.new()
var _overlay := RID()           # full resolution: rgb in-scattered light, a transmittance (shaders/cloud_overlay.gdshader)
var overlay_texture := Texture2DRD.new()
var shadow0_texture := Texture2DRD.new()
var shadow1_texture := Texture2DRD.new()
var shadow_info_texture := Texture2DRD.new()
var _layer_published := false
var _ready_frame := false       # this frame's parameters are in the buffer (the shadow pass ran)


class ShadowPass extends CompositorEffect:
	var fx: WeakRef
	func _init() -> void:
		effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	func _render_callback(_type: int, render_data: RenderData) -> void:
		var f = fx.get_ref() if fx else null
		if f:
			f._shadow_callback(render_data)


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--clouds-no-readback":
			_no_readback = true
		if a.begins_with("--clouds-debug"):
			_dbg = true
			_dbg_mode = a.trim_prefix("--clouds-debug").trim_prefix("=").to_int()
	# before the transparent pass: glass, the HUD, flames and particles then draw over the clouds instead of being
	# painted over by them; transparent things behind clouds hide behind them through the cloud layer texture
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	# with MSAA the depth the clouds are trimmed against must be resolved first (no-op without MSAA)
	access_resolved_depth = true
	shadow_pass = ShadowPass.new()
	shadow_pass.fx = weakref(self)
	WorldData.origin_shifted.connect(_on_origin_shifted)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return   # headless (dedicated server): nothing to render
	RenderingServer.call_on_render_thread(_setup)


## The clouds are sampled at map positions (scene + origin), so they stay put when the origin moves. The reprojection
## history is kept: last frame's view-projection is moved into the new frame instead.
func _on_origin_shifted(delta: Vector3) -> void:
	_shift += delta


func _setup() -> void:
	for n in ["noise", "mip", "mip2d", "weather", "shadow", "far", "march", "resolve", "composite"]:
		var spirv := (load("res://shaders/clouds_%s.glsl" % n) as RDShaderFile).get_spirv()
		if spirv.compile_error_compute != "":
			push_error("Clouds: %s shader: %s" % [n, spirv.compile_error_compute])
		var sh := _rd.shader_create_from_spirv(spirv)
		_pipes[n] = [sh, _rd.compute_pipeline_create(sh)]
	_repeat_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT, RenderingDevice.SAMPLER_FILTER_LINEAR)
	_clamp_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, RenderingDevice.SAMPLER_FILTER_LINEAR)
	_point_sampler = _sampler(RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE, RenderingDevice.SAMPLER_FILTER_NEAREST)
	_ubo = _rd.uniform_buffer_create(UBO_FLOATS * 4)
	var zero := PackedByteArray()
	zero.resize(16)
	_cam_buf = _rd.storage_buffer_create(16, zero)
	var u := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_shape = _volume(SHAPE_N, u)
	_detail = _volume(DETAIL_N, u)
	var wf := RDTextureFormat.new()
	wf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	wf.width = WEATHER_N
	wf.height = WEATHER_N
	wf.usage_bits = u | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_weather = _rd.texture_create(wf, RDTextureView.new())
	_sh[0] = _target(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector2i(SH0_N, SH0_N))
	_sh[1] = _target(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Vector2i(SH1_N, SH1_N))
	for i in 2:
		_rd.texture_clear(_sh[i], Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)
		for c in 2:
			var ff := RDTextureFormat.new()
			ff.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			ff.width = FAR_N
			ff.height = FAR_N
			ff.mipmaps = int(log(float(FAR_N)) / log(2.0)) + 1
			ff.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
			_far[c][i] = _rd.texture_create(ff, RDTextureView.new())
			_rd.texture_clear(_far[c][i], Color(0.0, 0.0, 0.0, 1.0), 0, ff.mipmaps, 0, 1)
			for lv in ff.mipmaps:
				_far_levels[c][i].append(_rd.texture_create_shared_from_slice(RDTextureView.new(), _far[c][i], 0, lv, 1, RenderingDevice.TEXTURE_SLICE_2D))
	var inf := RDTextureFormat.new()
	inf.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	inf.width = 4
	inf.height = 1
	inf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_sh_info = _rd.texture_create(inf, RDTextureView.new(), [PackedFloat32Array([0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]).to_byte_array()])
	shadow0_texture.texture_rd_rid = _sh[0]
	shadow1_texture.texture_rd_rid = _sh[1]
	shadow_info_texture.texture_rd_rid = _sh_info
	(func():
		RenderingServer.global_shader_parameter_set("cloud_shadow0", shadow0_texture)
		RenderingServer.global_shader_parameter_set("cloud_shadow1", shadow1_texture)
		RenderingServer.global_shader_parameter_set("cloud_shadow_info", shadow_info_texture)).call_deferred()
	_generate()


func _volume(n: int, usage: int) -> RID:
	var f := RDTextureFormat.new()
	f.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	f.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	f.width = n
	f.height = n
	f.depth = n
	f.mipmaps = int(log(float(n)) / log(2.0)) + 1
	f.usage_bits = usage
	return _rd.texture_create(f, RDTextureView.new())


## The noise volumes (with mips) and the weather map, once.
func _generate() -> void:
	for spec in [[_shape, SHAPE_N, 0.0], [_detail, DETAIL_N, 1.0]]:
		var tex: RID = spec[0]
		var n: int = spec[1]
		var lv0 := _rd.texture_create_shared_from_slice(RDTextureView.new(), tex, 0, 0, 1, RenderingDevice.TEXTURE_SLICE_3D)
		_dispatch3("noise", [_u_image(0, lv0)], n, PackedFloat32Array([float(n), spec[2], 17.0, 0.0]))
		var prev := lv0
		var size := n
		var level := 1
		while size > 1:
			size /= 2
			var lv := _rd.texture_create_shared_from_slice(RDTextureView.new(), tex, 0, level, 1, RenderingDevice.TEXTURE_SLICE_3D)
			_dispatch3("mip", [_u_image(0, prev), _u_image(1, lv)], size, PackedFloat32Array([float(size), 0.0, 0.0, 0.0]))
			_rd.free_rid(prev)
			prev = lv
			level += 1
		_rd.free_rid(prev)
	_dispatch("weather", [_u_image(0, _weather)], Vector2i(WEATHER_N, WEATHER_N), PackedFloat32Array([float(WEATHER_N), WEATHER_SEED, 0.0, 0.0]))
	var data := _rd.texture_get_data(_weather, 0)
	var img := Image.create_from_data(WEATHER_N, WEATHER_N, false, Image.FORMAT_RGBA8, data)
	CloudWeather.set_map.call_deferred(img)
	_generated = true


func _sampler(rep: int, filt: int) -> RID:
	var s := RDSamplerState.new()
	s.min_filter = filt
	s.mag_filter = filt
	s.mip_filter = filt
	s.repeat_u = rep
	s.repeat_v = rep
	s.repeat_w = rep
	return _rd.sampler_create(s)


## The blue noise used to spread the march's samples (assets/clouds/blue_noise_64.png), from the main thread. Its
## GPU texture is looked up each frame (the engine may still be uploading it, or replace it).
func set_blue_noise(tex: Texture2D) -> void:
	_blue_tex = tex
	_blue_rid = tex.get_rid()


func _all_targets() -> Array:
	return [_raw_color, _raw_depth, _hist_color[0], _hist_color[1], _hist_depth[0], _hist_depth[1]]


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		# the far map's per-level views first: they depend on the far map's textures
		for lv in _far_levels[0][0] + _far_levels[0][1] + _far_levels[1][0] + _far_levels[1][1]:
			if (lv as RID).is_valid() and _rd.texture_is_valid(lv):
				_rd.free_rid(lv)
		var rids: Array = [_raw_color, _raw_depth, _hist_color[0], _hist_color[1], _hist_depth[0], _hist_depth[1], _repeat_sampler, _clamp_sampler, _point_sampler, _ubo, _layer, _overlay,
			_shape, _detail, _weather, _sh[0], _sh[1], _sh_info, _far[0][0], _far[0][1], _far[1][0], _far[1][1]]
		if not _cam_pending:
			rids.append(_cam_buf)      # (a readback may still be reading it: then it goes with the device)
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
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	return _rd.texture_create(f, RDTextureView.new())


func _ensure_layer(size: Vector2i) -> void:
	if size == _layer_size and _layer.is_valid():
		return
	var old := _layer
	_layer = _target(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	_rd.texture_clear(_layer, Color(1.0, 60000.0, 60000.0, 1.0), 0, 1, 0, 1)
	layer_texture.texture_rd_rid = _layer
	if old.is_valid():
		_rd.free_rid(old)
	var old_o := _overlay
	_overlay = _target(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, size)
	_rd.texture_clear(_overlay, Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)
	overlay_texture.texture_rd_rid = _overlay
	if old_o.is_valid():
		_rd.free_rid(old_o)
	_layer_size = size
	if not _layer_published:
		_layer_published = true
		(func():
			RenderingServer.global_shader_parameter_set("cloud_layer", layer_texture)
			RenderingServer.global_shader_parameter_set("cloud_overlay", overlay_texture)).call_deferred()


func _ensure_targets(size: Vector2i) -> void:
	var dv := 4 if resolution_div >= 4 else 2
	var hs := Vector2i(maxi((size.x + dv - 1) / dv, 1), maxi((size.y + dv - 1) / dv, 1))
	if hs == _half_size and _raw_color.is_valid():
		return
	for r in _all_targets():
		if (r as RID).is_valid():
			_rd.free_rid(r)
	var rgba := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	var deep := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	_raw_color = _target(rgba, hs)
	_raw_depth = _target(deep, hs)
	for i in 2:
		_hist_color[i] = _target(rgba, hs)
		_hist_depth[i] = _target(deep, hs)
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


func _u_ubo() -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = 0
	u.add_id(_ubo)
	return u


func _u_buf(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _dispatch(name: String, uniforms: Array, size: Vector2i, pc := PackedFloat32Array()) -> void:
	var sh: RID = _pipes[name][0]
	var set := UniformSetCacheRD.get_cache(sh, 0, uniforms)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[name][1])
	_rd.compute_list_bind_uniform_set(cl, set, 0)
	if not pc.is_empty():
		var b := pc.to_byte_array()
		_rd.compute_list_set_push_constant(cl, b, b.size())
	_rd.compute_list_dispatch(cl, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_end()


func _dispatch3(name: String, uniforms: Array, n: int, pc: PackedFloat32Array) -> void:
	var sh: RID = _pipes[name][0]
	# image views made for one dispatch: a fresh uniform set, freed with its views
	var set := _rd.uniform_set_create(uniforms, sh, 0)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipes[name][1])
	_rd.compute_list_bind_uniform_set(cl, set, 0)
	var b := pc.to_byte_array()
	_rd.compute_list_set_push_constant(cl, b, b.size())
	var g := maxi((n + 3) / 4, 1)
	_rd.compute_list_dispatch(cl, g, g, g)
	_rd.compute_list_end()


func _ground_tex() -> RID:
	return RenderingServer.texture_get_rd_texture(CloudGround.texture.get_rid())


func _model_uniforms() -> Array:
	return [_u_ubo(), _u_tex(1, _clamp_sampler, _ground_tex()), _u_tex(2, _repeat_sampler, _weather),
		_u_tex(3, _repeat_sampler, _shape), _u_tex(4, _repeat_sampler, _detail)]


func _usable() -> bool:
	if _blue_rid.is_valid():
		_blue = RenderingServer.texture_get_rd_texture(_blue_rid)
	return _pipes.size() >= 9 and _generated and _blue.is_valid() and _rd.texture_is_valid(_blue) and coverage > 0.001 and active


## Before the opaque pass: the parameters for this frame, the shadow map and the camera's sunlight.
func _shadow_callback(render_data: RenderData) -> void:
	_ready_frame = false
	if not _usable():
		cam_od = 0.0
		if _sh_info.is_valid():
			# no clouds: nothing casts a shadow (the terrain and trees read this flag)
			_rd.texture_update(_sh_info, 0, PackedFloat32Array([0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]).to_byte_array())
		return
	var sd := render_data.get_render_scene_data()
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if sd == null or buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_ensure_targets(size)
	_ensure_layer(size)
	var cam_xf := sd.get_cam_transform()
	var proj := sd.get_cam_projection()
	_frame += 1
	# (wall time, as the drift of the clouds: it wraps with the detail noise's own repeat, 420 m, so seamlessly)
	var ms := Time.get_ticks_msec()
	if _evolve_ms >= 0:
		_evolve = fmod(_evolve + evolve_rate * float(ms - _evolve_ms) * 0.001, 420.0)
	_evolve_ms = ms
	if _shift != Vector3.ZERO:
		# a point at new scene position p was at p + shift in last frame's scene
		_prev_vp = _prev_vp * Projection(Transform3D(Basis(), _shift))
		_shift = Vector3.ZERO
	var cam_map := Vector2(cam_xf.origin.x + WorldData.origin_x, cam_xf.origin.z + WorldData.origin_z)
	var full := [false, false]
	for c in 2:
		var half := SH0_HALF if c == 0 else SH1_HALF
		var n := SH0_N if c == 0 else SH1_N
		var snap := 2.0 * half / n * 32.0
		var centre := (cam_map / snap).round() * snap
		if centre != _sh_centre[c]:
			_sh_centre[c] = centre
			full[c] = true
	# the far-cloud maps: a finished copy takes over, then the next is begun around where the camera is now
	for c in 2:
		if _far_row[c] >= FAR_N:
			# finished: its mip levels (the march picks the level of each pixel's footprint: no aliasing far away)
			var fbk: int = 1 - _far_front[c]
			var msz := FAR_N
			for lv in range(1, _far_levels[c][fbk].size()):
				msz /= 2
				_dispatch("mip2d", [_u_image(0, _far_levels[c][fbk][lv - 1]), _u_image(1, _far_levels[c][fbk][lv])], Vector2i(msz, msz),
					PackedFloat32Array([float(msz), 0.0, 0.0, 0.0]))
			_far_front[c] = fbk
			_far_valid[c][fbk] = true
			_far_row[c] = 0
		if _far_row[c] == 0:
			var snap: float = 2.0 * FAR_HALF[c] / FAR_N * 16.0
			_far_centre[c][1 - _far_front[c]] = ((cam_map + wind) / snap).round() * snap
	_write_params(cam_xf, proj, size)
	for c in 2:
		var fb: int = 1 - _far_front[c]
		var fc: Vector2 = _far_centre[c][fb]
		_dispatch("far", _model_uniforms() + [_u_image(6, _far_levels[c][fb][0])], Vector2i(FAR_N, FAR_ROWS[c]),
			PackedFloat32Array([fc.x, fc.y, FAR_HALF[c], float(_far_row[c]), float(FAR_N), float(FAR_ROWS[c]), FAR_LOD[c], 0.0]))
		_far_row[c] += FAR_ROWS[c]
	var info := PackedFloat32Array([_sh_centre[0].x, _sh_centre[0].y, SH0_HALF, SH0_N,
		_sh_centre[1].x, _sh_centre[1].y, SH1_HALF, SH1_N,
		_slab_bottom(), 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	_rd.texture_update(_sh_info, 0, info.to_byte_array())
	_sh_phase = (_sh_phase + 1) % SH_ROWS
	if _cam_arrived:
		_cam_arrived = false
		_cam_pending = false
		if _cam_result >= 0.0:
			cam_od = _cam_result
			cam_od_valid = true
	elif _cam_pending and _frame - _cam_frame > 30:
		_cam_pending = false               # (a readback that never came back: ask again)
	var read_cam := not _cam_pending and not _no_readback
	for c in 2:
		var n := SH0_N if c == 0 else SH1_N
		var rows := 1 if full[c] else SH_ROWS
		var phase := 0 if full[c] else _sh_phase
		var u := _model_uniforms() + [_u_image(6, _sh[c]), _u_buf(7, _cam_buf)]
		_dispatch("shadow", u, Vector2i(n, n / rows), PackedFloat32Array([float(c), float(phase), float(rows), 1.0 if (read_cam and c == 0) else 0.0]))
	if read_cam:
		_cam_pending = true
		# a callback on the script, not on this effect: the readback can complete after the effect is gone (at quit),
		# and a callback into a freed object crashed the game on exit
		_cam_frame = _frame
		_rd.buffer_get_data_async(_cam_buf, Callable(get_script(), "_on_cam_light"))
	_ready_frame = true


static var _cam_result := -1.0
static var _cam_arrived := false


static func _on_cam_light(data: PackedByteArray) -> void:
	_cam_arrived = true
	if data.size() >= 4:
		_cam_result = data.decode_float(0)


## How much farther the march reaches with the camera's height above the cloud tops under it: 1 at and below
## them, up to 4 from 7.5 km above.
func range_scale(cam_y: float, cam_map: Vector2) -> float:
	var g: Vector2 = CloudGround.at(cam_map.x, cam_map.y)
	var top_here := lerpf(g.x, g.y, ground_mix) + top
	return clampf(1.0 + (cam_y - top_here) / 2500.0, 1.0, 4.0)


## The lowest any cloud can be (true height), and the highest.
func _slab_bottom() -> float:
	return CloudGround.lo + base - height_variation * 0.5
func _slab_top() -> float:
	return CloudGround.hi + base + (top - base) * 1.35 + height_variation


func _write_params(cam_xf: Transform3D, proj: Projection, size: Vector2i) -> void:
	var vp := proj * Projection(cam_xf.affine_inverse())
	var data := PackedFloat32Array()
	data.append_array(_proj_floats(proj.inverse()))
	data.append_array(_xform_floats(cam_xf))
	data.append_array(_proj_floats(_prev_vp))
	_prev_vp = vp
	# the noise offset moves opposite to the clouds; the world-space cloud movement this frame is its negation
	var wind_move := -(wind - _prev_wind) if _has_history else Vector2.ZERO
	_prev_wind = wind
	var shape := Vector4(coverage, density, base * 0.001, top * 0.001)
	var hw := history_weight if shape.distance_to(_prev_shape) < 0.0002 else minf(history_weight, 0.7)
	_prev_shape = shape
	data.append_array([cam_xf.origin.x, cam_xf.origin.y, cam_xf.origin.z, _evolve])
	data.append_array([WorldData.origin_x, WorldData.origin_z, float(_frame % 4096), 1.0 if _has_history else 0.0])
	data.append_array([sun_dir.x, sun_dir.y, sun_dir.z, light_intensity])
	data.append_array([sun_color.r, sun_color.g, sun_color.b, ambient])
	data.append_array([amb_top.r, amb_top.g, amb_top.b, hw])
	data.append_array([amb_bottom.r, amb_bottom.g, amb_bottom.b, height_variation])
	data.append_array([fog_color.r, fog_color.g, fog_color.b, fog_density])
	data.append_array([base, top, coverage, density])
	data.append_array([stratus, darkness, variability, cirrus])
	data.append_array([wind.x, wind.y, wind_move.x, wind_move.y])
	var dv := 4 if resolution_div >= 4 else 2
	var hs := Vector2i(maxi((size.x + dv - 1) / dv, 1), maxi((size.y + dv - 1) / dv, 1))
	data.append_array([float(hs.x), float(hs.y), float(size.x), float(size.y)])
	# a longer march from high up (range_scale) gets more steps to go with it, or it runs out before its end
	var sk := range_scale(cam_xf.origin.y, Vector2(cam_xf.origin.x + WorldData.origin_x, cam_xf.origin.z + WorldData.origin_z))
	data.append_array([float(primary_steps), float(light_steps), float(max_iterations) * minf(sk, 2.5), float(max_dense) * minf(sk, 2.0)])
	data.append_array([hor_toward.r, hor_toward.g, hor_toward.b, sun_xz.x])
	data.append_array([hor_away.r, hor_away.g, hor_away.b, sun_xz.y])
	# the ground the layers stand on, and the Earth's curvature (the clouds sink with distance as the terrain does)
	var curve := WorldData.EARTH_CURVE if WorldData.is_large() else 0.0
	data.append_array([ground_mix, CloudGround.lo, CloudGround.hi, curve])
	var gr: Vector4 = CloudGround.rect
	data.append_array([gr.x, gr.y, gr.z, gr.w])
	data.append_array([_sh_centre[0].x, _sh_centre[0].y, SH0_HALF, float(SH0_N)])
	data.append_array([_sh_centre[1].x, _sh_centre[1].y, SH1_HALF, float(SH1_N)])
	# far reach: to the horizon (from high up, hundreds of km)
	var reach := clampf(sqrt(maxf(cam_xf.origin.y + 2000.0, 0.0) / maxf(curve, 1e-9)) * 1.5, 120000.0, 450000.0) if curve > 0.0 else 120000.0
	# the higher above the clouds, the farther the full march and its detail reach: from up there every cloud is
	# far away, and each ray crosses the layer only once (the empty air above it is skipped), so it costs little
	var rk := range_scale(cam_xf.origin.y, Vector2(cam_xf.origin.x + WorldData.origin_x, cam_xf.origin.z + WorldData.origin_z))
	data.append_array([near_end * rk, march_end * rk, reach, float(_dbg_mode)])
	var pix := 2.0 / (absf(proj.y.y) * float(hs.y))
	data.append_array([CIRRUS_HEIGHT, cirrus, pix, _slab_bottom()])
	var lights := _lights(cam_xf.origin)
	data.append_array([float(lights.size()), _slab_top(), 0.0, 0.0])
	for c in 2:
		var ff: Vector2 = _far_centre[c][_far_front[c]]
		data.append_array([ff.x, ff.y, FAR_HALF[c], 1.0 if _far_valid[c][_far_front[c]] else 0.0])
	for k in 3:
		for i in 4:
			if i < lights.size():
				data.append_array(lights[i][k])
			else:
				data.append_array([0.0, 0.0, 0.0, 0.0])
	var bytes := data.to_byte_array()
	_rd.buffer_update(_ubo, 0, bytes.size(), bytes)


# ---- local lights: lamps near the camera light the cloud around them (scripts/aircraft/aircraft_effects.gd) ----
static var _lamps: Array = []
static var _lamp_snapshot: Array = []


## Lamps that light the clouds near them (an afterburner's glow, a landing light). Weakly held.
static func register_lamp(light: Light3D) -> void:
	_lamps.append(weakref(light))


## From the main thread each frame (scripts/world/sky_system.gd): the four brightest lamps near the camera.
static func gather_lamps(cam_pos: Vector3) -> void:
	var out := []
	var i := 0
	while i < _lamps.size():
		var l: Light3D = _lamps[i].get_ref()
		if l == null:
			_lamps.remove_at(i)
			continue
		i += 1
		if not l.is_visible_in_tree() or l.light_energy <= 0.01:
			continue
		var p := l.global_position
		var d := p.distance_to(cam_pos)
		if d > 800.0:
			continue
		var col := l.light_color * l.light_energy * 30.0
		var range := 260.0
		var cosc := -2.0
		var dir := Vector3.ZERO
		if l is SpotLight3D:
			cosc = cos(deg_to_rad((l as SpotLight3D).spot_angle))
			dir = -l.global_transform.basis.z
			range = 600.0
		out.append([d, [p.x, p.y, p.z, range], [col.r, col.g, col.b, cosc], [dir.x, dir.y, dir.z, 0.0]])
	out.sort_custom(func(a, b): return a[0] < b[0])
	var snap := []
	for k in mini(out.size(), 4):
		snap.append(out[k].slice(1))
	_lamp_snapshot = snap


func _lights(_cam: Vector3) -> Array:
	return _lamp_snapshot      # [pos, col, dir] per lamp (gather_lamps)


func _render_callback(_type: int, render_data: RenderData) -> void:
	if _dbg:
		_dbg_n += 1
		if _dbg_n % 240 == 1:
			print("CLOUDDBG pipes %d gen %s cov %.2f active %s base %.0f top %.0f gmix %.2f ground %.0f..%.0f size %s cam_od %.2f" % [_pipes.size(), _generated, coverage, active, base, top, ground_mix, CloudGround.lo, CloudGround.hi, str(_half_size), cam_od])
	if not _usable() or not _ready_frame:
		_has_history = false
		if _layer.is_valid():
			_rd.texture_clear(_layer, Color(1.0, 60000.0, 60000.0, 1.0), 0, 1, 0, 1)   # clear sky: nothing hides
		if _overlay.is_valid():
			_rd.texture_clear(_overlay, Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)    # and nothing is drawn
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	_cur = 1 - _cur
	for view in buffers.get_view_count():
		var depth := buffers.get_depth_layer(view)
		_dispatch("march", _model_uniforms() + [_u_tex(5, _point_sampler, _blue), _u_tex(6, _point_sampler, depth),
			_u_tex(7, _clamp_sampler, _sh[0]), _u_tex(8, _clamp_sampler, _sh[1]),
			_u_image(9, _raw_color), _u_image(10, _raw_depth), _u_tex(11, _clamp_sampler, _far[0][_far_front[0]]),
			_u_tex(12, _clamp_sampler, _far[1][_far_front[1]])], _half_size)
		_dispatch("resolve", [_u_ubo(), _u_image(1, _hist_color[_cur]), _u_image(2, _hist_depth[_cur]),
			_u_tex(3, _point_sampler, _raw_color), _u_tex(4, _point_sampler, _raw_depth),
			_u_tex(5, _clamp_sampler, _hist_color[1 - _cur]), _u_tex(6, _point_sampler, _hist_depth[1 - _cur])], _half_size)
		_dispatch("composite", [_u_ubo(), _u_image(1, _overlay), _u_tex(2, _point_sampler, _hist_color[_cur]),
			_u_tex(3, _point_sampler, _hist_depth[_cur]), _u_tex(4, _point_sampler, depth),
			_u_image(5, _layer)], size)
	_has_history = true
