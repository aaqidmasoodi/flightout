shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Streamed terrain tiles (scripts/world/terrain_streamer.gd). One grid patch per tile instance; heights come from
// the tile's layer of a texture array, and near the edge of its range the grid morphs onto the next coarser level's
// grid (every other vertex slides halfway), so tiles of different levels meet without cracks.
//
// Shading from the land cover (ESA WorldCover): forest, fields, towns, grass, scree, snow and water, with rock on
// steep faces. Large-scale colour variation and close-up detail come from mipmapped noise textures (smooth at any
// distance).

uniform sampler2D macro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// distance haze (set by the sky system, see surface_materials.ocean_materials): the aerial perspective below
uniform vec3 haze_color : source_color = vec3(0.6, 0.7, 0.8);
uniform float haze_density = 0.0;
uniform vec3 hor_toward : source_color = vec3(0.0);
uniform vec3 hor_away : source_color = vec3(0.0);
uniform vec2 sun_xz = vec2(0.0);
uniform float aerial_k = 1.0;        // large maps: strength of the aerial perspective
uniform float aerial_max = 0.9;      // never fully hazed: distant ranges keep their silhouette
uniform float view_far = 1e9;        // camera far plane (set by the streamer)
// lighter shading for modest GPUs (graphics/terrain_detail low): one macro and one detail sample, the land cover read
// straight from its grid (no wandering boundaries), no field patchwork, close-up relief or cover morph; about half
// the texture reads of the full path. The colours, rock, snow, haze and lighting are the same.
uniform bool lite = false;

float haze_mean(float y0, float y1) {
	const float H = 2500.0;
	y0 = max(y0, 0.0);
	y1 = max(y1, 0.0);
	float a = exp(-y0 / H);
	float b = exp(-y1 / H);
	float dy = y0 - y1;
	return abs(dy) < 1.0 ? a : H * (b - a) / dy;
}


uniform sampler2DArray heights : filter_linear, repeat_disable;
uniform float tile_quads = 64.0;
uniform float tile_samples = 67.0;
uniform float h_scale = 16383.75;       // 16-bit value (0..1) to metres
uniform float h_offset = -500.0;
// land cover (ESA WorldCover class codes, same layout as the heights); without it the island's procedural shading
uniform sampler2DArray cover : filter_nearest, repeat_disable;

global uniform vec2 world_origin;     // floating origin (scripts/world/world_data.gd): scene + origin = map
// Earth's curvature, drawn only (the simulation stays flat, as in DCS): the ground drops by d^2 * earth_curve below
// a flat plane at horizontal distance d from the camera. 1 / (2 R'), R' the Earth's radius stretched by standard
// atmospheric refraction (k = 0.13, R' = R / (1 - k)); 0 on the island.
global uniform float earth_curve;
#include "res://shaders/include/terrain_shadow.gdshaderinc"

varying vec3 wpos;
varying vec3 wnorm;
varying flat float v_layer;
varying flat float v_level;
uniform bool debug_lod = false;      // tint each level (development: --terrain-lod)
varying vec2 v_grid;
varying float v_step;
varying float v_h;                   // true terrain height (before the curvature drop): shading, snow line, haze
varying flat vec2 v_morph;           // this tile's morph range (m0, m1)
varying float v_shadow;              // 1 lit by the sun, 0 in a mountain's shadow (macro_shadow)
varying float v_wet;                 // water: sun glint (light())
varying float v_rough;

float hfetch(vec2 g, float layer) {
	vec2 uv = (g + 1.5) / tile_samples;        // sample g sits one texel in (the border)
	return textureLod(heights, vec3(uv, layer), 0.0).r * h_scale + h_offset;
}

// other views than the main camera (the cockpit mirrors' picture) shade the terrain the cheap way (as `lite`): their
// picture is small and seen in a mirror, the fine detail would not show
varying flat float v_lite;

