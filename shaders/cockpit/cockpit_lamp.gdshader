shader_type spatial;
// Cockpit signal lamps and push-lights. The legend comes from labels.png (white text, alpha); `lit` is set per
// lamp by scripts/aircraft/cockpit.gd. Unlit, the lens is dark and the legend faintly readable; lit, the lens
// glows and the legend burns bright. Round lamps (no legend) pass use_legend = 0.
render_mode blend_mix, cull_back, specular_schlick_ggx, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D legend : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(1.0, 0.25, 0.1);
uniform float energy = 2.6;
instance uniform float lit = 0.0;
instance uniform float use_legend = 1.0;

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	float a = mix(1.0, texture(legend, UV).a, use_legend);
	vec3 lens = tint * 0.08 + vec3(0.015);
	ALBEDO = mix(lens, vec3(0.5), a * use_legend * 0.55);
	ROUGHNESS = 0.38;
	SPECULAR = 0.35;
	EMISSION = tint * energy * lit * mix(0.22, 1.0, a);
}
