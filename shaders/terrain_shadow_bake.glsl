#[compute]
#version 450
// The mountains' cast shadows for the whole map, at the coarse heightmap's own resolution (256 m): from every texel,
// march towards the sun over the heightmap and keep the lowest clearance of the ray (as an angle, about two degrees
// of penumbra). Run by scripts/world/terrain_shadow_bake.gd only when the sun has moved; the terrain and the trees
// then read the result with one texture lookup (shaders/include/terrain_shadow.gdshaderinc).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D overview;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D shadow_img;
layout(push_constant, std430) uniform Params {
	vec4 sun;      // xyz towards the sun, w unused
	vec4 rect;     // x0, z0 (map metres of the image's corner), 1 / width, 1 / depth (in metres)
	vec4 size;     // image width, height (texels), spacing (m), unused
} p;

float ov_h(vec2 mp) {
	vec2 uv = (mp - p.rect.xy) * p.rect.zw;
	return textureLod(overview, uv, 0.0).r * (65535.0 * 0.25) - 500.0;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(p.size.x) || px.y >= int(p.size.y)) {
		return;
	}
	vec2 mp = p.rect.xy + (vec2(px) + 0.5) * p.size.z;
	vec3 sd = p.sun.xyz;
	float hor = length(sd.xz);
	float result;
	if (sd.y <= -0.02 || hor < 1e-3) {
		result = sd.y > 0.0 ? 1.0 : 0.0;
	} else {
		vec2 d = sd.xz / hor;
		float tan_e = sd.y / hor;
		float h0 = ov_h(mp) + 25.0;
		float s = 1.0;
		float t = 200.0;
		for (int i = 0; i < 18; i++) {
			float ray = h0 + t * tan_e;
			s = min(s, (ray - ov_h(mp + d * t)) / (t * 0.035));
			t *= 1.33;
		}
		result = clamp(0.5 + 0.5 * s, 0.0, 1.0);
	}
	imageStore(shadow_img, px, vec4(result, 0.0, 0.0, 0.0));
}
