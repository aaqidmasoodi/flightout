shader_type spatial;
// Weathered cockpit paint (Su-27S turquoise, black panels, bare metal parts).
// Vertex colour from blender/build_cockpit.py: R = edge wear on bevelled convex edges, G = grime (low in the tub,
// concave corners), B = per-part random. Wear chips the paint through to the primer or metal underneath;
// horizontal surfaces low in the cockpit (floor, console tops) also get boot and glove scuffs.
// B = baked ambient occlusion (contact shadows in corners, under lips, around bezels); A = baked floodlight.
// The paint has a fine orange-peel and brush texture in its normal (screen-space bump) and its sheen varies,
// so light rolls across curved parts instead of lying flat on them.
render_mode blend_mix, cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform vec3 base_color : source_color = vec3(0.40, 0.63, 0.62);
uniform vec3 under_color : source_color = vec3(0.62, 0.62, 0.60);
uniform float roughness_base : hint_range(0.0, 1.0) = 0.6;
uniform float metallic_base : hint_range(0.0, 1.0) = 0.0;
uniform float under_metallic : hint_range(0.0, 1.0) = 0.75;
uniform float wear : hint_range(0.0, 2.0) = 1.0;
uniform float grime : hint_range(0.0, 2.0) = 1.0;
uniform float scuffs : hint_range(0.0, 2.0) = 1.0;
uniform float cabin = 0.0;           // set by scripts/aircraft/cockpit.gd (cockpit lights)
uniform float mottle : hint_range(0.0, 0.5) = 0.07;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float bump : hint_range(0.0, 4.0) = 1.0;
// surface finish, all procedural in the part's own space (millimetre detail, faded out when it gets sub-pixel):
// 0 enamel paint (orange peel, faint hammer)   1 crinkle / wrinkle finish (black panels and bezels)
// 2 grained vinyl / leather (pads, glareshield, seat)   3 ribbed rubber matting (floor)
// 4 brushed metal   5 moulded rubber / plastic stipple   6 woven fabric
uniform int finish = 0;

varying vec3 lpos;
varying vec3 lnrm;
varying vec4 mask;

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x),
			mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x),
			mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int k = 0; k < 4; k++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.3);
		a *= 0.5;
	}
	return s;
}

