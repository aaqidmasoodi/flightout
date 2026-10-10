shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, world_vertex_coords, shadows_disabled, fog_disabled;
// Airfield lights (scripts/world/airfield_lights.gd): every light is a point drawn as a small glowing disc that
// always faces the camera. One MultiMesh instance per light, its origin sitting exactly on the fixture.
//   - it sinks with the Earth's curvature like the terrain and the runway (otherwise far lights float above them)
//   - it never gets smaller than `min_px` pixels, so a lit runway reads from far away at night, as real ones do
//   - lit at night (and dusk), off by day: except PAPIs (`day_on`), which are bright enough to use in daylight
//   - fades with distance as a real light does: full brightness up close, then falling off with range (the light
//     reaching you thins with the square of the distance; a display cannot show a sub-pixel point as bright as the
//     eye sees it, so the fall-off is gentler than the square, as flight simulators do), and dimmed by the haze
//     between you and it (the same thinning-with-height haze the terrain uses). From high above an airfield is a
//     faint string of points, not a crisp bright line.

uniform float size_m = 0.6;          // fixture glow size in metres (close up)
uniform float min_px = 2.5;          // and at least this many pixels
uniform float intensity = 6.0;       // HDR brightness at night (feeds the bloom)
uniform bool day_on = false;
uniform float full_range = 1500.0;   // m: full brightness up to here, then the fall-off
uniform float falloff = 1.5;         // brightness ~ (full_range / distance) ^ falloff beyond it
uniform float haze_density = 0.0;    // set with the terrain's (scripts/world/sky_system.gd): sea-level haze, per metre
float haze_mean(float y0, float y1) {
	// mean haze density between two heights (scale height 2.5 km), as the terrain and sky use
	const float H = 2500.0;
	y0 = max(y0, 0.0);
	y1 = max(y1, 0.0);
	float a = exp(-y0 / H);
	float b = exp(-y1 / H);
	float dy = y0 - y1;
	return abs(dy) < 1.0 ? a : H * (b - a) / dy;
}
global uniform float earth_curve;
#include "res://shaders/include/cloud_cover.gdshaderinc"
global uniform vec3 sun_dir;

varying vec4 v_col;
varying float v_main;

void vertex() {
	v_main = all(equal(INV_VIEW_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz)) ? 1.0 : 0.0;
	vec3 c = MODEL_MATRIX[3].xyz;                         // the fixture (scene coordinates)
	vec2 dc = c.xz - CAMERA_POSITION_WORLD.xz;
	c.y -= dot(dc, dc) * earth_curve;
	float d = max(length(CAMERA_POSITION_WORLD - c), 0.1);
	// metres per pixel at this distance: keep the disc at least min_px wide
	float m_per_px = 2.0 * d / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float s = max(size_m, min_px * m_per_px);
	vec2 q = (UV - 0.5) * vec2(1.0, -1.0);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	VERTEX = c + (right * q.x + up * q.y) * s;
	float range_dim = pow(clamp(full_range / d, 0.0, 1.0), falloff);
	float haze = exp(-haze_density * d * haze_mean(CAMERA_POSITION_WORLD.y, c.y));
	float night = 1.0 - smoothstep(-0.03, 0.12, sun_dir.y);
	float on = day_on ? max(night, 0.6) : night;
	// directional fixtures (INSTANCE_CUSTOM.xy = flat direction they shine towards, z = 1): threshold green only
	// towards the approach, runway end red only along the runway, approach lights and PAPI only towards arrivals
	if (INSTANCE_CUSTOM.z > 0.5) {
		vec2 to_cam = normalize(-dc + vec2(1e-4));
		on *= smoothstep(-0.05, 0.35, dot(to_cam, INSTANCE_CUSTOM.xy));
	}
	v_col = vec4(COLOR.rgb * intensity * range_dim * haze, on);
}

void fragment() {
	vec2 q = UV - 0.5;
	float r = length(q) * 2.0;
	float a = (1.0 - smoothstep(0.35, 1.0, r)) * v_col.a;
	if (a < 0.002) {
		discard;
	}
	// hidden by the cloud in front of it (and dimmed inside a cloud)
	ALBEDO = v_col.rgb * a * cloud_visibility(SCREEN_UV, length(VERTEX), v_main);
	ALPHA = a;
}
