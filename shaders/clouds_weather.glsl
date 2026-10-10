#[compute]
#version 450
// The weather map (scripts/world/volumetric_clouds.gd): one texture for the whole map (400 m texels, tiling every
// 410 km, larger than Kashmir, so nothing repeats in sight), generated once from a fixed seed, so every player sees
// the same clouds. The weather preset sets the means; this map says how they vary across the land:
//   r  regional coverage: where the sky is fuller or clearer (features of 30 to 80 km, domain-warped so they are
//      not blobs)
//   g  cloud type: stretches of cumulus, stratocumulus and stratus (features of about 100 km)
//   b  height and density: where the layer sits higher and thicker (about 40 km)
//   a  cumulus clustering: where the individual cumulus gather into fields and streets (2 to 6 km), and where they
//      tower
// All four are 0..1 around a mean of 0.5.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image2D out_img;
layout(push_constant, std430) uniform PC {
	vec4 a;            // x size, y seed
} pc;

vec2 h22(vec2 c) {
	vec3 q = fract(vec3(c.xyx) * vec3(0.1031, 0.1030, 0.0973) + pc.a.y * 0.0173);
	q += dot(q, q.yzx + 33.33);
	return fract((q.xx + q.yz) * q.zy);
}

// tiling gradient noise, `period` cells across the map
float gnoise(vec2 x, float period) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 g00 = normalize(h22(mod(i, period)) * 2.0 - 1.0 + 1e-4);
	vec2 g10 = normalize(h22(mod(i + vec2(1, 0), period)) * 2.0 - 1.0 + 1e-4);
	vec2 g01 = normalize(h22(mod(i + vec2(0, 1), period)) * 2.0 - 1.0 + 1e-4);
	vec2 g11 = normalize(h22(mod(i + vec2(1, 1), period)) * 2.0 - 1.0 + 1e-4);
	float n00 = dot(g00, f);
	float n10 = dot(g10, f - vec2(1, 0));
	float n01 = dot(g01, f - vec2(0, 1));
	float n11 = dot(g11, f - vec2(1, 1));
	return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y);
}

float fbm(vec2 uv, float freq, int oct) {
	float s = 0.0;
	float a = 0.5;
	float n = 0.0;
	float f = freq;
	for (int o = 0; o < oct; o++) {
		s += gnoise(uv * f, f) * a;
		n += a;
		f *= 2.0;
		a *= 0.5;
	}
	return s / n;
}

float to01(float v, float k) {
	return clamp(v * k + 0.5, 0.0, 1.0);
}

// tiling Worley, inverted (1 at the cell's point)
float worley(vec2 x, float period) {
	vec2 i = floor(x);
	vec2 f = fract(x);
	float d = 1e9;
	for (int y = -1; y <= 1; y++) {
		for (int xx = -1; xx <= 1; xx++) {
			vec2 o = vec2(xx, y);
			vec2 pt = o + h22(mod(i + o, period) + 41.0);
			vec2 v = pt - f;
			d = min(d, dot(v, v));
		}
	}
	return 1.0 - clamp(sqrt(d), 0.0, 1.0);
}

void main() {
	int n = int(pc.a.x);
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(id, ivec2(n)))) {
		return;
	}
	vec2 uv = (vec2(id) + 0.5) / float(n);
	// domain warp: the regions take irregular, wind-blown shapes
	vec2 warp = vec2(fbm(uv + 3.1, 6.0, 4), fbm(uv + 7.7, 6.0, 4)) * 0.06;
	float r = to01(fbm(uv + warp, 6.0, 5), 1.7);
	float g = to01(fbm(uv + warp * 0.5 + 11.3, 3.0, 4), 1.6);
	float b = to01(fbm(uv + 23.9, 10.0, 4), 1.6);
	// cumulus fields: cells of a few km (Worley), broken up and stretched into streets by the warp
	vec2 uw = uv + warp * 0.35 + vec2(fbm(uv + 5.3, 40.0, 3), fbm(uv + 9.1, 40.0, 3)) * 0.004;
	float a = worley(uw * 128.0, 128.0) * 0.6 + worley(uw * 256.0, 256.0) * 0.4;
	a = clamp((a - 0.45) * 1.8 + 0.5, 0.0, 1.0);
	a = mix(a, to01(fbm(uv, 64.0, 3), 1.6), 0.3);
	imageStore(out_img, id, vec4(r, g, b, a));
}
