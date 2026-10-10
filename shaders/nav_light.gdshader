shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// An aircraft's lamp seen from a distance (scripts/aircraft/aircraft_effects.gd): a soft glow facing the camera,
// sized in metres around the lamp (so it shrinks with the jet as you pull away), never smaller than a couple of
// pixels (so a lit jet still reads as a light far away), and fading with range and haze the way real lights do
// (as the airfield lights do, shaders/airfield_light.gdshader). Before, it kept a fixed size on screen and full
// brightness: zoomed out, the lamps grew huge against a small jet.

uniform sampler2D glow : source_color, filter_linear, repeat_disable;
uniform vec3 color : source_color = vec3(1.0);
uniform float intensity = 2.2;       // brightness up close (times the night factor set by the script)
uniform float size_m = 0.45;         // glow diameter around the lamp, metres
uniform float min_px = 2.5;
uniform float max_px = 22.0;        // up close (from your own cockpit) a lamp is a bright bulb, not a big blot
uniform float full_range = 150.0;    // m: full brightness up to here
uniform float falloff = 1.3;         // then ~ (full_range / distance) ^ falloff
uniform float haze_density = 0.0;    // set with the terrain's (scripts/world/sky_system.gd)

float haze_mean(float y0, float y1) {
	const float H = 2500.0;
	y0 = max(y0, 0.0);
	y1 = max(y1, 0.0);
	float a = exp(-y0 / H);
	float b = exp(-y1 / H);
	float dy = y0 - y1;
	return abs(dy) < 1.0 ? a : H * (b - a) / dy;
}

#include "res://shaders/include/cloud_cover.gdshaderinc"

varying float v_k;
varying float v_main;

void vertex() {
	v_main = all(equal(INV_VIEW_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz)) ? 1.0 : 0.0;
	vec3 c = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = max(length(CAMERA_POSITION_WORLD - c), 0.05);
	float m_per_px = 2.0 * d / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float s = clamp(size_m, min_px * m_per_px, max_px * m_per_px);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec2 q = (UV - 0.5) * vec2(1.0, -1.0);
	vec3 w = c + (right * q.x + up * q.y) * s;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(w, 1.0));
	float range_dim = pow(clamp(full_range / d, 0.0, 1.0), falloff);
	float haze = exp(-haze_density * d * haze_mean(CAMERA_POSITION_WORLD.y, c.y));
	// the glow's energy spread over a larger disc than the lamp itself when it is held at min_px: dimmer per pixel
	float spread = clamp(size_m / s, 0.25, 1.0);
	v_k = intensity * range_dim * haze * spread;
}

void fragment() {
	float a = texture(glow, UV).a;
	ALBEDO = color * v_k * a * cloud_visibility(SCREEN_UV, length(VERTEX), v_main);
	ALPHA = a;
}
