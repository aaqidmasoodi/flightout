#[compute]
#version 450
// The far-cloud map (scripts/world/volumetric_clouds.gd): each column of the cloud field integrated once, top to
// bottom, into a 2D map around the camera (1024 x 1024 over 240 km). The march draws everything beyond its own range
// from it: one lookup per layer instead of a march, so far clouds are sharp, steady (no noise to average away) and
// the same clouds as up close (the same model, integrated), not a haze.
//
// The map is kept in "wind space" (the position the clouds drift past: map + wind), so it stays valid while the
// clouds move; it is rebuilt continuously anyway, a band of rows per frame into a second copy, which then takes
// over (weather changes, the camera's moves). Per texel: x the optical depth of the column, y the true height where
// its cloud starts, z where it ends.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 1) uniform sampler2D ground_ref;
layout(set = 0, binding = 2) uniform sampler2D weather_tex;
layout(set = 0, binding = 3) uniform sampler3D shape_tex;
layout(set = 0, binding = 4) uniform sampler3D detail_tex;

#include "include/clouds_params.glslinc"
#include "include/clouds_common.glslinc"

layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image2D out_far;
layout(push_constant, std430) uniform PC {
	vec4 a;            // x, y centre (wind space), z half extent, w first row
	vec4 b;            // x resolution, y rows this dispatch, z noise level of a texel's footprint
} pc;

void main() {
	int res = int(pc.b.x);
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	id.y += int(pc.a.w);
	if (id.x >= res || id.y >= res || int(gl_GlobalInvocationID.y) >= int(pc.b.y)) {
		return;
	}
	vec2 w = pc.a.xy + ((vec2(id) + 0.5) / float(res) - 0.5) * 2.0 * pc.a.z;
	vec2 m = w - p.wind.xy;              // the map position the clouds of this column are over now
	Column c = column(m);
	float od = 0.0;
	float lo = 1e9;
	float hi = -1e9;
	if (c.cov > 0.002) {
		const int N = 16;
		float dy = (c.top - c.base) / float(N);
		for (int i = 0; i < N; i++) {
			float y = c.base + dy * (float(i) + 0.5);
			float hh;
			// the noise level of a texel's footprint
			float d = density(vec3(m.x, y, m.y), pc.b.z, 0.0, hh);
			if (d > 0.0) {
				od += d * EXT * dy;
				lo = min(lo, y - dy * 0.5);
				hi = max(hi, y + dy * 0.5);
			}
		}
	}
	if (od <= 0.0) {
		lo = c.base;
		hi = c.top;
	}
	// opacities, not optical depth: averaged into the mip levels they keep the share of the sky the clouds cover
	// (averaged depth turned half-covered texels nearly opaque: a white blanket far away). x straight down, w along a
	// slant four times as long (seen at a shallow angle)
	imageStore(out_far, id, vec4(1.0 - exp(-od), lo, hi, 1.0 - exp(-4.0 * od)));
}
