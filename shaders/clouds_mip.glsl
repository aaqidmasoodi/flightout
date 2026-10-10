#[compute]
#version 450
// One mip level of a cloud noise volume from the level above it (the average of 2 x 2 x 2 texels).

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D src;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image3D dst;
layout(push_constant, std430) uniform PC {
	vec4 a;            // x destination size
} pc;

void main() {
	int n = int(pc.a.x);
	ivec3 id = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(id, ivec3(n)))) {
		return;
	}
	vec4 s = vec4(0.0);
	for (int k = 0; k < 8; k++) {
		s += imageLoad(src, id * 2 + ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1));
	}
	imageStore(dst, id, s * 0.125);
}
