// Cloud cover for everything drawn after the clouds (the clouds are composited at the start of the transparent
// pass, scripts/world/volumetric_clouds.gd): lights, trails, flames, the sea. One rule for all of them: how much
// of the light from a point at this distance gets through the cloud in front of it.
//
// The cloud pass writes, per pixel (shaders/clouds_composite.glsl): r the clouds' transmittance, g the distance
// where they start, b where they end (km). A point before the cloud is fully seen, a point behind it is dimmed by
// all of it, a point inside by the share of the cloud in front of it.
//
// Only the main camera's view has this layer (the cockpit mirrors' picture has no clouds): pass `main_view`, from
// a varying set in vertex() as
//     v_main = all(equal(INV_VIEW_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz)) ? 1.0 : 0.0;
global uniform sampler2D cloud_layer : filter_nearest;

// 1 = nothing in front of this surface, 0 = fully hidden by clouds in front of it
float cloud_visibility(vec2 screen_uv, float dist_m, float main_view) {
	if (main_view < 0.5) {
		return 1.0;
	}
	vec4 l = textureLod(cloud_layer, screen_uv, 0.0);
	float front = l.g * 1000.0;
	float back = max(l.b * 1000.0, front + 40.0);
	return mix(1.0, clamp(l.r, 0.0, 1.0), clamp((dist_m - front) / (back - front), 0.0, 1.0));
}
