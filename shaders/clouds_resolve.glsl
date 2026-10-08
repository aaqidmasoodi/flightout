#[compute]
#version 450
// Pass 2: temporal resolve at half resolution. Reprojects last frame's clouds using the cloud's own distance, clips
// that history to the colour range of the current 3x3 neighbourhood (variance clipping), and blends. Stale clouds
// cannot survive where the current frame has none, so camera moves leave no trails.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D out_color;
layout(rg32f, set = 0, binding = 1) uniform restrict writeonly image2D out_depth;
layout(set = 0, binding = 2) uniform sampler2D cur_color;
layout(set = 0, binding = 3) uniform sampler2D cur_depth;
layout(set = 0, binding = 4) uniform sampler2D hist_color;
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


void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 hsize = ivec2(p.sizes.xy);
	if (px.x >= hsize.x || px.y >= hsize.y) {
		return;
	}
	vec4 c = texelFetch(cur_color, px, 0);
	vec2 d = texelFetch(cur_depth, px, 0).xy;
	// neighbourhood statistics of the current frame
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
	// lightly filtered current frame: clouds are low-frequency, so single-pixel ray noise should not survive
	vec4 cf = mix(c, m1, 0.5);

	vec4 result = cf;
	if (p.misc2.x > 0.5) {
		vec2 uv = (vec2(px) + 0.5) / vec2(hsize);
		vec4 vfar = p.inv_proj * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
		vec3 rd = normalize(mat3(p.cam_xform) * normalize(vfar.xyz / vfar.w));
		// reproject the cloud itself (or a far point when this pixel has no cloud)
		float rep_t = d.x < 1e8 ? mix(d.x, min(d.y, d.x + 3000.0), 0.35) : 30000.0;
		vec3 wp = p.cam_pos.xyz + rd * rep_t;
		if (d.x < 1e8) {
			wp.xz -= vec2(p.cam_pos.w, p.amb_top.w);     // clouds drift with the wind: where was this cloud last frame
		}
		vec4 clip = p.prev_vp * vec4(wp, 1.0);
		if (clip.w > 0.0) {
			vec2 puv = (clip.xy / clip.w) * 0.5 + 0.5;
			if (all(greaterThanEqual(puv, vec2(0.0))) && all(lessThanEqual(puv, vec2(1.0)))) {
				vec4 h = textureLod(hist_color, puv, 0.0);
				// motion-adaptive clipping: when this pixel barely moved, history is trustworthy, so clip loosely and
				// let it converge; when it moved a lot, clip tightly so nothing trails
				float motion = length((puv - uv) * vec2(hsize));
				float k = mix(8.0, 2.0, smoothstep(0.25, 4.0, motion));
				h = clamp(h, m1 - k * sigma, m1 + k * sigma);
				float w = p.misc2.y * mix(1.0, 0.85, smoothstep(2.0, 12.0, motion));
				// when history is trusted less (fast motion), lean more on the spatially filtered current frame
				vec4 cf_m = mix(c, m1, mix(0.5, 0.85, smoothstep(0.5, 4.0, motion)));
				result = mix(cf_m, h, w);
			}
		}
	}
	imageStore(out_color, px, result);
	imageStore(out_depth, px, vec4(d, 0.0, 0.0));
}