void vertex() {
	v_lite = (lite || any(notEqual(INV_VIEW_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz))) ? 1.0 : 0.0;
	float layer = INSTANCE_CUSTOM.x;
	float m0 = INSTANCE_CUSTOM.z;
	float m1 = INSTANCE_CUSTOM.w;
	float size = length(MODEL_MATRIX[0].xyz);
	vec2 g = floor(VERTEX.xz * tile_quads + 0.5);
	vec3 p0 = (MODEL_MATRIX * vec4(VERTEX.x, hfetch(g, layer), VERTEX.z, 1.0)).xyz;
	float morph = clamp((length(p0 - CAMERA_POSITION_WORLD) - m0) / max(m1 - m0, 1.0), 0.0, 1.0);
	g -= fract(g * 0.5) * 2.0 * morph;
	VERTEX = vec3(g.x / tile_quads, hfetch(g, layer), g.y / tile_quads);
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;     // scene position (distances, view)
	v_h = wpos.y;
	vec2 dc = wpos.xz - CAMERA_POSITION_WORLD.xz;
	float drop = dot(dc, dc) * earth_curve;
	VERTEX.y -= drop;
	wpos.y -= drop;
	v_morph = vec2(m0, m1);
	v_shadow = macro_shadow(vec3(wpos.x + world_origin.x, v_h, wpos.z + world_origin.y));
	v_layer = layer;
	v_level = INSTANCE_CUSTOM.y;
	v_grid = g;
	v_step = size / tile_quads;
	wnorm = vec3(0.0, 1.0, 0.0);
}

// Texture coordinates for a texture repeating every `period` metres, from the scene position: the origin's share is
// taken modulo the period first, so the numbers stay small (full precision) however far from the map centre.
vec2 tc(vec2 scene_xz, float period) {
	return (scene_xz + mod(world_origin, vec2(period))) / period;
}

// Heights on the next coarser level's grid (every other sample of this tile), central differences two samples apart:
// the normal the parent tile would show here. Blended in with the same morph as the geometry, so when a tile splits
// into its four children the shading does not jump to the finer detail (the patch "pop" on mountains).
float htexel(ivec2 s, int layer) {
	s = clamp(s, ivec2(-1), ivec2(int(tile_quads) + 1));
	return texelFetch(heights, ivec3(s + 1, layer), 0).r * h_scale + h_offset;
}

// height on the parent's grid: bilinear between this tile's even samples only (exactly the parent's own samples)
float hcoarse(vec2 g, int layer) {
	vec2 p = g * 0.5;
	vec2 i = floor(p);
	vec2 f = p - i;
	ivec2 s = ivec2(i) * 2;
	float a = mix(htexel(s, layer), htexel(s + ivec2(2, 0), layer), f.x);
	float b = mix(htexel(s + ivec2(0, 2), layer), htexel(s + ivec2(2, 2), layer), f.x);
	return mix(a, b, f.y);
}

vec3 coarse_normal(vec2 g, float layer, float step_m) {
	int l = int(layer + 0.5);
	float hx = hcoarse(g + vec2(2.0, 0.0), l) - hcoarse(g - vec2(2.0, 0.0), l);
	float hz = hcoarse(g + vec2(0.0, 2.0), l) - hcoarse(g - vec2(0.0, 2.0), l);
	return normalize(vec3(-hx, 4.0 * step_m, -hz));
}

float cls_at(vec2 g, float layer) {
	return texelFetch(cover, ivec3(ivec2(g) + 1, int(layer + 0.5)), 0).r * 255.0;
}

