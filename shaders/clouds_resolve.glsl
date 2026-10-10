#[compute]
#version 450
// Pass 2: temporal resolve at march resolution. Reprojects last frame's clouds at the cloud's opacity-weighted
// distance (where the light actually comes from, so the history moves exactly as the cloud does and the clouds
// keep their parallax), clips that history to the colour range of the current 3x3 neighbourhood (variance
// clipping), and blends. Stale clouds cannot survive where the current frame has none, so camera moves leave no
// trails.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "include/clouds_params.glslinc"

layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D out_color;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D out_depth;
layout(set = 0, binding = 3) uniform sampler2D cur_color;
layout(set = 0, binding = 4) uniform sampler2D cur_depth;
layout(set = 0, binding = 5) uniform sampler2D hist_color;

// Clip towards the neighbourhood centre along a straight line (not per channel), so the result is always a
// blend of colours that really exist here; per-channel clamping could pair dark light with opaque cover.
vec4 clip_box(vec4 h, vec4 lo, vec4 hi) {
	vec4 c = 0.5 * (hi + lo);
	vec4 e = 0.5 * (hi - lo) + 1e-4;
	vec4 v = h - c;
	vec4 u = abs(v / e);
	float m = max(max(u.x, u.y), max(u.z, u.w));
	return m > 1.0 ? c + v / m : h;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 hsize = ivec2(p.sizes.xy);
	if (px.x >= hsize.x || px.y >= hsize.y) {
		return;
	}
	vec4 c = texelFetch(cur_color, px, 0);
	vec4 d = texelFetch(cur_depth, px, 0);
	vec4 m1 = vec4(0.0);
	vec4 m2 = vec4(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec4 s = texelFetch(cur_color, clamp(px + ivec2(x, y), ivec2(0), hsize - 1), 0);
			m1 += s;
			m2 += s * s;
		}
	}
	m1 /= 9.0;
	m2 /= 9.0;
	vec4 sigma = sqrt(max(m2 - m1 * m1, vec4(0.0)));
	vec4 result = mix(c, m1, 0.5);     // no history: lightly filtered
	if (p.origin.w > 0.5) {
		vec2 uv = (vec2(px) + 0.5) / vec2(hsize);
		vec4 vfar = p.inv_proj * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
		vec3 rd = normalize(mat3(p.cam_xform) * normalize(vfar.xyz / vfar.w));
		bool has = d.z < 1e8;
		float rep_t = has ? d.z : 60000.0;
		vec3 wp = p.cam_pos.xyz + rd * rep_t;
		if (has) {
			wp.xz -= p.wind.zw;               // clouds drift with the wind: where was this cloud last frame
		}
		vec4 clip = p.prev_vp * vec4(wp, 1.0);
		if (clip.w > 0.0) {
			vec2 puv = (clip.xy / clip.w) * 0.5 + 0.5;
			if (all(greaterThanEqual(puv, vec2(0.0))) && all(lessThanEqual(puv, vec2(1.0)))) {
				vec4 h = textureLod(hist_color, puv, 0.0);
				// motion-adaptive clipping: barely moving, the history is trustworthy (clip loosely, converge);
				// moving fast, clip tightly so nothing trails
				float motion = length((puv - uv) * vec2(hsize));
				float k = mix(6.0, 1.75, smoothstep(0.25, 4.0, motion));
				h = clip_box(h, m1 - k * sigma, m1 + k * sigma);
				float w = p.amb_top.w * mix(1.0, 0.85, smoothstep(2.0, 12.0, motion));
				// the current frame sharp while the history is trusted; leaning on its neighbourhood only when moving
				vec4 cf = mix(c, m1, mix(0.15, 0.7, smoothstep(0.5, 4.0, motion)));
				result = mix(cf, h, w);
			}
		}
	}
	imageStore(out_color, px, result);
	imageStore(out_depth, px, d);
}
