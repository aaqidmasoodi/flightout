#[compute]
#version 450
// One mip level of the far-cloud map (clouds_far.glsl) from the level above: optical depth averaged, the cloud's
// lowest start and highest end kept (so a thin cloud is not lost in the average height of its clear neighbours).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform PC {
	vec4 a;            // x destination size
} pc;

void main() {
	int n = int(pc.a.x);
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(id, ivec2(n)))) {
		return;
	}
	float od = 0.0;
	float lo = 1e9;
	float hi = -1e9;
	float lo_all = 0.0;
	float hi_all = 0.0;
	int k = 0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			vec4 s = imageLoad(src, id * 2 + ivec2(i, j));
			od += s.x;
			lo_all += s.y;
			hi_all += s.z;
			if (s.x > 0.0) {
				lo = min(lo, s.y);
				hi = max(hi, s.z);
				k++;
			}
		}
	}
	vec4 o = vec4(od * 0.25, lo_all * 0.25, hi_all * 0.25, 1.0);
	if (k > 0) {
		o.y = lo;
		o.z = hi;
	}
	imageStore(dst, id, o);
}
