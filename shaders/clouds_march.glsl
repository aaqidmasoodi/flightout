#[compute]
#version 450
// Pass 1: the clouds raymarched at half (or quarter) resolution, from the shared cloud model
// (include/clouds_common.glslinc), in three ranges along each ray:
//   near (to ~9 km)        full shapes with the detail erosion; sunlight by a short light march plus the shadow map
//   mid (to the march end) the shapes alone, at the noise level the pixel's footprint calls for; shadow map light
//   far (to the horizon)   the far-cloud map: the same cloud columns, integrated (clouds_far.glsl), met as three
//                          layers through each column: sharp, steady, the same clouds as up close
// then the cirrus, a thin sheet high above (a real plane in the sky, so it moves with true parallax).
// out_color: rgb in-scattered light, a transmittance. out_depth: x where the cloud starts, y where it ends, z the
// opacity-weighted distance of the cloud (what the temporal pass reprojects at), 1e9 when there is none. The
// composite pass trims all of it to each full-resolution pixel's own depth, so clouds behind an object never land on it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform sampler2D ground_ref;
layout(set = 0, binding = 2) uniform sampler2D weather_tex;
layout(set = 0, binding = 3) uniform sampler3D shape_tex;
layout(set = 0, binding = 4) uniform sampler3D detail_tex;

#include "include/clouds_params.glslinc"
#include "include/clouds_common.glslinc"

layout(set = 0, binding = 5) uniform sampler2D blue_noise;     // 64x64 void-and-cluster blue noise
layout(set = 0, binding = 6) uniform sampler2D depth_tex;
layout(set = 0, binding = 7) uniform sampler2D shadow0_tex;
layout(set = 0, binding = 8) uniform sampler2D shadow1_tex;
layout(rgba16f, set = 0, binding = 9) uniform restrict writeonly image2D out_color;
layout(rgba32f, set = 0, binding = 10) uniform restrict writeonly image2D out_depth;
layout(set = 0, binding = 11) uniform sampler2D far_tex;           // the far-cloud map (clouds_far.glsl)

const float NO_CLOUD = 1e9;

