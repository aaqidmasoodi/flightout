shader_type spatial;
// Autopilot panel face: a live texture (scripts/avionics/ap_panel.gd) on the panel and its push-button caps.
// Saturated colours (amber digits, green mode lights) glow; white legends and grey paint are just lit by the cockpit.
render_mode blend_mix, cull_back, depth_draw_opaque, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D face : source_color, filter_linear_mipmap, repeat_disable;
uniform float glow = 2.2;

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec3 c = texture(face, UV).rgb;
	float sat = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
	float lit = smoothstep(0.3, 0.55, sat);
	ALBEDO = mix(c, c * 0.25, lit);
	ROUGHNESS = mix(0.62, 0.3, lit);
	EMISSION = c * lit * glow;
}
