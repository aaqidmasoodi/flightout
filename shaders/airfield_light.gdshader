shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, world_vertex_coords, shadows_disabled, fog_disabled;
// Airfield lights (scripts/world/airfield_lights.gd): every light is a point drawn as a small glowing disc that
// always faces the camera. One MultiMesh instance per light, its origin sitting exactly on the fixture.
//   - it sinks with the Earth's curvature like the terrain and the runway (otherwise far lights float above them)
//   - it never gets smaller than `min_px` pixels, so a lit runway reads from far away at night, as real ones do
//   - lit at night (and dusk), off by day: except PAPIs (`day_on`), which are bright enough to use in daylight

uniform float size_m = 0.6;          // fixture glow size in metres (close up)
uniform float min_px = 2.5;          // and at least this many pixels
uniform float intensity = 6.0;       // HDR brightness at night (feeds the bloom)
uniform bool day_on = false;
global uniform float earth_curve;
global uniform vec3 sun_dir;

varying vec4 v_col;

void vertex() {
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
	// brighter when the disc is small on screen (a distant light is a point with all its energy in a few pixels)
	float far_boost = clamp(min_px * m_per_px / size_m, 1.0, 3.0);
	float night = 1.0 - smoothstep(-0.03, 0.12, sun_dir.y);
	float on = day_on ? max(night, 0.6) : night;
	// directional fixtures (INSTANCE_CUSTOM.xy = flat direction they shine towards, z = 1): threshold green only
	// towards the approach, runway end red only along the runway, approach lights and PAPI only towards arrivals
	if (INSTANCE_CUSTOM.z > 0.5) {
		vec2 to_cam = normalize(-dc + vec2(1e-4));
		on *= smoothstep(-0.05, 0.35, dot(to_cam, INSTANCE_CUSTOM.xy));
	}
	v_col = vec4(COLOR.rgb * intensity * far_boost, on);
}

void fragment() {
	vec2 q = UV - 0.5;
	float r = length(q) * 2.0;
	float a = (1.0 - smoothstep(0.35, 1.0, r)) * v_col.a;
	if (a < 0.002) {
		discard;
	}
	ALBEDO = v_col.rgb * a;
	ALPHA = a;
}
