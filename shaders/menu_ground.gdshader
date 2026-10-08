shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Menu backdrop ground seen through gaps in the cloud deck: land (fields, forest, dry ground) broken by coastlines
// and sea, scrolling with the jet, fading into warm sunset haze. Smooth at any distance (mipmapped textures only).

uniform sampler2D macro_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wave_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec2 scroll = vec2(0.0);
uniform vec3 haze_color : source_color = vec3(0.86, 0.64, 0.5);
uniform float haze_density = 0.00022;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz + scroll;
	float dist = length(CAMERA_POSITION_WORLD - wpos);
	// coastlines: large shapes with a ragged edge
	float shape = texture(macro_tex, p / 26000.0).r * 0.72 + texture(macro_tex, p / 7000.0 + 0.31).r * 0.28;
	float land = smoothstep(0.47, 0.5, shape);
	float shore = smoothstep(0.47, 0.485, shape) * (1.0 - smoothstep(0.485, 0.51, shape));
	// land: patchwork of fields, forest and dry ground
	float m1 = texture(macro_tex, p / 4200.0 + 0.6).r;
	float m2 = texture(detail_tex, p / 900.0).r;
	float m3 = texture(detail_tex, p / 240.0 + 0.2).r;
	vec3 forest = vec3(0.03, 0.075, 0.03);
	vec3 field = vec3(0.1, 0.19, 0.05);
	vec3 dry = vec3(0.26, 0.22, 0.12);
	vec3 lc = mix(field, forest, smoothstep(0.45, 0.6, m1));
	lc = mix(lc, dry, smoothstep(0.66, 0.8, m2) * 0.5);
	lc *= 0.85 + 0.3 * m3;
	lc = mix(lc, vec3(0.62, 0.56, 0.42), shore);            // beaches
	// sea: deeper offshore, lighter near the coast
	vec3 sea = mix(vec3(0.012, 0.06, 0.12), vec3(0.03, 0.15, 0.2), smoothstep(0.4, 0.47, shape));
	vec2 n = (texture(wave_nrm, p / 300.0 + TIME * 0.004).xy * 2.0 - 1.0) * (1.0 - land);
	vec3 nw = normalize(vec3(n.x * 0.25, 1.0, n.y * 0.25));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	ALBEDO = mix(sea, lc, land);
	ROUGHNESS = mix(0.12, 0.95, land);
	SPECULAR = mix(0.5, 0.2, land);
	// distant ground melts into the warm haze of the sky
	float haze = 1.0 - exp(-haze_density * dist);
	FOG = vec4(haze_color, clamp(haze, 0.0, 0.94));
}
