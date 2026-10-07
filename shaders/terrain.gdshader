shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Procedural terrain shading: sand, grass, forest, rock and snow by height, slope and noise.

uniform sampler2D forest_mask : filter_linear, repeat_disable;
uniform float map_half_extent = 20480.0;

varying vec3 wpos;
varying vec3 wnorm;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float s = 0.0; float a = 0.5;
	for (int i = 0; i < 4; i++) { s += vnoise(p) * a; p *= 2.03; a *= 0.5; }
	return s / 0.9375;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float h = wpos.y;
	float slope = 1.0 - clamp(wnorm.y, 0.0, 1.0);
	vec2 p = wpos.xz;
	float n_big = fbm(p * 0.0012);
	float n_mid = fbm(p * 0.018);
	float n_fine = vnoise(p * 0.4) * 0.6 + vnoise(p * 1.7) * 0.4;
	float dist = length(CAMERA_POSITION_WORLD - wpos);

	vec3 sand = vec3(0.74, 0.68, 0.50);
	vec3 grass = mix(vec3(0.26, 0.38, 0.14), vec3(0.42, 0.47, 0.20), n_mid);
	grass = mix(grass, vec3(0.50, 0.48, 0.26), smoothstep(0.62, 0.8, n_big) * 0.6);
	vec3 forest = mix(vec3(0.08, 0.16, 0.06), vec3(0.12, 0.21, 0.08), n_mid);
	vec3 rock = mix(vec3(0.36, 0.34, 0.31), vec3(0.52, 0.49, 0.45), n_mid);
	vec3 snow = vec3(0.92, 0.94, 0.97);
	vec3 seabed = vec3(0.50, 0.46, 0.34);

	vec2 muv = (p + vec2(map_half_extent)) / (2.0 * map_half_extent);
	float fm = texture(forest_mask, muv).r;
	float forest_amt = smoothstep(0.50, 0.58, fm) * smoothstep(20.0, 35.0, h) * (1.0 - smoothstep(850.0, 1000.0, h)) * (1.0 - smoothstep(0.12, 0.2, slope));

	vec3 c = mix(grass, forest, forest_amt);
	float rock_amt = clamp(smoothstep(0.22, 0.42, slope) + smoothstep(1050.0, 1350.0, h + (n_mid - 0.5) * 150.0), 0.0, 1.0);
	c = mix(c, rock, rock_amt);
	float snow_line = 1420.0 + (n_mid - 0.5) * 220.0;
	float snow_amt = smoothstep(snow_line, snow_line + 120.0, h) * (1.0 - smoothstep(0.45, 0.7, slope));
	c = mix(c, snow, snow_amt);
	c = mix(sand, c, smoothstep(2.0, 9.0, h + (n_mid - 0.5) * 5.0));
	c = mix(seabed * 0.75, c, smoothstep(-8.0, 0.5, h));

	// close-up detail fades out with distance to avoid shimmer
	float detail = mix(0.8 + 0.4 * n_fine, 1.0, clamp(dist / 3000.0, 0.0, 1.0));
	ALBEDO = c * detail;
	ROUGHNESS = mix(0.95, 0.55, snow_amt);
}
