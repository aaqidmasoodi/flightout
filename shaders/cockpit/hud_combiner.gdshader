shader_type spatial;
// HUD combiner glass: nearly clear, like a hologram plate (a faint sheen that grows toward grazing angles), with
// saturated green symbology looked up by viewing direction (degrees from the aircraft's boresight), so it is
// collimated: fixed against the world, not the glass. The symbols stay below the tonemapper's white point so they
// read green, never washed out to white.
render_mode blend_mix, cull_disabled, depth_draw_never, unshaded, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D hud_tex : source_color, filter_linear, repeat_disable;
uniform mat3 to_aircraft;                 // world -> aircraft axes (aircraft forward is -Z)
uniform float fov_deg = 18.0;             // degrees the texture covers, edge to edge
uniform float el0 = 0.0;                  // elevation (deg) at the texture's centre
uniform float brightness = 0.95;
uniform vec4 window = vec4(-5.9, 5.9, -5.3, 3.7); // usable az min/max, el min/max (deg): symbology margin
uniform float window_fade = 0.35;           // degrees of soft fade at the window edge
uniform vec3 glass_tint : source_color = vec3(0.62, 0.78, 0.74);
uniform float glass_alpha = 0.018;
uniform float sheen = 0.09;                 // extra reflection toward grazing angles

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec3 ray_world = (INV_VIEW_MATRIX * vec4(-VIEW, 0.0)).xyz;
	vec3 r = to_aircraft * ray_world;
	float az = degrees(atan(r.x, -r.z));
	float el = degrees(atan(r.y, -r.z));
	vec2 uv = vec2(0.5 + az / fov_deg, 0.5 - (el - el0) / fov_deg);
	vec4 s = vec4(0.0);
	if (r.z < 0.0 && uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
		s = texture(hud_tex, uv);
		float m = smoothstep(window.x - window_fade, window.x, az) * smoothstep(window.y + window_fade, window.y, az)
				* smoothstep(window.z - window_fade, window.z, el) * smoothstep(window.w + window_fade, window.w, el);
		s.a *= m;
	}
	float a = s.a;
	float fres = pow(1.0 - clamp(abs(dot(normalize(NORMAL), VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = mix(glass_tint * 0.5, s.rgb * brightness, a);
	ALPHA = clamp(max(glass_alpha + sheen * fres, a * 0.92), 0.0, 1.0);
}
