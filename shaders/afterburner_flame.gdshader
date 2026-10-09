shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;
// Afterburner plume: blue-white core at the nozzle fading to orange, flickering.

uniform float intensity = 1.0;
uniform float length_m = 3.8;

#include "res://shaders/include/cloud_cover.gdshaderinc"

varying float t;

void vertex() {
	t = clamp(-VERTEX.z / length_m, 0.0, 1.0);
}

void fragment() {
	float flick = 0.85 + 0.15 * sin(TIME * 55.0 + t * 18.0) * sin(TIME * 23.0);
	vec3 core = vec3(0.55, 0.7, 1.0);
	vec3 hot = vec3(1.0, 0.5, 0.12);
	vec3 col = mix(core, hot, smoothstep(0.05, 0.45, t));
	float fade = (1.0 - t);
	fade *= fade;
	float facing = abs(dot(NORMAL, VIEW));
	ALBEDO = col * fade * facing * intensity * flick * 1.8;
	ALBEDO *= cloud_visibility(SCREEN_UV, length(VERTEX));
}