// ground colour for a WorldCover class
vec3 cover_col(float c, float macro, float macro2, float det, float fields, float hgt) {
	vec3 grass = mix(vec3(0.08, 0.13, 0.045), vec3(0.15, 0.17, 0.07), macro2);
	vec3 bare = mix(vec3(0.3, 0.25, 0.19), vec3(0.36, 0.33, 0.29), macro);         // Ladakh: ochre to grey scree
	bare = mix(bare, bare * vec3(0.78, 0.8, 0.86), smoothstep(4200.0, 5600.0, hgt)); // greyer high up
	if (c < 15.0) return mix(vec3(0.03, 0.06, 0.03), vec3(0.06, 0.1, 0.045), det);   // tree cover (conifer canopy)
	if (c < 25.0) return mix(grass, bare, 0.45) * 0.9;                                // shrubland
	if (c < 35.0) return grass;                                                         // grassland
	if (c < 45.0) {                                                                     // cropland: a patchwork of fields
		vec3 f1 = vec3(0.09, 0.14, 0.045), f2 = vec3(0.15, 0.16, 0.07), f3 = vec3(0.13, 0.12, 0.07), f4 = vec3(0.11, 0.155, 0.05);
		return fields < 0.25 ? f1 : (fields < 0.5 ? f2 : (fields < 0.75 ? f3 : f4));
	}
	if (c < 55.0) {                                                                     // built-up: roofs among trees and gardens
		vec3 roofs = mix(vec3(0.12, 0.11, 0.1), vec3(0.18, 0.16, 0.14), fields);
		return mix(roofs, grass * 0.75, 0.25 + smoothstep(0.4, 0.7, det) * 0.4);
	}
	if (c < 65.0) return bare;                                                          // bare / sparse vegetation
	if (c < 75.0) return vec3(0.84, 0.87, 0.92) * (0.93 + 0.07 * det);                // snow and ice
	if (c < 85.0) return vec3(0.03, 0.07, 0.08);                                        // water
	if (c < 97.0) return vec3(0.12, 0.15, 0.08);                                        // wetland, mangroves
	return mix(vec3(0.24, 0.22, 0.14), bare, 0.4);                                      // moss and lichen
}

