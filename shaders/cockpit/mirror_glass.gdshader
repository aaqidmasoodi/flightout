shader_type spatial;
// Rear-view mirror glass (scripts/aircraft/cockpit_mirrors.gd).
//
// One wide picture of the view behind the jet is rendered each frame (from the canopy arch, looking aft) and all the
// mirrors share it. Each pixel of the glass works out where a real mirror would send your line of sight (the view
// ray from your eye, reflected about the glass's normal there) and looks that direction up in the shared picture.
// So the reflection follows the true optics: it shifts as your head moves, changes as the canopy (and the mirrors on
// it) swings open, and each mirror shows its own part of the scene. The glass is slightly convex, as real cockpit
// mirrors are, which widens what it shows. Only the direction is looked up, from one point, so things very close
// behind the jet are a little out of place; the tail and everything beyond is right.
render_mode unshaded, cull_back, skip_vertex_transform, fog_disabled, shadows_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform sampler2D reflection : source_color, filter_linear, repeat_disable;
uniform bool live = true;                   // false: folded away, nothing rendered, plain dark glass
uniform vec3 tint : source_color = vec3(0.82, 0.84, 0.86);   // silvered glass is not a perfect reflector
uniform mat3 capture_basis;                 // world direction -> the shared picture's camera space
uniform vec2 capture_tan;                   // tan of half the picture's field of view (across, up)
uniform float convex_radius = 1.6;          // m: the glass's curvature (a flat mirror would be infinite)
instance uniform vec2 size_m = vec2(0.22, 0.07);
instance uniform float corner_m = 0.014;

varying vec3 off_view;                      // this point's offset from the glass centre, in view space

void vertex() {
	vec2 local = VERTEX.xy;                  // the quad is centred on the glass: model x, y are metres from the centre
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
	vec3 nx = normalize(TANGENT);
	vec3 ny = normalize(cross(NORMAL, nx));
	off_view = nx * local.x + ny * local.y;
}

void fragment() {
	// rounded corners
	vec2 p = (UV - 0.5) * size_m;
	vec2 q = abs(p) - (size_m * 0.5 - corner_m);
	float dist = length(max(q, 0.0)) - corner_m;
	if (dist > 0.0) {
		discard;
	}
	vec3 c = vec3(0.05, 0.055, 0.06);
	if (live) {
		vec3 n = normalize(normalize(NORMAL) * convex_radius + off_view);   // convex: the normal leans out towards the rim
		vec3 r = reflect(normalize(VERTEX), n);                      // the line of sight after the mirror (view space)
		vec3 w = mat3(INV_VIEW_MATRIX) * r;                          // ... in world directions
		vec3 k = capture_basis * w;                                  // ... in the picture's camera space
		if (k.z < -0.02) {
			vec2 s = k.xy / (-k.z) / capture_tan;                    // -1..1 inside the picture
			vec2 uv = vec2(s.x, -s.y) * 0.5 + 0.5;
			vec3 img = texture(reflection, clamp(uv, vec2(0.002), vec2(0.998))).rgb;
			// past the picture's edge (looking at the mirror from far off its axis): fade to the dark rim
			float inside = 1.0 - smoothstep(0.96, 1.04, max(abs(s.x), abs(s.y)));
			c = mix(c, img, inside);
		}
	}
	float rim = 1.0 - 0.18 * smoothstep(-0.008, 0.0, dist);
	ALBEDO = c * tint * rim;
}
