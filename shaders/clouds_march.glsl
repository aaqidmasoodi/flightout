#[compute]
#version 450
// Volumetric clouds, raymarched at half resolution.
// Output: rgb = in-scattered light (already attenuated), a = transmittance of the scene behind.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D out_img;
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
} p;

float remap(float v, float a, float b, float c, float d) {
	return c + (clamp(v, a, b) - a) / max(b - a, 1e-5) * (d - c);
}

float height_profile(float h) {
	// cumulus: rounded top, flat-ish base; stratus: a flatter, uniform slab
	float cu = smoothstep(0.0, 0.08, h) * (1.0 - smoothstep(0.35, 1.0, h));
	float st = smoothstep(0.0, 0.05, h) * (1.0 - smoothstep(0.55, 0.9, h));
	return mix(cu, st, p.shape.x);
}

float cloud_density(vec3 pos, bool cheap) {
	float base = p.layer.x;
	float top = p.layer.y;
	float h = (pos.y - base) / (top - base);
	if (h <= 0.0 || h >= 1.0) {
		return 0.0;
	}
	vec2 wind = p.shape.zw;
	vec2 wuv = (pos.xz + wind) / 26000.0;
	float weather = texture(weather_tex, wuv).r;
	weather = mix(weather, 1.0, p.shape.x * 0.6);
	float cov = clamp(p.layer.z * 1.18, 0.0, 1.0);
	vec3 q = (pos + vec3(wind.x, 0.0, wind.y)) / 5200.0;
	float pn = texture(perlin_tex, q).r;
	float wn = texture(worley_tex, q * 1.7).r;
	// Perlin-Worley: billowy cauliflower shapes
	float base_shape = remap(pn * 0.55 + wn * 0.6, 0.18, 1.0, 0.0, 1.0);
	float d = base_shape * height_profile(h);
	d = remap(d, 1.0 - cov * mix(0.6, 1.05, weather), 1.0, 0.0, 1.0);
	d *= mix(0.25, 1.0, weather);
	if (d <= 0.0) {
		return 0.0;
	}
	if (!cheap) {
		// erode the edges with fine detail for wispy, billowing borders
		float det = texture(detail_tex, (pos + vec3(wind.x * 1.4, 0.0, wind.y * 1.4)) / 620.0).r;
		float erode = mix(det, 1.0 - det, clamp(h * 4.0, 0.0, 1.0));
		d = remap(d, erode * 0.45, 1.0, 0.0, 1.0);
	}
	return max(d, 0.0) * p.layer.w;
}

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * 3.14159265 * pow(1.0 + g2 - 2.0 * g * c, 1.5));
}

// interleaved gradient noise: decorrelates the march start per pixel (removes banding)
float ign(vec2 px, float frame) {
	px += 5.588238 * mod(frame, 64.0);
	return fract(52.9829189 * fract(0.06711056 * px.x + 0.00583715 * px.y));
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 hsize = ivec2(p.sizes.xy);
	if (px.x >= hsize.x || px.y >= hsize.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(hsize);
	// scene depth (reverse-Z: 0 = far)
	float depth = textureLod(depth_tex, uv, 0.0).r;
	vec4 vp = p.inv_proj * vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec3 view_pos = vp.xyz / vp.w;
	vec4 vfar = p.inv_proj * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
	vec3 vdir = normalize(vfar.xyz / vfar.w);
	vec3 ro = p.cam_pos.xyz;
	vec3 rd = normalize(mat3(p.cam_xform) * vdir);
	float scene_dist = depth <= 0.0000001 ? 1e9 : length(view_pos);
	float max_dist = min(scene_dist, p.misc.x);

	// intersect the cloud slab
	float base = p.layer.x;
	float top = p.layer.y;
	float t0, t1;
	if (abs(rd.y) < 1e-4) {
		if (ro.y < base || ro.y > top) {
			imageStore(out_img, px, vec4(0.0, 0.0, 0.0, 1.0));
			return;
		}
		t0 = 0.0;
		t1 = max_dist;
	} else {
		float ta = (base - ro.y) / rd.y;
		float tb = (top - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = max(ta, tb);
	}
	t1 = min(t1, max_dist);
	if (t1 <= t0 || p.layer.z <= 0.001) {
		imageStore(out_img, px, vec4(0.0, 0.0, 0.0, 1.0));
		return;
	}

	int steps = int(p.misc.z);
	float seg = t1 - t0;
	float dt = max(seg / float(steps), 25.0);
	float t = t0 + dt * ign(vec2(px), p.misc.y);
	vec3 L = normalize(p.sun_dir.xyz);
	float cos_t = dot(rd, L);
	float phase = mix(hg(cos_t, 0.6), hg(cos_t, -0.25), 0.3) * 4.0 * 3.14159265;
	phase = mix(1.0, phase, 0.85);
	vec3 S = vec3(0.0);
	float T = 1.0;
	float hit_t = -1.0;
	float ext_k = 0.075;
	int light_steps = int(p.misc.w);
	int empty = 0;
	for (int i = 0; i < 160; i++) {
		if (i >= steps || t > t1 || T < 0.01) {
			break;
		}
		vec3 pos = ro + rd * t;
		float cheap = cloud_density(pos, true);
		if (cheap <= 0.0) {
			empty++;
			t += dt * (empty > 4 ? 2.0 : 1.0);     // stride faster through empty air
			continue;
		}
		empty = 0;
		float dens = cloud_density(pos, false);
		if (dens > 0.0) {
			if (hit_t < 0.0) {
				hit_t = t;
			}
			// light march towards the sun: optical depth -> shadowing inside the cloud
			float od = 0.0;
			float ls = 70.0;
			for (int j = 0; j < light_steps; j++) {
				vec3 lp = pos + L * (ls * (float(j) + 0.5));
				od += cloud_density(lp, j > 2) * ls;
				ls *= 1.6;
			}
			float hgt = clamp((pos.y - base) / (top - base), 0.0, 1.0);
			// Beer-Lambert shadowing towards the sun, plus a softer second term for multiple scattering
			float beer = max(exp(-od * ext_k), exp(-od * ext_k * 0.25) * 0.3);
			float powder = 1.0 - exp(-dens * ext_k * 140.0);
			float light = beer * mix(0.45, 1.0, powder);
			// ambient: brighter on the tops, darker in the bellies and deep inside
			float self_occ = exp(-dens * 1.4);
			vec3 amb = mix(p.amb_bottom.rgb, p.amb_top.rgb, hgt) * p.sun_color.w * mix(0.55, 1.0, self_occ);
			vec3 lum = p.sun_color.rgb * p.sun_dir.w * light * phase + amb;
			lum *= 1.0 - p.shape.y * (1.0 - hgt * 0.6);
			float sigma = max(dens * ext_k, 1e-6);
			float tr = exp(-sigma * dt);
			S += T * lum * (1.0 - tr);
			T *= tr;
		}
		t += dt;
	}
	// aerial perspective: distant clouds fade into the horizon haze
	if (hit_t > 0.0) {
		float f = 1.0 - exp(-p.fog.w * hit_t * 0.85);
		S = mix(S, p.fog.rgb * (1.0 - T), f);
	}
	imageStore(out_img, px, vec4(S, T));
}
