shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;
// Soft cloud deck for the menu backdrop, lit from a low sun.

uniform vec2 scroll = vec2(0.0);
uniform vec3 lit : source_color = vec3(1.0, 0.80, 0.62);
uniform vec3 shade : source_color = vec3(0.42, 0.46, 0.58);
uniform float coverage = 0.48;

varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0; float a = 0.5;
	for (int i = 0; i < 5; i++) { s += vnoise(p) * a; p = p * 2.07 + vec2(1.7, 9.2); a *= 0.5; }
	return s;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = (wpos.xz + scroll) * 0.0011;
	float n = fbm(p);
	float detail = fbm(p * 3.3 + vec2(TIME * 0.01, 0.0));
	float d = smoothstep(coverage, coverage + 0.22, n * 0.8 + detail * 0.3);
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(9000.0, 30000.0, dist);
	ALBEDO = mix(shade, lit, smoothstep(0.35, 0.85, detail));
	ALPHA = d * fade * 0.94;
}