void fragment() {
	bool lt = v_lite > 0.5;
	float h = v_h;
	{
		float hx = hfetch(v_grid + vec2(1.0, 0.0), v_layer) - hfetch(v_grid - vec2(1.0, 0.0), v_layer);
		float hz = hfetch(v_grid + vec2(0.0, 1.0), v_layer) - hfetch(v_grid - vec2(0.0, 1.0), v_layer);
		vec3 n = normalize(vec3(-hx, 2.0 * v_step, -hz));
		float dist = length(CAMERA_POSITION_WORLD - wpos);
		// shading morph (see coarse_normal): towards the outer edge of its range a tile shades like its parent
		float morph = clamp((dist - v_morph.x) / max(v_morph.y - v_morph.x, 1.0), 0.0, 1.0);
		if (morph > 0.0) {
			n = normalize(mix(n, coarse_normal(v_grid, v_layer, v_step), morph));
		}
		float slope = 1.0 - clamp(n.y, 0.0, 1.0);
		vec2 sp = wpos.xz;
		// fine detail that only reads up close: the wandering cover boundaries fade out by FINE_FAR (beyond it a 32 m
		// sample is a few pixels and the wander is invisible), the 8 m grain is gone by 900 m and the close-up relief
		// by 700 m (their weights are zero beyond, so those lookups are skipped there)
		const float FINE_NEAR = 5000.0;
		const float FINE_FAR = 6500.0;
		float fine = lt ? 0.0 : 1.0 - smoothstep(FINE_NEAR, FINE_FAR, dist);
		float macro = texture(macro_tex, tc(sp, 16000.0)).r;
		float macro2 = lt ? macro : texture(macro_tex, tc(sp, 4000.0) + 0.5).r;
		float det = texture(detail_tex, tc(sp, 64.0)).r;
		float det2 = (lt || dist > 900.0) ? det : texture(detail_tex, tc(sp, 8.0) + 0.3).r;
		// fields: irregular cells about 125 m across (cell index from a 64 km periodic frame, so it survives origin moves)
		vec2 fw = (sp + mod(world_origin, vec2(64000.0))) / 125.0;
		vec2 warp = vec2(0.0);
		if (!lt) {
			// (the field outlines' wobble stays at every distance: a field's colour is picked per cell, so fading
			// the wobble would make distant fields change colour as you fly)
			fw += (vec2(texture(detail_tex, tc(sp, 400.0)).r, texture(detail_tex, tc(sp, 400.0) + 0.5).r) - 0.5) * 1.4;
		}
		if (fine > 0.0) {
			// land cover, blended between the four nearest samples, read through a little noise so class boundaries
			// wander naturally instead of following the 32 m grid
			warp = ((vec2(texture(detail_tex, tc(sp, 180.0)).r, texture(detail_tex, tc(sp, 180.0) + 0.37).r) - 0.5) * 2.2
					+ (vec2(texture(detail_tex, tc(sp, 50.0) + 0.11).r, texture(detail_tex, tc(sp, 50.0) + 0.61).r) - 0.5) * 0.8) * fine;
		}
		float fields = fract(sin(dot(floor(fw), vec2(12.9898, 78.233))) * 43758.5453);
		vec2 gw = clamp(v_grid + warp - 0.5, vec2(-1.0), vec2(tile_quads + 0.99));
		vec2 g0 = floor(gw);
		vec2 f = gw - g0;
		vec3 c00 = cover_col(cls_at(g0, v_layer), macro, macro2, det, fields, h);
		vec3 c10 = cover_col(cls_at(g0 + vec2(1.0, 0.0), v_layer), macro, macro2, det, fields, h);
		vec3 c01 = cover_col(cls_at(g0 + vec2(0.0, 1.0), v_layer), macro, macro2, det, fields, h);
		vec3 c11 = cover_col(cls_at(g0 + vec2(1.0, 1.0), v_layer), macro, macro2, det, fields, h);
		vec3 c = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
		float c_here = cls_at(g0, v_layer);
		if (morph > 0.0 && !lt) {
			// the parent's land cover: only every other sample, so the class blocks are twice as big
			// the parent reads its cover through the same warp in its own (twice as coarse) sample units
			vec2 gc = clamp(v_grid * 0.5 + warp - 0.5, vec2(0.0), vec2(tile_quads * 0.5 - 0.001));
			vec2 q0 = floor(gc);
			vec2 fq = gc - q0;
			vec3 p00 = cover_col(cls_at(q0 * 2.0, v_layer), macro, macro2, det, fields, h);
			vec3 p10 = cover_col(cls_at(q0 * 2.0 + vec2(2.0, 0.0), v_layer), macro, macro2, det, fields, h);
			vec3 p01 = cover_col(cls_at(q0 * 2.0 + vec2(0.0, 2.0), v_layer), macro, macro2, det, fields, h);
			vec3 p11 = cover_col(cls_at(q0 * 2.0 + vec2(2.0, 2.0), v_layer), macro, macro2, det, fields, h);
			c = mix(c, mix(mix(p00, p10, fq.x), mix(p01, p11, fq.x), fq.y), morph);
			if (morph > 0.5) {
				c_here = cls_at(q0 * 2.0, v_layer);
			}
		}
		float snowc = (c_here > 65.0 && c_here < 75.0) ? 1.0 : 0.0;
		float waterc = (c_here > 75.0 && c_here < 85.0) ? 1.0 : 0.0;
		// steep faces are rock whatever the cover says (snow does not stay on cliffs)
		float rock_det = (lt || dist > FINE_FAR) ? det : mix(det, texture(detail_tex, tc(sp, 40.0) + 0.7).r, fine);
		vec3 rock = mix(vec3(0.24, 0.22, 0.21), vec3(0.38, 0.35, 0.32), rock_det);
		rock = mix(rock, rock * vec3(1.08, 0.96, 0.84), macro2 * 0.6);
		float rock_amt = smoothstep(0.38, 0.6, slope + (rock_det - 0.5) * 0.12) * (1.0 - waterc);
		c = mix(c, rock, rock_amt);
		c *= mix(0.9 + 0.2 * det2, 1.0, smoothstep(150.0, 900.0, dist));
		vec3 nw = n;
		if (!lt && dist < 700.0) {
			vec2 dn = texture(detail_nrm, tc(sp, 24.0)).xy * 2.0 - 1.0;
			float relief = (1.0 - smoothstep(60.0, 700.0, dist)) * (0.35 + 0.65 * rock_amt) * (1.0 - waterc);
			nw = normalize(n + vec3(dn.x, 0.0, dn.y) * relief * 0.6);
		}
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		ALBEDO = c;
		ROUGHNESS = mix(mix(0.95, 0.55, snowc * (1.0 - rock_amt)), 0.08, waterc);
		SPECULAR = mix(mix(0.25, 0.45, snowc), 0.6, waterc);
		v_rough = ROUGHNESS;
		v_wet = SPECULAR;
		// aerial perspective (replaces the scene fog on this terrain): the haze along the line of sight thins with
		// height, so valley floors fade blue-grey with distance while high ridges stay crisp, and the farthest
		// ranges keep their silhouette against the sky instead of vanishing into it
		if (haze_density > 0.0) {
			float depth = haze_density * aerial_k * dist * haze_mean(CAMERA_POSITION_WORLD.y, h);
			float haze = 1.0 - exp(-depth);
			vec3 hc = haze_color;
			if (dot(sun_xz, sun_xz) > 0.25) {
				vec2 dh = normalize(wpos.xz - CAMERA_POSITION_WORLD.xz + vec2(1e-5));
				float toward = pow(clamp(dot(dh, sun_xz) * 0.5 + 0.5, 0.0, 1.0), 3.0);
				hc = mix(hor_away, hor_toward, toward);
			}
			// a faint blue cast first (air light), the grey-white of the haze itself only far away
			hc = mix(hc * vec3(0.82, 0.9, 1.08), hc, smoothstep(0.3, 0.8, haze));
			// ... except right at the far plane, where the land fades fully into the sky (no cut-off edge)
			float cap = mix(aerial_max, 1.0, smoothstep(0.85 * view_far, 0.98 * view_far, dist));
			FOG = vec4(hc, min(max(haze, smoothstep(0.85 * view_far, 0.98 * view_far, dist)), cap));
		}
		if (debug_lod) {
			vec3 tints[6] = vec3[](vec3(1.0, 0.3, 0.3), vec3(0.3, 1.0, 0.3), vec3(0.3, 0.4, 1.0), vec3(1.0, 1.0, 0.3), vec3(1.0, 0.3, 1.0), vec3(0.3, 1.0, 1.0));
			ALBEDO = tints[int(v_level) % 6] * (0.6 + 0.4 * fract(v_grid.x * 0.5 + v_grid.y * 0.5));
		}
	}
}


// Sun and moon light with the mountains' cast shadows (v_shadow) on top of the shadow maps (ATTENUATION).
// Lambert diffuse and a Blinn-Phong highlight from the roughness (glints on lakes and rivers, a sheen on snow).
void light() {
	float sh = LIGHT_IS_DIRECTIONAL ? v_shadow : 1.0;
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR / PI * sh;
	vec3 hv = normalize(LIGHT + VIEW);
	float r4 = max(pow(v_rough, 4.0), 1e-4);
	float n = 2.0 / r4 - 2.0;
	float spec = pow(clamp(dot(NORMAL, hv), 0.0, 1.0), n) * (n + 8.0) / (8.0 * PI);
	float fres = v_wet * 0.08 + (1.0 - v_wet * 0.08) * pow(1.0 - clamp(dot(VIEW, hv), 0.0, 1.0), 5.0);
	SPECULAR_LIGHT += spec * fres * ndl * ATTENUATION * LIGHT_COLOR / PI * sh;
}
