shader_type spatial;
render_mode diffuse_burley, specular_disabled, cull_disabled;
// Trees: vertex colours times the per-instance tint, soft foliage normals baked into the mesh, gentle wind sway.
// Per-instance LOD: each tree is drawn by exactly one of the two sets (near detailed / far simple), chosen by its
// own distance with a dithered threshold, so there is no popping and no double drawing.

uniform float wind = 0.3;
uniform bool far_set = false;
uniform float near_radius = 1100.0;
uniform float band = 220.0;
uniform float density = 1.0;          // fraction of trees drawn (lower presets thin forests evenly)
uniform float min_pixels = 2.5;      // trees shorter than this on screen are left to the canopy texture

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

global uniform vec2 world_origin;     // floating origin (scripts/world/world_data.gd)
global uniform float earth_curve;     // drawn curvature of the Earth (see terrain_cdlod.gdshader)
#include "res://shaders/include/terrain_shadow.gdshaderinc"

varying float v_sun;                  // 0 in a mountain's shadow

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 mo = origin.xz + world_origin;   // map position: per-tree choices must not change when the origin moves
	float d = length(origin - CAMERA_POSITION_WORLD);
	float h = hash(mo * 0.013);
	float edge = near_radius - band * h;
	bool mine = far_set ? (d >= edge) : (d < edge);
	// screen-size culling (as flight sims do): a tree only a few pixels tall adds speckle, not detail; thin those out
	// gradually (each tree has its own threshold), and the terrain's canopy texture carries the forest from there
	float tree_h = length(MODEL_MATRIX[1].xyz) * 14.0;
	float px = tree_h * abs(PROJECTION_MATRIX[1][1]) * 0.5 * VIEWPORT_SIZE.y / max(d, 1.0);   // y scale is negative under Vulkan
	if (px < mix(min_pixels, min_pixels * 2.5, h) || hash(mo * 0.071 + 3.7) > density) {
		mine = false;
	}
	v_sun = 1.0;
	if (!mine) {
		VERTEX = vec3(0.0);
	} else {
		float phase = (mo.x + mo.y) * 0.045;
		float k = pow(max(VERTEX.y, 0.0) / 12.0, 2.0) * wind;
		VERTEX.x += sin(TIME * 1.3 + phase) * 0.35 * k;
		VERTEX.z += cos(TIME * 1.1 + phase * 1.3) * 0.25 * k;
		// sink with the ground under it (the curvature drop, in the tree's own scale)
		vec2 dc = origin.xz - CAMERA_POSITION_WORLD.xz;
		VERTEX.y -= dot(dc, dc) * earth_curve / max(length(MODEL_MATRIX[1].xyz), 0.01);
		v_sun = macro_shadow_lite(vec3(mo.x, origin.y, mo.y));
	}
}

void fragment() {
	// in a mountain's shadow only the sky lights the tree (an approximation: the trees keep the engine's own lighting)
	ALBEDO = COLOR.rgb * mix(0.5, 1.0, v_sun);
	ROUGHNESS = 1.0;
	BACKLIGHT = vec3(0.08, 0.12, 0.04);
}
