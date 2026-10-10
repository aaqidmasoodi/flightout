shader_type spatial;
// The volumetric clouds (scripts/world/volumetric_clouds.gd) blended over the scene: a full-screen surface drawn first
// in the transparent pass, so glass, the HUD, flames and particles draw over the clouds, and it lands in the
// multisampled image when MSAA is on (the cloud pass itself cannot write there).
// The overlay holds rgb in-scattered light and a transmittance: scene * a + rgb (premultiplied blending).
//
// Depth-tested, at the distance where the cloud in this pixel begins (the cloud layer's front, a little nearer):
// with MSAA, a pixel on the jet's outline holds both jet and ground samples, while the cloud pass has one depth for
// it. Without the test, the cloud behind the ground samples was laid over the jet's samples too: a white fringe
// around the jet over clouds far below, flickering as the view moved. Now each sample nearer than the cloud keeps
// its own colour.
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

global uniform sampler2D cloud_overlay : filter_nearest;
global uniform sampler2D cloud_layer : filter_nearest;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);      // the quad covers the screen exactly, wherever the camera is
}

void fragment() {
	vec4 c = texture(cloud_overlay, SCREEN_UV);
	ALBEDO = c.rgb;
	ALPHA = clamp(1.0 - c.a, 0.0, 1.0);
	// the cloud's front (km), with a margin: the composite takes the whole cloud for a surface at 98 % of where its
	// march stopped (a mountain inside the cloud), so the test must never cut nearer than that
	float front = textureLod(cloud_layer, SCREEN_UV, 0.0).g * 1000.0;
	float d = max(front * 0.96 - 30.0, 0.05);
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
	vec3 dir = normalize(v.xyz / v.w);
	vec4 clip = PROJECTION_MATRIX * vec4(dir * d, 1.0);
	// (reverse depth: beyond the far plane would fall below the sky's 0 and fail; keep it just above)
	DEPTH = clamp(clip.z / clip.w, 1e-9, 1.0);
}
