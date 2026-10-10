#[compute]
#version 450
// Pass 3: upsample to full resolution. Each pixel reads its exact scene depth; each nearby cloud sample is trimmed to
// the part of the cloud in front of that depth (none if the cloud starts behind the object), then they are blended
// (Catmull-Rom: sharp, the clouds keep their edges; clamped to the nearest four samples so it never rings). Clouds
// behind the jet never land on it; clouds in front still do.
//
// Two results:
//   overlay  rgb in-scattered light, a transmittance: blended over the scene at the start of the transparent pass
//            (shaders/cloud_overlay.gdshader); with MSAA the scene colour cannot be written here directly
//   layer    the occlusion every later surface uses (shaders/include/cloud_cover.gdshaderinc): r transmittance to
//            this pixel's depth, g the distance where the cloud starts, b where it ends (km). The lights, the trails,
//            the flames and the sea are drawn after the clouds, so this is how they hide behind them.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "include/clouds_params.glslinc"

layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D overlay_img;
layout(set = 0, binding = 2) uniform sampler2D cloud_color;
layout(set = 0, binding = 3) uniform sampler2D cloud_depth;
layout(set = 0, binding = 4) uniform sampler2D depth_tex;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D layer_img;

vec4 trimmed(ivec2 hp, float dist) {
	ivec2 hsize = ivec2(p.sizes.xy);
	hp = clamp(hp, ivec2(0), hsize - 1);
	vec4 c = texelFetch(cloud_color, hp, 0);
	vec2 d = texelFetch(cloud_depth, hp, 0).xy;
	if (d.x >= 1e8) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	// fraction of this sample's cloud that lies in front of the pixel's surface
	float k = clamp((dist - d.x) / max(d.y - d.x, 30.0), 0.0, 1.0);
	return vec4(c.rgb * k, mix(1.0, c.a, k));
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 fsize = ivec2(p.sizes.zw);
	if (px.x >= fsize.x || px.y >= fsize.y) {
		return;
	}
	float dz = texelFetch(depth_tex, px, 0).r;
	float dist = 1e9;
	if (dz > 0.0) {
		vec2 fuv = (vec2(px) + 0.5) / vec2(fsize);
		vec4 v = p.inv_proj * vec4(fuv * 2.0 - 1.0, dz, 1.0);
		dist = length(v.xyz / v.w);
	}
	vec2 hp = (vec2(px) + 0.5) * (p.sizes.xy / p.sizes.zw) - 0.5;
	ivec2 b = ivec2(floor(hp));
	vec2 f = hp - vec2(b);
	// Catmull-Rom weights
	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);
	float wx[4] = float[4](w0.x, w1.x, w2.x, w3.x);
	float wy[4] = float[4](w0.y, w1.y, w2.y, w3.y);
	vec4 cl = vec4(0.0);
	vec4 lo = vec4(1e9);
	vec4 hi = vec4(-1e9);
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			vec4 s = trimmed(b + ivec2(i - 1, j - 1), dist);
			cl += s * (wx[i] * wy[j]);
			if (i >= 1 && i <= 2 && j >= 1 && j <= 2) {
				lo = min(lo, s);
				hi = max(hi, s);
			}
		}
	}
	cl = clamp(cl, lo, hi);
	imageStore(overlay_img, px, cl);
	float front = 1e9;
	float back = 0.0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 q = clamp(b + ivec2(i, j), ivec2(0), ivec2(p.sizes.xy) - 1);
			vec2 d = texelFetch(cloud_depth, q, 0).xy;
			if (d.x < 1e8) {
				front = min(front, d.x);
				back = max(back, d.y);
			}
		}
	}
	if (front >= 1e8) {
		front = 6e7;
		back = 6e7;
	}
	back = min(back, dist);
	imageStore(layer_img, px, vec4(cl.a, min(front * 0.001, 60000.0), min(max(back, front) * 0.001, 60000.0), 1.0));
}
