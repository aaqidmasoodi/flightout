shader_type spatial;
// The cloud behind the nearest surface around each pixel (shaders/clouds_composite.glsl, overlay_b), drawn just
// before the main cloud overlay (shaders/cloud_overlay.gdshader) and depth-tested a little beyond that surface: on
// an MSAA edge, the samples of the jet keep their own colour and only the samples behind it take this cloud.
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

global uniform sampler2D cloud_overlay_b : filter_nearest;
global uniform sampler2D cloud_layer : filter_nearest;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
	vec4 c = texture(cloud_overlay_b, SCREEN_UV);
	ALBEDO = c.rgb;
	ALPHA = clamp(1.0 - c.a, 0.0, 1.0);
	float near = textureLod(cloud_layer, SCREEN_UV, 0.0).a * 1000.0;
	float d = near * 1.03 + 1.0;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
	vec3 dir = normalize(v.xyz / v.w);
	vec4 clip = PROJECTION_MATRIX * vec4(dir * d, 1.0);
	DEPTH = clamp(clip.z / clip.w, 1e-9, 1.0);
}