// Optical depth of the cloud above a point (true frame), towards the sun, from the shadow map.
float shadow_od(vec3 mp, vec3 L) {
	float ly = max(L.y, 0.06);
	vec2 q = mp.xz + L.xz * (p.cirrus.w - mp.y) / ly;
	vec2 uv0 = (q - p.shadow0.xy) / (2.0 * p.shadow0.z) + 0.5;
	vec2 uv1 = (q - p.shadow1.xy) / (2.0 * p.shadow1.z) + 0.5;
	float od1 = 0.0;
	if (all(greaterThan(uv1, vec2(0.0))) && all(lessThan(uv1, vec2(1.0)))) {
		vec4 v = textureLod(shadow1_tex, uv1, 0.0);
		od1 = v.x * (1.0 - saturate((mp.y - v.y) / max(v.z - v.y, 1.0)));
	}
	// cascade 0, fading into cascade 1 over its outer tenth
	vec2 e = abs(uv0 - 0.5) * 2.0;
	float w0 = 1.0 - smoothstep(0.85, 0.98, max(e.x, e.y));
	if (w0 <= 0.0) {
		return od1;
	}
	vec4 v = textureLod(shadow0_tex, uv0, 0.0);
	float od0 = v.x * (1.0 - saturate((mp.y - v.y) / max(v.z - v.y, 1.0)));
	return mix(od1, od0, w0);
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

// sunlight reaching a sample, through the cloud towards the sun (optical depth od), with the multiple scattering
// that lights a cloud from inside (Wrenninge's octaves: each scatters wider and reaches deeper)
float sun_light(float od, float cos_t, float dens) {
	float s = 0.0;
	float a = 1.0;
	float b = 1.0;
	float c = 1.0;
	for (int o = 0; o < 3; o++) {
		float ph = mix(hg(cos_t, 0.6 * c), hg(cos_t, -0.25 * c), 0.3) * 4.0 * PI;
		s += a * mix(1.0, ph, 0.85) * exp(-od * b);
		a *= 0.5;
		b *= 0.45;
		c *= 0.5;
	}
	float powder = 1.0 - exp(-dens * EXT * 140.0);
	return s * mix(0.45, 1.0, powder);
}

// light from the jets' own lamps (afterburners, landing lights) scattered by cloud near them
vec3 local_light(vec3 sp) {
	vec3 sum = vec3(0.0);
	int n = int(p.lights_n.x);
	for (int i = 0; i < 4; i++) {
		if (i >= n) {
			break;
		}
		vec3 d = sp - p.light_pos[i].xyz;
		float r2 = dot(d, d);
		float R = p.light_pos[i].w;
		if (r2 > R * R) {
			continue;
		}
		float win = 1.0 - r2 / (R * R);
		float k = win * win / (1.0 + r2 * 0.02);
		if (p.light_col[i].w > -1.5) {
			float c = dot(normalize(d), p.light_dir[i].xyz);
			k *= smoothstep(p.light_col[i].w, mix(p.light_col[i].w, 1.0, 0.35), c);
		}
		sum += p.light_col[i].rgb * k;
	}
	return sum * (1.0 / (4.0 * PI));
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 hsize = ivec2(p.sizes.xy);
	if (px.x >= hsize.x || px.y >= hsize.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(hsize);
	// march as far as the farthest of the full-resolution pixels this texel covers; the composite trims it back per
	// pixel, so the background beside an object still gets its clouds
	int r = int(p.sizes.z / p.sizes.x + 0.5);
	ivec2 f0 = px * r;
	ivec2 fmax = ivec2(p.sizes.zw) - 1;
	float scene_dist = max(max(scene_distance(min(f0, fmax)), scene_distance(min(f0 + ivec2(r - 1, 0), fmax))),
		max(scene_distance(min(f0 + ivec2(0, r - 1), fmax)), scene_distance(min(f0 + ivec2(r - 1, r - 1), fmax))));
	vec4 vfar = p.inv_proj * vec4(uv * 2.0 - 1.0, 0.5, 1.0);
	vec3 ro = p.cam_pos.xyz;
	vec3 rd = normalize(mat3(p.cam_xform) * normalize(vfar.xyz / vfar.w));
	vec2 omap = p.origin.xy;
	float curve = p.ground.w;
	float reach = p.ranges.z;
	// the slab any cloud can lie in (scene frame): from the lowest base (less the curvature drop at the far end of the
	// ray) to the highest top
	float sb = p.cirrus.w - reach * reach * curve;
	float st = p.lights_n.y;
	float t0, t1;
	if (abs(rd.y) < 1e-4) {
		t0 = (ro.y < sb || ro.y > st) ? 1.0 : 0.0;
		t1 = (ro.y < sb || ro.y > st) ? 0.0 : reach;
	} else {
		float ta = (sb - ro.y) / rd.y;
		float tb = (st - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(max(ta, tb), reach);
	}
	// Objects nearer than the clouds (the jet, nearby scenery) do not stop the march: the composite trims each
	// pixel to its own depth anyway, and marching through them keeps the cloud image continuous
	float max_dist = (scene_dist < max(t0, 300.0)) ? reach : min(scene_dist, reach);
	t1 = min(t1, max_dist);
	if (p.ranges.w > 0.5 && p.ranges.w < 1.5) {
		// debug 1: red where the ray crosses the cloud slab (brightness: how long), blue where it does not
		float seg_dbg = max(t1 - t0, 0.0);
		imageStore(out_color, px, seg_dbg > 0.0 ? vec4(clamp(seg_dbg / 20000.0, 0.05, 1.0), 0.0, 0.0, 0.0) : vec4(0.0, 0.0, 0.5, 0.0));
		imageStore(out_depth, px, vec4(100.0, 200.0, 150.0, 0.0));
		return;
	}

	vec3 L = normalize(p.sun_dir.xyz);
	float cos_t = dot(rd, L);
	vec3 S = vec3(0.0);
	float T = 1.0;
	float first = NO_CLOUD;
	float last = NO_CLOUD;
	float wsum = 0.0;
	float wdist = 0.0;
	float jitter = fract(texelFetch(blue_noise, px % 64, 0).r + p.origin.z * 0.61803398875);
	// the horizon colour in this direction (aerial perspective: far clouds melt into it like the sky behind them)
	vec2 dh = normalize(rd.xz + vec2(1e-5));
	float toward = pow(clamp(dot(dh, vec2(p.hor_a.w, p.hor_b.w)) * 0.5 + 0.5, 0.0, 1.0), 3.0);
	vec3 fc = mix(p.hor_b.rgb, p.hor_a.rgb, toward);
	float pix = p.cirrus.z;                 // radians per march pixel
	float shape_texel = SHAPE_SCALE / 128.0;
	float near_end = p.ranges.x;
	float march_end = min(p.ranges.y, t1);

	if (t1 > t0 && p.layer.z > 0.001) {
		// ---- near and mid: adaptive march (Nubis): large cheap steps through clear air; on touching cloud, step
		// back and walk it in small steps, so thin clouds never fall between two samples ----
		int steps = int(p.steps.x);
		float seg = max(march_end - t0, 0.0);
		float dt = clamp(seg / float(steps), 25.0, 250.0);
		float t = t0 + dt * jitter;
		int fine_left = 0;
		int expensive = 0;
		float last_step = dt;
		int max_iter = int(p.steps.z);
		int max_dense = int(p.steps.w);
		int light_steps = int(p.steps.y);
		for (int i = 0; i < max_iter; i++) {
			if (t > march_end || T < 0.01 || expensive >= max_dense) {
				break;
			}
			float big = dt * (1.0 + t / 12000.0);
			float fine = clamp(big * 0.35, 30.0, 160.0) * (1.0 + t / 9000.0);
			vec3 sp = ro + rd * t;
			vec2 dc = sp.xz - ro.xz;
			vec3 mp = vec3(sp.x + omap.x, sp.y + dot(dc, dc) * curve, sp.z + omap.y);
			// the noise level for this sample's footprint (a pixel's width at this distance)
			float lod = log2(max(t * pix, 0.5) / shape_texel) + 0.5;   // below 0 near: the detail level uses it
			float hh;
			Column col = column(mp.xz);
			// empty-space skipping by height: above or below this column's layer, jump to where the ray reaches it
			// (at most 3 km on: the layer's height changes over the land). The slab every ray crosses spans all of
			// Kashmir's valleys and peaks; without this most of a ray's steps went into the empty part of it.
			if (fine_left == 0) {
				float gap = 0.0;
				if (mp.y > col.top && rd.y < -1e-3) {
					gap = (mp.y - col.top) / -rd.y;
				} else if (mp.y < col.base && rd.y > 1e-3) {
					gap = (col.base - mp.y) / rd.y;
				}
				if (gap > big) {
					// land short of the layer by this pixel's own random share of a step, so the samples inside
					// keep their spread (landing everyone at the same point showed the steps as bands)
					t += min(gap - big * (0.25 + 0.75 * jitter), 3000.0);
					continue;
				}
			}
			float cheap = density_in(mp, col, lod, 0.0, hh);
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
			float detail_amt = 1.0 - smoothstep(near_end * 0.55, near_end, t);
			float hgt;
			float dens = density_in(mp, col, lod, detail_amt, hgt);
			// approaching the end of the march, hand over to the far-cloud map (which fades in over the same band)
			dens *= 1.0 - smoothstep(p.ranges.y * 0.75, p.ranges.y, t);
			if (dens > 0.0) {
				if (first >= NO_CLOUD) {
					first = t;
				}
				last = t;
				// sunlight: a short march towards the sun near the camera (sharp self-shadowing in the detail), then
				// the shadow map for the rest of the way up
				float od = 0.0;
				float reach_l = 0.0;
				if (t < near_end) {
					float ls = 60.0;
					// each sample's own offset along the way (fixed offsets showed as bands at fixed heights)
					float lj = fract(jitter * 7.13 + float(expensive) * 0.618);
					for (int j = 0; j < light_steps; j++) {
						float hl;
						od += density(mp + L * (reach_l + ls * mix(0.15, 0.85, lj)), lod + 1.0, 0.0, hl) * EXT * ls;
						reach_l += ls;
						ls *= 2.0;
					}
				}
				od += shadow_od(mp + L * reach_l, L);
				float sl = sun_light(od, cos_t, dens);
				float self_occ = exp(-dens * 1.4);
				vec3 amb = mix(p.amb_bottom.rgb, p.amb_top.rgb, hgt) * p.sun_color.w * mix(0.55, 1.0, self_occ);
				// sunlight diffused through the whole cloud from its lit side (what keeps a cumulus base grey, not black)
				amb += p.sun_color.rgb * p.sun_dir.w * 0.07 * (0.45 + 0.55 * hgt);
				vec3 lum = p.sun_color.rgb * p.sun_dir.w * sl + amb;
				lum *= 1.0 - p.shape.y * (1.0 - hgt * 0.6);
				if (t < 600.0) {
					lum += local_light(sp);
				}
				// aerial perspective for this sample
				float f = 1.0 - exp(-p.fog.w * t * haze_mean(ro.y, sp.y));
				lum = mix(lum, fc, f);
				float sigma = max(dens * EXT, 1e-6);
				float tr = exp(-sigma * step_here);
				float a = T * (1.0 - tr);
				S += a * lum;
				wsum += a;
				wdist += a * t;
				T *= tr;
			}
			t += step_here;
		}
		// ---- far: the far-cloud map. Each column is met once, at the face the camera sees (its base from below,
		// its top from above), with all of its optical depth along the slant of the ray. No random samples: the far
		// clouds are as steady as the terrain. (Three slices through each column showed each cloud three times,
		// kilometres apart, at the shallow angles seen from the ground.) Beyond the map, the weather's mean
		// density. ----
		float fa = max(march_end * 0.75, t0);
		if (t1 > fa && T > 0.01) {
			float slant = 1.0 / max(abs(rd.y), 0.12);
			for (int k = 0; k < 2; k++) {
				// the face towards the camera; the other one if that lies behind it
				float frac = (rd.y < 0.0) == (k == 0) ? 0.8 : 0.2;
				// where the ray meets this height of the local cloud (the height comes from the map: iterate)
				float tk = max(fa, (mix(p.cirrus.w, p.lights_n.y, frac) - ro.y) / (abs(rd.y) > 1e-4 ? rd.y : 1e-4));
				const float FAR_TEXEL = 2.0 * 120000.0 / 1024.0;
				vec4 col = vec4(0.0);
				bool hit = false;
				vec3 sp = ro;
				for (int it = 0; it < 3; it++) {
					tk = clamp(tk, fa, t1);
					sp = ro + rd * tk;
					vec2 dc = sp.xz - ro.xz;
					vec2 w = sp.xz + omap + p.wind.xy;
					vec2 uv = (w - p.far_map.xy) / (2.0 * p.far_map.z) + 0.5;
					if (p.far_map.w < 0.5 || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
						// beyond the map: the weather's mean density, at this height of the column
						vec3 mp = vec3(sp.x + omap.x, 0.0, sp.z + omap.y);
						Column cc = column(mp.xz);
						mp.y = mix(cc.base, cc.top, 0.3 + 0.4 * frac);
						float hf;
						float dfar = density_far(mp, hf);
						col = vec4(dfar * EXT * (cc.top - cc.base), cc.base, cc.top, 0.0);
					} else {
						// the map's mip level for this pixel's footprint on it, stretched along the ray at a grazing
						// view (the larger of the two: blur rather than alias into streaks)
						float fp = tk * pix * min(slant, 8.0);
						col = textureLod(far_tex, uv, max(log2(fp / FAR_TEXEL), 0.0));
					}
					float y_true = mix(col.y, col.z, frac);
					float yr = y_true - dot(dc, dc) * curve;
					if (abs(rd.y) < 1e-4) {
						break;
					}
					float tn = (yr - ro.y) / rd.y;
					hit = tn >= fa && tn <= t1;
					tk = tn;
				}
				if (!hit || col.x <= 0.0) {
					continue;
				}
				// fade in over the end of the march (the march fades out there)
				float fin = smoothstep(march_end * 0.75, march_end, tk);
				float od_k = col.x * min(slant, 4.0) * fin;
				float tr = exp(-od_k);
				if (tr > 0.999) {
					continue;
				}
				vec3 mp = vec3(sp.x + omap.x, mix(col.y, col.z, frac), sp.z + omap.y);
				float dens = col.x / max(EXT * (col.z - col.y), 1.0);
				float od = shadow_od(mp, L);
				float sl = sun_light(od, cos_t, dens);
				float hgt = frac;
				vec3 amb = mix(p.amb_bottom.rgb, p.amb_top.rgb, hgt) * p.sun_color.w;
				amb += p.sun_color.rgb * p.sun_dir.w * 0.07 * (0.45 + 0.55 * hgt);
				vec3 lum = p.sun_color.rgb * p.sun_dir.w * sl + amb;
				lum *= 1.0 - p.shape.y * (1.0 - hgt * 0.6);
				float f = 1.0 - exp(-p.fog.w * tk * haze_mean(ro.y, sp.y));
				lum = mix(lum, fc, f);
				float a = T * (1.0 - tr);
				if (first >= NO_CLOUD) {
					first = tk;
				}
				last = max(last < NO_CLOUD ? last : tk, tk);
				S += a * lum;
				wsum += a;
				wdist += a * tk;
				T *= tr;
				break;
			}
		}
	}

	// ---- cirrus: a thin sheet high above, a real plane (true parallax), behind everything else ----
	if (p.cirrus.y > 0.002 && T > 0.01 && abs(rd.y) > 1e-4) {
		float yc = p.cirrus.x;
		float tc = (yc - ro.y) / rd.y;
		if (tc > 0.0 && tc < 300000.0) {
			float yc2 = yc - tc * tc * curve * (1.0 - rd.y * rd.y);    // the sheet sinks with distance too
			tc = (yc2 - ro.y) / rd.y;
		}
		if (tc > 0.0 && tc < 300000.0 && tc < scene_dist) {
			vec3 sp = ro + rd * tc;
			vec2 m = sp.xz + omap + p.wind.xy * 2.2;
			float lod = max(log2(max(tc * pix, 1.0) / (60000.0 / 128.0)), 0.0);
			// streaks stretched along one direction, broken by the shape noise; where the weather allows
			float reg = textureLod(weather_tex, m / 180000.0 + 0.31, 0.0).g;
			vec4 nz = textureLod(shape_tex, vec3(m.x / 60000.0, 0.37, m.y / 18000.0), lod);
			float c = smoothstep(1.0 - p.cirrus.y, 1.0 - p.cirrus.y + 0.45, nz.r * 0.7 + reg * 0.5 - nz.b * 0.25);
			float a = c * 0.55 * smoothstep(0.0, 0.04, abs(rd.y));
			if (a > 0.001) {
				vec3 lum = p.sun_color.rgb * p.sun_dir.w * mix(1.0, hg(cos_t, 0.7) * 4.0 * PI, 0.6) * 0.8 + p.amb_top.rgb * p.sun_color.w;
				float f = 1.0 - exp(-p.fog.w * tc * haze_mean(ro.y, sp.y));
				lum = mix(lum, fc, f);
				S += T * a * lum;
				wsum += T * a;
				wdist += T * a * tc;
				if (first >= NO_CLOUD) {
					first = tc;
				}
				last = max(last < NO_CLOUD ? last : tc, tc);
				T *= 1.0 - a;
			}
		}
	}

	if (p.ranges.w > 1.5 && p.ranges.w < 2.5) {
		// debug 2: green where the march found cloud (brightness: opacity), red where it marched and found none
		imageStore(out_color, px, first < NO_CLOUD ? vec4(0.0, 1.0 - T, 0.0, 0.0) : vec4(0.3, 0.0, 0.0, 0.0));
		imageStore(out_depth, px, vec4(100.0, 200.0, 150.0, 0.0));
		return;
	}
	float wd = wsum > 1e-4 ? wdist / wsum : NO_CLOUD;
	imageStore(out_color, px, vec4(S, T));
	imageStore(out_depth, px, vec4(first, last < NO_CLOUD ? last + 60.0 : NO_CLOUD, wd, 0.0));
}
