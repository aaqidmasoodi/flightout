shader_type spatial;
// Rear-view mirror glass (scripts/aircraft/cockpit_mirrors.gd): shows the mirror's picture of the view behind the jet,
// flipped left to right as a mirror shows it, inside a rectangle with rounded corners.
render_mode unshaded, cull_back, skip_vertex_transform, fog_disabled, shadows_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D reflection : source_color, filter_linear, repeat_disable;
uniform bool live = true;            // false: mirrors switched off in the settings, plain dark glass
uniform vec3 tint : source_color = vec3(0.82, 0.84, 0.86);   // silvered glass is not a perfect reflector
uniform vec2 size_m = vec2(0.22, 0.07);                       // the glass, in metres
uniform float corner_m = 0.014;                               // corner radius, in metres

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	// rounded corners: distance outside a rectangle shrunk by the radius
	vec2 p = (UV - 0.5) * size_m;
	vec2 q = abs(p) - (size_m * 0.5 - corner_m);
	float dist = length(max(q, 0.0)) - corner_m;
	if (dist > 0.0) {
		discard;
	}
	vec3 c = live ? texture(reflection, vec2(1.0 - UV.x, UV.y)).rgb : vec3(0.05, 0.055, 0.06);
	// a faint darkening towards the rim of the glass
	float rim = 1.0 - 0.18 * smoothstep(-0.008, 0.0, dist);
	ALBEDO = c * tint * rim;
}
