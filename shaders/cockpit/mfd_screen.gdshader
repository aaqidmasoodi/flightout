shader_type spatial;
// Multifunction display glass: the page picture (a SubViewport texture drawn by scripts/avionics/mfd.gd) glows
// from behind a slightly glossy cover glass, so the cockpit's light still glints off it.
render_mode blend_mix, cull_back, specular_schlick_ggx, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D screen_tex : source_color, filter_linear, repeat_disable;
uniform float brightness = 1.15;

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec3 c = texture(screen_tex, UV).rgb;
	ALBEDO = c * 0.05 + vec3(0.004, 0.006, 0.005);
	ROUGHNESS = 0.14;
	SPECULAR = 0.45;
	EMISSION = c * brightness;
}
