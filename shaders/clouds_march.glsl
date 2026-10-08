#[compute]
#version 450
// Pass 1: volumetric clouds raymarched at half resolution.
// out_color: rgb = in-scattered light, a = transmittance.  out_depth: x = cloud start distance, y = cloud end distance
// (1e9 when the ray meets no cloud). The composite pass uses these distances against each full-resolution pixel's
// exact depth, so clouds behind an object can never be drawn over it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D out_color;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 2) uniform sampler3D perlin_tex;
layout(set = 0, binding = 3) uniform sampler3D worley_tex;
layout(set = 0, binding = 4) uniform sampler3D detail_tex;
layout(set = 0, binding = 5) uniform sampler2D weather_tex;
layout(set = 0, binding = 6, std140) uniform Params {
	mat4 inv_proj;
	mat4 cam_xform;        // camera to world
	vec4 cam_pos;          // xyz, w = time
	vec4 sun_dir;          // xyz towards the light, w = light intensity
	vec4 sun_color;        // rgb, w = ambient strength
	vec4 amb_top;          // rgb sky light from above
	vec4 amb_bottom;       // rgb light from below (ground bounce)
	vec4 fog;              // rgb fog colour, w = fog density
	vec4 layer;            // x base, y top, z coverage, w density
	vec4 shape;            // x stratus (0 cumulus .. 1 stratus), y darkness, z wind x offset, w wind z offset
	vec4 sizes;            // x half width, y half height, z full width, w full height
	vec4 misc;             // x max distance, y frame, z primary steps, w light steps
	mat4 prev_vp;          // last frame's view-projection, for reprojection
	vec4 misc2;            // x history valid, y history weight, z height variation (m)
} p;

layout(rg32f, set = 0, binding = 7) uniform restrict writeonly image2D out_depth;
layout(set = 0, binding = 8) uniform sampler2D blue_noise;     // 64x64 void-and-cluster blue noise

const float NO_CLOUD = 1e9;

float remap(float v, float a, float b, float c, float d) {
	return c + (clamp(v, a, b) - a) / max(b - a, 1e-5) * (d - c);
}

float height_profile(float h) {
	float cu = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.35, 1.0, h));
	float st = smoothstep(0.0, 0.05, h) * (1.0 - smoothstep(0.55, 0.9, h));
	return mix(cu, st, p.shape.x);
}

float cloud_density(vec3 pos, bool cheap, float detail_amt) {
	vec2 wind = p.shape.zw;
	float hv = texture(weather_tex, (pos.xz + wind) / 9000.0 + vec2(0.37, 0.11)).r - 0.5;
	float tv = texture(weather_tex, (pos.xz + wind) / 4200.0 + vec2(0.71, 0.53)).r - 0.5;
	float base = p.layer.x + hv * p.misc2.z;
	float top = p.layer.y + hv * p.misc2.z * 0.7 + tv * p.misc2.z * 1.6 * (1.0 - p.shape.x * 0.7);
	float h = (pos.y - base) / max(top - base, 50.0);
	if (h <= 0.0 || h >= 1.0) {
		return 0.0;
	}
	float weather = texture(weather_tex, (pos.xz + wind) / 26000.0).r;
	weather = mix(weather, 1.0, p.shape.x * 0.6);
	float cov = clamp(p.layer.z * 1.18, 0.0, 1.0);
	vec3 q = (pos + vec3(wind.x, 0.0, wind.y)) / 5200.0;
	float pn = texture(perlin_tex, q).r;
	float wn = texture(worley_tex, q * 1.7).r;
	float base_shape = remap(pn * 0.55 + wn * 0.6, 0.18, 1.0, 0.0, 1.0);
	float d = base_shape * height_profile(h);
	d = remap(d, 1.0 - cov * mix(0.6, 1.05, weather), 1.0, 0.0, 1.0);
	d *= mix(0.25, 1.0, weather);
	if (d <= 0.0) {
		return 0.0;
	}
	if (!cheap && detail_amt > 0.0) {
		float det = texture(detail_tex, (pos + vec3(wind.x * 1.4, 0.0, wind.y * 1.4)) / 620.0).r;
		float erode = mix(det, 1.0 - det, clamp(h * 4.0, 0.0, 1.0));
		d = remap(d, erode * 0.45 * detail_amt, 1.0, 0.0, 1.0);
	}
	return max(d, 0.0) * p.layer.w;
}

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

float white(uvec2 px) {
	uint v = px.x * 1973u + px.y * 9277u + 26699u;
	v = v * 747796405u + 2891336453u;
	uint w = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
	w = (w >> 22u) ^ w;
	return float(w) / 4294967295.0;
}

