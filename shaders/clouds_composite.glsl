#[compute]
#version 450
// Pass 3: depth-aware upsample at full resolution. Each pixel reads its exact scene depth; each of the nearest
// cloud samples is trimmed to the part of the cloud in front of that depth (none if the cloud starts behind the
// object), then they are blended. Clouds behind the jet never land on it; clouds in front still do.
// The result goes to the cloud overlay (rgb in-scattered light, a transmittance), which a full-screen surface blends
// over the scene at the start of the transparent pass (shaders/cloud_overlay.gdshader). Writing into the scene colour
// here instead does not work with MSAA: that is the resolve target, overwritten when the multisampled image resolves.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D overlay_img;
layout(set = 0, binding = 1) uniform sampler2D cloud_color;
layout(set = 0, binding = 2) uniform sampler2D cloud_depth;
layout(set = 0, binding = 3) uniform sampler2D depth_tex;
// per-pixel cloud cover for transparent surfaces drawn after this pass: r = transmittance, g = front distance (km)
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D layer_img;
layout(set = 0, binding = 4, std140) uniform Params {
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
	// cubic B-spline reconstruction over 4x4 low-resolution samples (smooth, no stair-steps or speckle),
	// each sample trimmed against this pixel's depth first
	vec2 hp = (vec2(px) + 0.5) * (p.sizes.xy / p.sizes.zw) - 0.5;
	ivec2 b = ivec2(floor(hp));
	vec2 f = hp - vec2(b);
	vec2 f2 = f * f;
	vec2 f3 = f2 * f;
	vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
	vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
	vec2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
	vec2 w3 = f3 / 6.0;
	float wx[4] = float[4](w0.x, w1.x, w2.x, w3.x);
	float wy[4] = float[4](w0.y, w1.y, w2.y, w3.y);
	vec4 cl = vec4(0.0);
	for (int j = 0; j < 4; j++) {
		for (int i = 0; i < 4; i++) {
			cl += trimmed(b + ivec2(i - 1, j - 1), dist) * (wx[i] * wy[j]);
		}
	}
	imageStore(overlay_img, px, vec4(cl.rgb, cl.a));
	float front = 1e9;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 q = clamp(b + ivec2(i, j), ivec2(0), ivec2(p.sizes.xy) - 1);
			front = min(front, texelFetch(cloud_depth, q, 0).x);
		}
	}
	imageStore(layer_img, px, vec4(cl.a, min(front * 0.001, 60000.0), 0.0, 1.0));
}
