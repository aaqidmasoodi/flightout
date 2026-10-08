shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Terrain: grass, meadow, forest floor, rock, snow, sand and seabed. Large-scale colour variation and close-up
// detail come from mipmapped noise textures (smooth at any distance). Forest floor follows the same density map
// that places the trees, so ground and forests always agree.

uniform sampler2D forest_density : filter_linear, repeat_disable;
uniform sampler2D macro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float map_half_extent = 20480.0;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float h = wpos.y;
	vec3 n = normalize(wnorm);
	float slope = 1.0 - clamp(n.y, 0.0, 1.0);
	vec2 p = wpos.xz;
	float dist = length(CAMERA_POSITION_WORLD - wpos);
	float macro = texture(macro_tex, p / 14000.0).r;
	float macro2 = texture(macro_tex, p / 3100.0 + 0.5).r;
	float det = texture(detail_tex, p / 60.0).r;
	float det2 = texture(detail_tex, p / 9.0 + 0.3).r;
	// triplanar detail for steep rock
	vec3 bw = pow(abs(n), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z);
	float rock_det = texture(detail_tex, wpos.zy / 35.0).r * bw.x + texture(detail_tex, wpos.xz / 35.0).r * bw.y + texture(detail_tex, wpos.xy / 35.0).r * bw.z;

	vec2 muv = (p + vec2(map_half_extent)) / (2.0 * map_half_extent);
	float forest = texture(forest_density, muv).r;

	// grass: lush in the lowlands, drier and browner with height and in dry patches
	vec3 lush = vec3(0.075, 0.15, 0.04);
	vec3 meadow = vec3(0.14, 0.2, 0.065);
	vec3 dry = vec3(0.24, 0.23, 0.12);
	vec3 alpine = vec3(0.22, 0.2, 0.13);
	vec3 grass = mix(lush, meadow, smoothstep(0.35, 0.7, macro2));
	grass = mix(grass, dry, smoothstep(0.55, 0.8, macro) * 0.7);
	grass = mix(grass, alpine, smoothstep(650.0, 1050.0, h + (macro - 0.5) * 200.0));
	grass *= 0.85 + 0.3 * det;
	vec3 floor_c = mix(vec3(0.035, 0.06, 0.025), vec3(0.055, 0.085, 0.035), det);
	// canopy seen from afar: clumps of crowns (lit tops, dark gaps), taking over from individual trees with distance
	float crowns = texture(detail_tex, p / 26.0 + 0.17).r * 0.65 + texture(detail_tex, p / 9.0 + 0.61).r * 0.35;
	float clump = smoothstep(0.35, 0.75, crowns);
	vec3 canopy = mix(vec3(0.03, 0.055, 0.025), vec3(0.075, 0.125, 0.05), clump);
	canopy = mix(canopy, canopy * vec3(1.15, 1.05, 0.8), smoothstep(450.0, 900.0, h) * 0.6);   // drier conifers higher up
	float far_canopy = smoothstep(700.0, 2600.0, dist);
	floor_c = mix(floor_c, canopy, far_canopy);
	float forest_amt = smoothstep(0.2, 0.6, forest);
	// sparse groves and lone trees also darken the ground slightly once individual trees are culled
	forest_amt = max(forest_amt, smoothstep(0.02, 0.2, forest) * 0.35 * far_canopy);
	vec3 c = mix(grass, floor_c, forest_amt);

	vec3 rock = mix(vec3(0.21, 0.2, 0.19), vec3(0.34, 0.32, 0.3), rock_det);
	rock = mix(rock, rock * vec3(1.05, 0.95, 0.85), macro2 * 0.5);
	float rock_amt = clamp(smoothstep(0.24, 0.42, slope + (rock_det - 0.5) * 0.08) + smoothstep(1050.0, 1350.0, h + (macro2 - 0.5) * 180.0), 0.0, 1.0);
	c = mix(c, rock, rock_amt);
	float snow_line = 1420.0 + (macro2 - 0.5) * 240.0;
	float snow_amt = smoothstep(snow_line, snow_line + 110.0, h) * (1.0 - smoothstep(0.45, 0.72, slope));
	c = mix(c, vec3(0.86, 0.88, 0.92) * (0.94 + 0.06 * det), snow_amt);
	vec3 sand = mix(vec3(0.48, 0.43, 0.31), vec3(0.56, 0.51, 0.38), det);
	c = mix(sand, c, smoothstep(2.0, 9.0, h + (macro2 - 0.5) * 6.0));
	c = mix(vec3(0.34, 0.32, 0.24), c, smoothstep(-8.0, 0.5, h));
	// fine grain close up only (fades long before it could alias)
	c *= mix(0.9 + 0.2 * det2, 1.0, smoothstep(150.0, 900.0, dist));

	// close-up surface relief from the detail normal map
	vec2 dn = texture(detail_nrm, p / 22.0).xy * 2.0 - 1.0;
	float relief = (1.0 - smoothstep(60.0, 700.0, dist)) * (0.35 + 0.65 * rock_amt) * (1.0 - snow_amt * 0.6);
	vec3 nw = normalize(n + vec3(dn.x, 0.0, dn.y) * relief * 0.6);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	ALBEDO = c;
	ROUGHNESS = mix(0.95, 0.5, snow_amt);
	SPECULAR = mix(0.25, 0.45, snow_amt);
}
