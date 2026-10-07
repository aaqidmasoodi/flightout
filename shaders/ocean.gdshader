shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;
// Ocean: animated normal-only waves (cheap at any size), fresnel-ish look, shallow-water tint from scene depth.

uniform vec3 deep_color : source_color = vec3(0.015, 0.08, 0.15);
uniform vec3 shallow_color : source_color = vec3(0.09, 0.38, 0.42);
uniform float shallow_depth = 14.0;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float waves(vec2 p, float t) {
	float h = vnoise(p * 0.015 + vec2(t * 0.04, t * 0.025));
	h += vnoise(p * 0.06 - vec2(t * 0.08, -t * 0.05)) * 0.5;
	h += vnoise(p * 0.22 + vec2(t * 0.18, t * 0.12)) * 0.22;
	h += vnoise(p * 0.8 - vec2(t * 0.35, t * 0.28)) * 0.08;
	return h;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	float t = TIME;
	float e = 0.6;
	float dist = length(CAMERA_POSITION_WORLD - wpos);
	float strength = mix(3.0, 0.4, clamp(dist / 6000.0, 0.0, 1.0));
	float hx = waves(p - vec2(e, 0.0), t) - waves(p + vec2(e, 0.0), t);
	float hz = waves(p - vec2(0.0, e), t) - waves(p + vec2(0.0, e), t);
	vec3 n_world = normalize(vec3(hx * strength, 2.0 * e, hz * strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float thickness = clamp((-view.z - (-VERTEX.z)) / shallow_depth, 0.0, 1.0);

	ALBEDO = mix(shallow_color, deep_color, thickness);
	ALPHA = mix(0.6, 0.97, thickness);
	ROUGHNESS = 0.05;
	SPECULAR = 0.55;
}
