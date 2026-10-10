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
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D overlay_b_img;

vec4 trimmed(ivec2 hp, float dist) {
	ivec2 hsize = ivec2(p.sizes.xy);
	hp = clamp(hp, ivec2(0), hsize - 1);
	vec4 c = texelFetch(cloud_color, hp, 0);
	vec4 d = texelFetch(cloud_depth, hp, 0);
	// The sample marched only as far as the nearest surface it covered (d.w; clouds_march.glsl): all of its cloud
	// lies in front of that, so a pixel at or beyond it takes the whole sample. Trimming there by the sample's cloud
	// start and end (this frame's own march, which jitters from frame to frame) flipped the pixels where a mountain
	// meets a cloud between "in front" and "behind": a line at every contact, sliding as the view moved.
	if (dist >= d.w * 0.98) {
		return c;
	}
	if (d.x >= 1e8) {
		// no depth for it (rare: see clouds_resolve.glsl): against the sky the accumulated cloud is still right
		return dist >= 1e8 ? c : vec4(0.0, 0.0, 0.0, 1.0);
	}
	// nearer than where the sample stopped (the jet in front of the clouds): the share of its cloud in front of it
	// The light builds up front-loaded, as light through cloud does: exponentially from where the cloud starts, over
	// the length its opacity-weighted depth gives (z - x), between its start and end. (Spread evenly over the whole
	// span, a jet 20 m into a deck kilometres deep was given almost none of the cloud in front of it, and the share
	// flipped from texel to texel: speckle all over the jet in cloud.)
	float L = max(d.z - d.x, 5.0);
	float span = max(d.y - d.x, 1.0);
	float k = clamp((1.0 - exp(-max(dist - d.x, 0.0) / L)) / max(1.0 - exp(-span / L), 1e-4), 0.0, 1.0);
	return vec4(c.rgb * k, mix(1.0, c.a, k));
}

// The clouds in front of a surface at `dist`, upsampled to full resolution at pixel px.
vec4 cloud_for(ivec2 px, float dist) {
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
	// At a depth edge (a ridge or the jet against the sky or the clouds), the nearby texels saw different scenes
	// (each marched to the nearest surface it covered): blend only those whose scene lies at this pixel's depth
	// (joint bilateral), over the 4 x 4 around it, with smooth B-spline weights.
	float ld = log2(min(dist, 1e9));
	float smin = 1e30;
	float smax = 0.0;
	float dnear = 1e30;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 q = clamp(b + ivec2(i, j), ivec2(0), ivec2(p.sizes.xy) - 1);
			float v = texelFetch(cloud_depth, q, 0).w;
			smin = min(smin, v);
			smax = max(smax, v);
			dnear = min(dnear, abs(log2(max(v, 1.0)) - ld));
		}
	}
	if (log2(smax) - log2(max(smin, 1.0)) > 0.3 || dnear > 0.3) {
		vec2 f2 = f * f;
		vec2 f3 = f2 * f;
		vec2 b0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
		vec2 b1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
		vec2 b2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
		vec2 b3 = f3 / 6.0;
		float bx[4] = float[4](b0.x, b1.x, b2.x, b3.x);
		float by[4] = float[4](b0.y, b1.y, b2.y, b3.y);
		vec4 acc = vec4(0.0);
		float wsum_b = 0.0;
		for (int j = 0; j < 4; j++) {
			for (int i = 0; i < 4; i++) {
				ivec2 q = clamp(b + ivec2(i - 1, j - 1), ivec2(0), ivec2(p.sizes.xy) - 1);
				float dd = abs(log2(max(texelFetch(cloud_depth, q, 0).w, 1.0)) - ld);
				float bw = (bx[i] * by[j] + 1e-4) / (1.0 + dd * dd * 64.0);
				acc += trimmed(b + ivec2(i - 1, j - 1), dist) * bw;
				wsum_b += bw;
			}
		}
		cl = acc / wsum_b;
	}
	return cl;
}

float pixel_dist(ivec2 q) {
	ivec2 fsize = ivec2(p.sizes.zw);
	q = clamp(q, ivec2(0), fsize - 1);
	float dz = texelFetch(depth_tex, q, 0).r;
	if (dz <= 0.0) {
		return 1e9;
	}
	vec2 fuv = (vec2(q) + 0.5) / vec2(fsize);
	vec4 v = p.inv_proj * vec4(fuv * 2.0 - 1.0, dz, 1.0);
	return length(v.xyz / v.w);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 fsize = ivec2(p.sizes.zw);
	if (px.x >= fsize.x || px.y >= fsize.y) {
		return;
	}
	float dist = pixel_dist(px);
	// The nearest and farthest surfaces around this pixel. With MSAA a pixel on the jet's outline holds samples of
	// the jet and of what lies behind it, but has one depth here. The cloud is split at the nearest surface: what is
	// in front of it goes to every sample (overlay), what is behind it only to the samples beyond it (overlay_b,
	// depth-tested there). One cloud for the whole pixel gave the jet's edge samples the cloud behind the jet: a
	// white rim round it whenever it was in or over cloud.
	float dn = dist;
	float df = dist;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			if (i != 0 || j != 0) {
				float q = pixel_dist(px + ivec2(i, j));
				dn = min(dn, q);
				df = max(df, q);
			}
		}
	}
	vec4 cl;
	vec4 behind = vec4(0.0, 0.0, 0.0, 1.0);
	float t_here;
	if (df > dn * 1.05 + 2.0) {
		vec4 fa = cloud_for(px, dn);
		// behind: up to this pixel's own surface when that is the far one (the ridge behind a nearer ridge takes no
		// cloud from beyond it); when its own is the near one (the jet's depth), up to the farthest around
		bool own_far = dist > dn * 1.05 + 2.0;
		vec4 ff = cloud_for(px, own_far ? dist : df);
		cl = fa;
		if (fa.a > 0.002) {
			behind = vec4(max(ff.rgb - fa.rgb, vec3(0.0)) / fa.a, clamp(ff.a / fa.a, 0.0, 1.0));
		}
		t_here = own_far ? ff.a : fa.a;
	} else {
		cl = cloud_for(px, dist);
		t_here = cl.a;
	}
	vec2 hp = (vec2(px) + 0.5) * (p.sizes.xy / p.sizes.zw) - 0.5;
	ivec2 b = ivec2(floor(hp));
	if ((p.ranges.w > 3.5 && p.ranges.w < 5.5) || p.ranges.w > 9.5) {
		// debug 4 / 5: the march-resolution picture itself, nearest texel, opacity as white on black (5: without
		// the temporal pass)
		vec4 n = texelFetch(cloud_color, clamp(ivec2(hp + 0.5), ivec2(0), ivec2(p.sizes.xy) - 1), 0);
		cl = vec4(vec3(1.0 - n.a), 0.0);
	} else if (p.ranges.w > 2.5 && p.ranges.w < 3.5) {
		// debug 3: this pixel's scene distance (red: km / 10, green: under 3 km), opaque
		cl = vec4(min(dist / 10000.0, 1.0), dist < 3000.0 ? 1.0 : 0.0, 0.0, 0.0);
	}
	imageStore(overlay_img, px, cl);
	imageStore(overlay_b_img, px, behind);
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
	// (w: the nearest surface around the pixel, km: where overlay_b's depth test cuts)
	imageStore(layer_img, px, vec4(t_here, min(front * 0.001, 60000.0), min(max(back, front) * 0.001, 60000.0), min(dn * 0.001, 60000.0)));
}
