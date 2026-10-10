shader_type spatial;
// The volumetric clouds (scripts/world/volumetric_clouds.gd) blended over the scene: a full-screen surface drawn first
// in the transparent pass, so glass, the HUD, flames and particles draw over the clouds, and it lands in the
// multisampled image when MSAA is on (the cloud pass itself cannot write there).
// The overlay holds rgb in-scattered light and a transmittance: scene * a + rgb (premultiplied blending).
render_mode unshaded, blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

global uniform sampler2D cloud_overlay : filter_nearest;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);      // the quad covers the screen exactly, wherever the camera is
}

void fragment() {
	vec4 c = texture(cloud_overlay, SCREEN_UV);
	ALBEDO = c.rgb;
	ALPHA = clamp(1.0 - c.a, 0.0, 1.0);
}
