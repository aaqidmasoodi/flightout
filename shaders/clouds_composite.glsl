#[compute]
#version 450
// Upsamples the half-resolution cloud buffer and composites it over the HDR scene colour.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_img;
layout(set = 0, binding = 1) uniform sampler2D cloud_tex;

layout(push_constant, std430) uniform Push {
	vec2 size;
	vec2 pad;
} pc;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(pc.size.x) || px.y >= int(pc.size.y)) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / pc.size;
	vec4 c = textureLod(cloud_tex, uv, 0.0);
	vec4 scene = imageLoad(color_img, px);
	imageStore(color_img, px, vec4(scene.rgb * c.a + c.rgb, scene.a));
}
