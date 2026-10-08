shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, skip_vertex_transform;
// One cloud puff: a camera-facing soft sprite, lit by hand (sunlit top, shaded base, forward-scattered silver
// lining), drifted by the wind and wrapped around the map. Fades softly into terrain and as the camera gets close.

uniform sampler2D puff_atlas : source_color, filter_linear_mipmap, repeat_disable;   // 2x2 puff shapes
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0);
uniform vec3 lit_color : source_color = vec3(1.0);
uniform vec3 shade_color : source_color = vec3(0.6, 0.65, 0.72);
uniform float darkness = 0.0;          // storms darken the cloud body
uniform vec2 drift = vec2(0.0);
uniform vec2 area_min = vec2(-36000.0);
uniform vec2 area_size = vec2(72000.0);
uniform float coverage = 0.4;           // clusters with a threshold above this are hidden
uniform float far_fade = 30000.0;

varying float v_height;
varying float v_alpha;
varying vec3 v_wpos;
varying float v_size;

void vertex() {
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float size = length(MODEL_MATRIX[0].xyz);
	centre.xz = area_min + mod(centre.xz + drift - area_min, area_size);
	float ang = INSTANCE_CUSTOM.y * 6.2831;
	vec2 v = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang))) * VERTEX.xy;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world = centre + (right * v.x + up * v.y) * size;
	v_wpos = world;
	v_size = size;
	v_height = INSTANCE_CUSTOM.x;
	float cam_d = length(CAMERA_POSITION_WORLD - centre);
	float shown = step(INSTANCE_CUSTOM.w, coverage);
	v_alpha = shown
		* smoothstep(size * 0.35, size * 1.1, cam_d)                       // never a screen-filling sheet up close
		* (1.0 - smoothstep(far_fade * 0.7, far_fade, cam_d));
	vec4 view = VIEW_MATRIX * vec4(world, 1.0);
	VERTEX = view.xyz;
	POSITION = PROJECTION_MATRIX * view;
	// atlas cell
	vec2 cell = vec2(mod(floor(INSTANCE_CUSTOM.z * 4.0), 2.0), floor(INSTANCE_CUSTOM.z * 2.0));
	UV = (UV + cell) * 0.5;
}

void fragment() {
	if (v_alpha <= 0.001) {
		discard;
	}
	vec4 p = texture(puff_atlas, UV);
	float a = p.a * v_alpha;
	// soft intersection with terrain, sea and aircraft
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	vec4 scene = INV_PROJECTION_MATRIX * ndc;
	scene.xyz /= scene.w;
	a *= clamp((VERTEX.z - scene.z) / (v_size * 0.25), 0.0, 1.0);
	if (a < 0.004) {
		discard;
	}
	// lighting: top lit, base shaded, internal shading from the puff texture, forward scattering toward the sun
	vec3 vdir = normalize(v_wpos - CAMERA_POSITION_WORLD);
	float fwd = pow(max(dot(vdir, normalize(sun_dir)), 0.0), 8.0);
	float body = clamp(v_height * 0.75 + p.r * 0.45, 0.0, 1.0);
	vec3 c = mix(shade_color, lit_color * sun_color, body);
	c *= 1.0 - darkness * (1.0 - body * 0.5);
	c += sun_color * fwd * (1.0 - p.a) * 1.6 * (1.0 - darkness);
	ALBEDO = c;
	ALPHA = a;
}