// distance to the scene for a full-resolution texel (reverse-Z: 0 = sky)
float scene_distance(ivec2 fpx) {
	float dz = texelFetch(depth_tex, fpx, 0).r;
	if (dz <= 0.0) {
		return NO_CLOUD;
	}
	vec2 fuv = (vec2(fpx) + 0.5) / p.sizes.zw;
	vec4 v = p.inv_proj * vec4(fuv * 2.0 - 1.0, dz, 1.0);
	return length(v.xyz / v.w);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 hsize = ivec2(p.sizes.xy);
	if (px.x >= hsize.x || px.y >= hsize.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(hsize);
	// march as far as the farthest of the 2x2 full-resolution pixels this texel covers; the composite trims it
	// back per pixel, so the background beside an object still gets its clouds
	ivec2 f0 = px * 2;
	ivec2 fmax = ivec2(p.sizes.zw) - 1;
	float scene_dist = max(max(scene_distance(min(f0, fmax)), scene_distance(min(f0 + ivec2(1, 0), fmax))),
		max(scene_distance(min(f0 + ivec2(0, 1), fmax)), scene_distance(min(f0 + ivec2(1, 1), fmax))));
	vec4 vfar = p.inv_proj * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
	vec3 ro = p.cam_pos.xyz;
	vec3 rd = normalize(mat3(p.cam_xform) * normalize(vfar.xyz / vfar.w));
	float max_dist = min(scene_dist, p.misc.x);

	float base = p.layer.x - p.misc2.z * 0.5;
	float top = p.layer.y + p.misc2.z * 1.2;
	float t0, t1;
	if (abs(rd.y) < 1e-4) {
		t0 = (ro.y < base || ro.y > top) ? 1.0 : 0.0;
		t1 = (ro.y < base || ro.y > top) ? 0.0 : max_dist;
	} else {
		float ta = (base - ro.y) / rd.y;
		float tb = (top - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = max(ta, tb);
	}
	t1 = min(t1, max_dist);
	if (t1 <= t0 || p.layer.z <= 0.001) {
		imageStore(out_color, px, vec4(0.0, 0.0, 0.0, 1.0));
		imageStore(out_depth, px, vec4(NO_CLOUD, NO_CLOUD, 0.0, 0.0));
		return;
	}

	int steps = int(p.misc.z);
	float seg = t1 - t0;
	float dt = clamp(seg / float(steps), 25.0, 380.0);
	// blue-noise offset per pixel (evenly spread, no visible pattern), advanced each frame by the golden ratio
	float jitter = fract(texelFetch(blue_noise, px % 64, 0).r + p.misc.y * 0.61803398875);
	float t = t0 + dt * jitter;
	vec3 L = normalize(p.sun_dir.xyz);
	float cos_t = dot(rd, L);
	vec3 S = vec3(0.0);
	float T = 1.0;
	float first = NO_CLOUD;
	float last = NO_CLOUD;
	float ext_k = 0.075;
	int light_steps = int(p.misc.w);
	// adaptive stepping (Nubis): large cheap steps through empty air; on touching cloud, step back and march it in
	// small steps, so thin clouds can never fall between two samples (the source of hit-or-miss noise)
	int fine_left = 0;
	int expensive = 0;
	float last_step = dt;
	for (int i = 0; i < 320; i++) {
		if (t > t1 || T < 0.01 || expensive >= 96) {
			break;
		}
		float big = dt * (1.0 + t / 7000.0);
		// fine steps near the camera; far away the clouds are small on screen and the resolve hides the rest
		float fine = clamp(big * 0.35, 30.0, 160.0) * (1.0 + t / 9000.0);
		vec3 pos = ro + rd * t;
		float cheap = cloud_density(pos, true, 0.0);
		if (fine_left == 0) {
			if (cheap > 0.0 && t - big > t0 - 1.0) {
				t = max(t - big, t0);       // step back to the last empty sample, then walk in finely
				fine_left = 6;
				continue;
			}
			if (cheap > 0.0) {
				fine_left = 6;
			} else {
				t += big;
				continue;
			}
		}
		float step_here = fine;
		last_step = step_here;
		if (cheap <= 0.0) {
			fine_left--;
			t += step_here;
			continue;
		}
		fine_left = 6;
		expensive++;
		float detail_amt = 1.0 - smoothstep(4000.0, 12000.0, t);
		float dens = cloud_density(pos, false, detail_amt);
		if (dens > 0.0) {
			if (first >= NO_CLOUD) {
				first = t;
			}
			last = t;
			float od = 0.0;
			float ls = 70.0;
			for (int j = 0; j < light_steps; j++) {
				vec3 lp = pos + L * (ls * (float(j) + 0.5));
				od += cloud_density(lp, j > 0, detail_amt) * ls;
				ls *= 2.1;
			}
			float hgt = clamp((pos.y - p.layer.x) / (p.layer.y - p.layer.x), 0.0, 1.0);
			float powder = 1.0 - exp(-dens * ext_k * 140.0);
			float sun_light = 0.0;
			float oa = 1.0;
			float ob = 1.0;
			float oc = 1.0;
			for (int o = 0; o < 3; o++) {
				float ph = mix(hg(cos_t, 0.6 * oc), hg(cos_t, -0.25 * oc), 0.3) * 4.0 * 3.14159265;
				sun_light += oa * mix(1.0, ph, 0.85) * exp(-od * ext_k * ob);
				oa *= 0.5;
				ob *= 0.45;
				oc *= 0.5;
			}
			sun_light *= mix(0.45, 1.0, powder);
			float self_occ = exp(-dens * 1.4);
			vec3 amb = mix(p.amb_bottom.rgb, p.amb_top.rgb, hgt) * p.sun_color.w * mix(0.55, 1.0, self_occ);
			vec3 lum = p.sun_color.rgb * p.sun_dir.w * sun_light + amb;
			lum *= 1.0 - p.shape.y * (1.0 - hgt * 0.6);
			float sigma = max(dens * ext_k, 1e-6);
			float tr = exp(-sigma * step_here);
			S += T * lum * (1.0 - tr);
			T *= tr;
		}
		t += step_here;
	}
	if (first < NO_CLOUD) {
		float f = 1.0 - exp(-p.fog.w * first * 0.85);
		S = mix(S, p.fog.rgb * (1.0 - T), f);
	}
	imageStore(out_color, px, vec4(S, T));
	imageStore(out_depth, px, vec4(first, last + last_step, 0.0, 0.0));
}
