shader_type spatial;
// Rear-view mirror glass (scripts/aircraft/cockpit_mirrors.gd): shows the mirror's own reflection picture, rendered
// from your eye reflected in the mirror's plane through exactly the mirror's outline, so it lines up at any head
// position. The picture is the world seen from behind the glass, so it is flipped left to right here.
render_mode unshaded, cull_back, skip_vertex_transform, fog_disabled, shadows_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D reflection : source_color, filter_linear, repeat_disable;
uniform bool live = true;            // false: mirrors switched off in the settings, plain dark glass
uniform vec3 tint : source_color = vec3(0.82, 0.84, 0.86);   // silvered glass is not a perfect reflector

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec3 c = live ? texture(reflection, vec2(1.0 - UV.x, UV.y)).rgb : vec3(0.05, 0.055, 0.06);
	// a faint darkening towards the rim of the glass
	vec2 e = abs(UV - 0.5) * 2.0;
	float rim = 1.0 - 0.18 * smoothstep(0.85, 1.0, max(e.x, e.y));
	ALBEDO = c * tint * rim;
}
