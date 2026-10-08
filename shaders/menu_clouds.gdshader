shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;
// Soft cloud deck for the menu backdrop, from a smooth mipmapped noise texture at two scales.

uniform vec2 scroll = vec2(0.0);
uniform vec3 lit : source_color = vec3(1.0, 0.80, 0.62);
uniform vec3 shade : source_color = vec3(0.42, 0.46, 0.58);
uniform float coverage = 0.46;
uniform sampler2D cloud_tex : filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz + scroll;
	float big = texture(cloud_tex, p / 9000.0).r;
	float detail = texture(cloud_tex, p / 2300.0 + vec2(TIME * 0.0015, 0.0)).r;
	float n = big * 0.72 + detail * 0.38;
	float d = smoothstep(coverage, coverage + 0.24, n);
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(9000.0, 30000.0, dist);
	ALBEDO = mix(shade, lit, smoothstep(0.3, 0.8, detail));
	ALPHA = d * fade * 0.94;
}
