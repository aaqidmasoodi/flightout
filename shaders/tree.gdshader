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
	if (!mine) {
		VERTEX = vec3(0.0);
	} else {
		float phase = (mo.x + mo.y) * 0.045;
		float k = pow(max(VERTEX.y, 0.0) / 12.0, 2.0) * wind;
		VERTEX.x += sin(TIME * 1.3 + phase) * 0.35 * k;
		VERTEX.z += cos(TIME * 1.1 + phase * 1.3) * 0.25 * k;
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	BACKLIGHT = vec3(0.08, 0.12, 0.04);
}
