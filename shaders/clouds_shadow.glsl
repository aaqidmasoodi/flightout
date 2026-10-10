#[compute]
#version 450
// The clouds' shadow map (a "Beer shadow map", Hillaire / Frostbite): how much cloud the sunlight passes through on
// its way down, for everything that the sun lights: the terrain, the trees, the trails, the jets, and the clouds
// themselves (beyond the first few hundred metres of their own light march).
//
// Two cascades of the same layout, each a square of the map centred near the camera (snapped to whole texels so the
// shadows never crawl): cascade 0 (1024 x 1024 over 102 km, 100 m texels) from the full cloud shapes, cascade 1
// (256 x 256 over 410 km, 1.6 km) from the far-field density, for the land seen from high up.
//
// Each texel is a straight line of sunlight, fixed by where it crosses the bottom of the cloud slab (`slab bottom`,
// the lowest any cloud can be). Marched up through the slab, it stores:
//   x  the optical depth along the line, through all of the slab
//   y  the true height where the line enters cloud, z where it leaves (the cloud between is taken as even)
// A point lit by the sun finds its line (follow the sun direction to the slab bottom), and the share of the optical
// depth above it gives its sunlight: exp(-depth) for the direct beam, plus what the cloud scatters on forward.
// Cascade 0 is rebuilt continuously into a second copy, 64 rows a frame, and swapped in when complete; cascade 1
// updates a quarter of its rows each frame (all of them when it re-centres). Either way it costs very little.
//
// The same pass also marches the sunlight to the camera itself, exactly (full shape noise), and writes it to a small
// buffer the CPU reads back: the jets and everything else in the engine's own lighting take their sunlight from it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform sampler2D ground_ref;
layout(set = 0, binding = 2) uniform sampler2D weather_tex;
layout(set = 0, binding = 3) uniform sampler3D shape_tex;
layout(set = 0, binding = 4) uniform sampler3D detail_tex;

#include "include/clouds_params.glslinc"
#include "include/clouds_common.glslinc"

layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D out_shadow;
layout(set = 0, binding = 7, std430) restrict buffer CamLight {
	vec4 cam_light;        // x optical depth from the camera towards the sun
} cl;
layout(push_constant, std430) uniform PC {
	vec4 a;                // x cascade (0 / 1), y first row, z row step, w 1: also the camera's sunlight
	vec4 b;                // the copy being built: x z its centre (map), its half size, its texels across
} pc;

void main() {
	vec3 L = normalize(p.sun_dir.xyz);
	float ly = max(L.y, 0.06);
	if (gl_GlobalInvocationID.x == 0u && gl_GlobalInvocationID.y == 0u && pc.a.w > 0.5) {
		// the sunlight at the camera, through the full cloud shapes
		vec3 mp = vec3(p.cam_pos.x + p.origin.x, p.cam_pos.y, p.cam_pos.z + p.origin.y);
		float top = p.lights_n.y;
		float od = 0.0;
		if (mp.y < top && L.y > -0.05) {
			float len = min((top - mp.y) / ly, 60000.0);
			float ds = len / 48.0;
			for (int i = 0; i < 48; i++) {
				float hh;
				od += density(mp + L * (ds * (float(i) + 0.5)), 1.0, 0.0, hh) * EXT * ds;
			}
		}
		cl.cam_light = vec4(od, 0.0, 0.0, 0.0);
	}
	bool c1 = pc.a.x > 0.5;
	vec4 cas = pc.b;       // (cascade 0 is built into a second copy, centred apart from the one in use)
	int res = int(cas.w);
	int step_rows = int(pc.a.z);
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	id.y = id.y * step_rows + int(pc.a.y);
	if (id.x >= res || id.y >= res) {
		return;
	}
	vec2 q = cas.xy + ((vec2(id) + 0.5) / float(res) - 0.5) * 2.0 * cas.z;
	float y0 = p.cirrus.w;
	float y1 = p.lights_n.y;
	vec3 start = vec3(q.x, y0, q.y);
	float len = min((y1 - y0) / ly, 80000.0);
	int n = c1 ? 16 : 28;
	float ds = len / float(n);
	float od = 0.0;
	float front = y1;
	float back = y0;
	for (int i = 0; i < n; i++) {
		vec3 mp = start + L * (ds * (float(i) + 0.5));
		float hh;
		float d = c1 ? density_far(mp, hh) : density(mp, 2.0, 0.0, hh);
		if (d > 0.0) {
			od += d * EXT * ds;
			front = min(front, mp.y - L.y * ds * 0.5);
			back = max(back, mp.y + L.y * ds * 0.5);
		}
	}
	if (od <= 0.0) {
		front = y1;
		back = y1;
	}
	imageStore(out_shadow, id, vec4(od, front, back, 1.0));
}
