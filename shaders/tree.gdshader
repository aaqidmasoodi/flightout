shader_type spatial;
render_mode diffuse_burley, specular_disabled, cull_disabled;
// Trees: vertex colours times the per-instance tint, soft foliage normals baked into the mesh, gentle wind sway.
// Per-instance LOD: each tree is drawn by exactly one of the two sets (near detailed / far simple), chosen by its
// own distance with a dithered threshold, so there is no popping and no double drawing.

uniform float wind = 0.3;
uniform bool far_set = false;
uniform float near_radius = 1100.0;
uniform float band = 220.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float d = length(origin - CAMERA_POSITION_WORLD);
	float edge = near_radius - band * hash(origin.xz * 0.013);
	bool mine = far_set ? (d >= edge) : (d < edge);
	if (!mine) {
		VERTEX = vec3(0.0);
	} else {
		float phase = (origin.x + origin.z) * 0.045;
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
