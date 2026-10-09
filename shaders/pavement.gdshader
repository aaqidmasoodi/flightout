shader_type spatial;
// Airfield pavement: world-space, no UVs needed. Three octaves of noise for wear and staining,
// and analytically anti-aliased slab joints (concrete) that fade out before they could shimmer.
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.55);
uniform float variation = 0.16;
uniform float joint_spacing = 0.0;      // metres between slab joints, 0 = none (asphalt)
uniform float joint_width = 0.03;       // half width of a joint, metres
uniform float roughness_base = 0.88;
uniform sampler2D noise_tex : filter_linear_mipmap_anisotropic, repeat_enable;

global uniform vec2 world_origin;     // floating origin (scripts/world/world_data.gd)

varying vec3 wp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float joint(float d, float w) {
	// coverage of a 2*joint_width line by this pixel, then dimmed once the line is thinner than a pixel
	float c = clamp((joint_width - d) / max(w, 1e-4) + 0.5, 0.0, 1.0);
	return c * clamp(2.0 * joint_width / max(w, 1e-4), 0.0, 1.0);
}

void fragment() {
	vec2 p = wp.xz + world_origin;
	float n1 = texture(noise_tex, p * 0.011).r;
	float n2 = texture(noise_tex, p * 0.093 + 0.37).r;
	float n3 = texture(noise_tex, p * 0.71 + 0.71).r;
	float v = (n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.35 + (n3 - 0.5) * 0.2;
	vec3 col = base_color * (1.0 + v * variation * 2.0);
	if (joint_spacing > 0.0) {
		vec2 w = fwidth(p);
		vec2 g = abs(fract(p / joint_spacing + 0.5) - 0.5) * joint_spacing;
		float j = max(joint(g.x, w.x), joint(g.y, w.y));
		col *= 1.0 - 0.45 * j;
	}
	ALBEDO = col;
	ROUGHNESS = clamp(roughness_base + v * 0.12, 0.0, 1.0);
}
