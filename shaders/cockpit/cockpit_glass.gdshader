shader_type spatial;
// Cockpit glazing: thick canopy acrylic, armoured windscreen, instrument cover glass and the HUD combiner.
// Both faces of solidified glass draw (you see the inner and the outer surface), reflections grow strongly
// toward grazing angles (Fresnel), and fine scratches and haze catch the light like a used canopy does.
render_mode blend_mix, cull_disabled, depth_draw_never, specular_schlick_ggx, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform vec3 tint : source_color = vec3(0.9, 0.96, 0.94);
uniform float base_alpha : hint_range(0.0, 1.0) = 0.04;
uniform float fresnel_alpha : hint_range(0.0, 1.0) = 0.5;
uniform float fresnel_power : hint_range(1.0, 8.0) = 4.0;
uniform float roughness_base : hint_range(0.0, 1.0) = 0.03;
uniform float scratches : hint_range(0.0, 2.0) = 0.0;
uniform float haze : hint_range(0.0, 1.0) = 0.0;

varying vec3 lpos;

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

void vertex() {
	lpos = VERTEX;
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec3 n = FRONT_FACING ? NORMAL : -NORMAL;
	NORMAL = n;
	float f = pow(1.0 - clamp(abs(dot(n, VIEW)), 0.0, 1.0), fresnel_power);
	float s = 0.0;
	if (scratches > 0.0) {
		// long thin wipe marks (stretched noise in two directions) plus sparse fine pits
		float a = vnoise(lpos * vec3(420.0, 12.0, 420.0));
		float b = vnoise(lpos.zxy * vec3(16.0, 380.0, 380.0));
		s = (smoothstep(0.86, 0.93, a) + smoothstep(0.88, 0.95, b) * 0.7) * scratches;
		s += smoothstep(0.93, 0.97, vnoise(lpos * 900.0)) * 0.5 * scratches;
	}
	float h = haze * smoothstep(0.35, 0.85, vnoise(lpos * 5.0));
	ALBEDO = tint * (0.55 + 0.45 * h);
	ROUGHNESS = clamp(roughness_base + s * 0.45 + h * 0.35, 0.0, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.7;
	ALPHA = clamp(base_alpha + fresnel_alpha * f + s * 0.18 + h * 0.08, 0.0, 1.0);
}
