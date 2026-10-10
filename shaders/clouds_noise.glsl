#[compute]
#version 450
// The clouds' noise volumes, generated on the GPU once at start (scripts/world/volumetric_clouds.gd), tiling in
// every direction:
//   shape  (128^3): r Perlin-Worley (billowy, the body of the clouds), g b a Worley at three frequencies (fbm
//          erosion of the body)
//   detail (64^3):  r g b Worley at three higher frequencies (the edges)
// The mip levels are built afterwards (clouds_mip.glsl).

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image3D out_img;
layout(push_constant, std430) uniform PC {
	vec4 a;            // x size, y mode (0 shape, 1 detail), z seed
} pc;

float h31(vec3 c) {
	c = fract(c * vec3(0.1031, 0.1030, 0.0973) + pc.a.z * 0.0137);
	c += dot(c, c.yxz + 33.33);
	return fract((c.x + c.y) * c.z);
}

vec3 h33(vec3 c) {
	c = fract(c * vec3(0.1031, 0.1030, 0.0973) + pc.a.z * 0.0137);
	c += dot(c, c.yxz + 33.33);
	return fract((c.xxy + c.yxx) * c.zyx);
}

// tiling gradient noise with `period` cells across the volume
float gnoise(vec3 x, float period) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float r = 0.0;
	float n[8];
	for (int k = 0; k < 8; k++) {
		vec3 o = vec3(k & 1, (k >> 1) & 1, (k >> 2) & 1);
		vec3 c = mod(i + o, period);
		vec3 g = normalize(h33(c) * 2.0 - 1.0 + 1e-4);
		n[k] = dot(g, f - o);
	}
	float x00 = mix(n[0], n[1], u.x);
	float x10 = mix(n[2], n[3], u.x);
	float x01 = mix(n[4], n[5], u.x);
	float x11 = mix(n[6], n[7], u.x);
	r = mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
	return r;
}

// tiling Worley noise (distance to the nearest feature point), inverted: 1 at the points, 0 between
float worley(vec3 x, float period) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	float d = 1e9;
	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int xx = -1; xx <= 1; xx++) {
				vec3 o = vec3(xx, y, z);
				vec3 c = mod(i + o, period);
				vec3 pt = o + h33(c + 17.0);
				vec3 v = pt - f;
				d = min(d, dot(v, v));
			}
		}
	}
	return 1.0 - clamp(sqrt(d), 0.0, 1.0);
}

// Octaves no finer than four texels per cell (size / 4 cells across the volume): finer ones cannot be held by the
// texels and alias into regular stripes (stretched upright for cumulus towers, they showed as horizontal ripples).
float max_freq() {
	return pc.a.x / 4.0;
}

float worley_fbm(vec3 uvw, float freq) {
	float s = 0.0;
	float n = 0.0;
	float a = 0.625;
	float f = freq;
	for (int o = 0; o < 3; o++) {
		if (f <= max_freq()) {
			s += worley(uvw * f, f) * a;
			n += a;
		}
		f *= 2.0;
		a *= 0.4;
	}
	return n > 0.0 ? s / n : 0.5;
}

float perlin_fbm(vec3 uvw, float freq) {
	float s = 0.0;
	float a = 0.5;
	float f = freq;
	for (int o = 0; o < 5; o++) {
		if (f <= max_freq()) {
			s += gnoise(uvw * f, f) * a;
		}
		f *= 2.0;
		a *= 0.5;
	}
	return clamp(s * 1.15 + 0.5, 0.0, 1.0);
}

float remap(float v, float a, float b, float c, float d) {
	return c + (v - a) / max(b - a, 1e-5) * (d - c);
}

void main() {
	int n = int(pc.a.x);
	ivec3 id = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(id, ivec3(n)))) {
		return;
	}
	vec3 uvw = (vec3(id) + 0.5) / float(n);
	vec4 o;
	if (pc.a.y < 0.5) {
		float pn = perlin_fbm(uvw, 4.0);
		float wn = worley_fbm(uvw, 4.0);
		// Perlin-Worley: Perlin's continuity with Worley's billows (Schneider, Nubis)
		float pw = clamp(remap(pn, wn - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0);
		o = vec4(pw, worley_fbm(uvw, 4.0), worley_fbm(uvw, 8.0), worley_fbm(uvw, 16.0));
	} else {
		o = vec4(worley_fbm(uvw, 4.0), worley_fbm(uvw, 8.0), worley_fbm(uvw, 16.0), 1.0);
	}
	imageStore(out_img, id, o);
}