void vertex() {
	lpos = VERTEX;
	lnrm = NORMAL;
	mask = COLOR;
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	float n1 = fbm(lpos * 55.0);
	float n2 = fbm(lpos * 8.0 + 3.1);
	float chip = smoothstep(0.42, 0.5, mask.r * wear * (0.55 + 0.9 * n1));
	// scuffs: fine scratches on upward faces below the canopy sill (floor, console tops, footrests)
	float up = smoothstep(0.55, 0.9, lnrm.y) * (1.0 - smoothstep(0.5, 0.7, lpos.y));
	float sc = smoothstep(0.74, 0.8, fbm(lpos * vec3(140.0, 40.0, 30.0))) * up * scuffs;
	chip = max(chip, sc * 0.7);
	float g = clamp(mask.g * grime * (0.55 + 0.9 * n2), 0.0, 1.0);
	vec3 c = base_color * (1.0 + (n2 - 0.5) * mottle * 2.0);
	// ambient occlusion: darkens what the sky cannot reach, and a little of the direct light too
	float ao = mix(1.0, (mask.b >= 0.0 && mask.b <= 1.0) ? mask.b : 1.0, ao_strength);
	ao = pow(ao, 1.4);
	c = mix(c, c * vec3(0.52, 0.5, 0.46), g * 0.6);
	c = mix(c, under_color * (0.85 + 0.3 * n1), chip);
	ALBEDO = c * mix(0.62, 1.0, ao);
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	// micro surface: the finish's height field, applied as a screen-space bump
	float h = 0.0;
	float freq = 420.0;
	float amp = 0.0009;
	float rough_mod = 0.0;
	float cav = 0.0;                                       // darkening in the low parts of the texture
	if (finish == 1) {
		// crinkle: tight wrinkles (ridged noise), satin peaks, dull valleys
		freq = 520.0;
		float r = 1.0 - abs(vnoise(lpos * freq) * 2.0 - 1.0);
		float r2 = 1.0 - abs(vnoise(lpos * freq * 2.3 + 7.1) * 2.0 - 1.0);
		h = r * 0.65 + r2 * 0.35;
		amp = 0.0011;
		rough_mod = (0.5 - h) * 0.25;
		cav = 1.0 - h;
	} else if (finish == 2) {
		// grained leather / vinyl: pebbled cells with fine creases and pores
		freq = 380.0;
		float cells = 1.0 - abs(vnoise(lpos * freq) * 2.0 - 1.0);
		float pores = smoothstep(0.72, 0.85, vnoise(lpos * freq * 3.1 + 2.0));
		float crease = fbm(lpos * 40.0);
		h = cells * 0.7 - pores * 0.35 + crease * 0.3;
		amp = 0.0012;
		rough_mod = (0.5 - cells) * 0.2 + pores * 0.1;
		cav = (1.0 - cells) * 0.8 + pores * 0.4;
	} else if (finish == 3) {
		// ribbed rubber matting: raised ribs across the floor (local x), with a worn stipple
		freq = 60.0;
		float rib = smoothstep(0.18, 0.3, abs(fract(lpos.z * 70.0) - 0.5));
		h = rib + vnoise(lpos * 600.0) * 0.25;
		amp = 0.0016;
		rough_mod = (1.0 - rib) * 0.1;
		cav = 1.0 - rib;
	} else if (finish == 4) {
		// brushed metal: fine streaks along one direction plus light machining marks
		freq = 300.0;
		h = vnoise(lpos * vec3(2400.0, 40.0, 40.0)) * 0.7 + vnoise(lpos * 300.0) * 0.3;
		amp = 0.0005;
		rough_mod = (h - 0.5) * 0.25;
	} else if (finish == 5) {
		// moulded rubber / plastic: soft stipple
		freq = 700.0;
		h = vnoise(lpos * freq) * 0.7 + vnoise(lpos * freq * 2.2) * 0.3;
		amp = 0.0006;
		rough_mod = (0.5 - h) * 0.1;
		cav = (1.0 - h) * 0.4;
	} else if (finish == 6) {
		// woven fabric (straps, cushions): over-under weave
		freq = 500.0;
		float wx = sin(lpos.x * 900.0) * sin(lpos.y * 900.0 + lpos.z * 900.0);
		h = wx * 0.5 + 0.5 + vnoise(lpos * 300.0) * 0.3;
		amp = 0.0007;
		cav = (1.0 - h) * 0.5;
	} else {
		// enamel: orange peel and a faint hammered dimpling
		h = fbm(lpos * 420.0) * 0.45 + vnoise(lpos * 110.0) * 0.55;
		amp = 0.0019;
		rough_mod = (0.5 - h) * 0.12;
	}
	h = h * (1.0 - chip * 0.6) + chip * 0.8;            // chipped spots sit lower, with a small step
	vec3 dpx = dFdx(VERTEX);
	vec3 dpy = dFdy(VERTEX);
	vec3 r1 = cross(dpy, NORMAL);
	vec3 r2 = cross(NORMAL, dpx);
	float det = dot(dpx, r1);
	vec3 grad = sign(det) * (dFdx(h) * r1 + dFdy(h) * r2);
	float fade = 1.0 - smoothstep(0.25, 0.9, length(fwidth(lpos * freq)));   // no shimmer when the grain gets sub-pixel
	// scale-free form (divide by |det| first) and a guard: where the screen derivatives vanish (degenerate pixels)
	// the bump is skipped instead of producing a NaN normal, which bloom would smear into white halos
	vec3 nb = NORMAL;
	if (abs(det) > 1e-14) {
		nb = NORMAL - grad * (amp * bump * fade / abs(det));
	}
	float nl = length(nb);
	NORMAL = (nl > 1e-6 && !isnan(nl) && !isinf(nl)) ? nb / nl : NORMAL;
	ALBEDO *= 1.0 - cav * 0.22 * fade;
	// cockpit lights: baked floodlighting (vertex alpha, with soft shadows) lifts the surface faintly; no real-time
	// lamps, so nothing glares or reflects in the canopy and HUD glass
	// (alpha clamped: pow() of a negative value is NaN, and a NaN pixel blooms into a white blob)
	float lit = (mask.a >= 0.0 && mask.a <= 1.0) ? mask.a : 0.0;     // also rejects NaN (every comparison fails)
	EMISSION = cabin > 0.0 ? c * cabin * (0.03 + 0.97 * pow(lit, 1.6)) : vec3(0.0);
	// sheen: worn smooth where hands and boots rub (edges, chips), duller in the grimy corners
	// floor at 0.38: a cockpit is all satin and worn surfaces; anything glossier turns into tiny mirror sparks of
	// the sun (HDR) on every bevel and chip, which the bloom then smears into white blobs
	ROUGHNESS = clamp(roughness_base + (n1 - 0.5) * 0.22 + (n2 - 0.5) * 0.12 + g * 0.2 + rough_mod * fade, 0.38, 1.0);
	SPECULAR = 0.5 * mix(0.35, 1.0, ao);              // no glints from deep inside corners
	METALLIC = mix(metallic_base, under_metallic * 0.6, chip);
}
