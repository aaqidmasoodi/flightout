shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;
// Ocean: three scrolling, mipmapped normal-map layers (swell, waves, chop). Texture filtering keeps it smooth
// at any distance; fine detail fades out far away and distant water gets slightly rougher (no glitter, no grain).

uniform vec3 deep_color : source_color = vec3(0.015, 0.08, 0.15);
uniform vec3 shallow_color : source_color = vec3(0.09, 0.38, 0.42);
uniform float shallow_depth = 14.0;
uniform vec2 scroll = vec2(0.0);   // world-space offset (menu backdrop fakes forward flight with it)
uniform sampler2D normal_large : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_small : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform vec3 haze_color : source_color = vec3(0.6, 0.7, 0.8);
uniform float haze_density = 0.0;     // set by the sky system; 0 = use only the scene fog
uniform vec3 hor_toward : source_color = vec3(0.0);   // sky at the horizon towards the sun (0 = use haze_color)
uniform vec3 hor_away : source_color = vec3(0.0);
uniform vec2 sun_xz = vec2(0.0);

// mean haze density between two heights (haze lives low): seen from high up the sea stays visible further
float haze_mean(float y0, float y1) {
	const float H = 2500.0;
	y0 = max(y0, 0.0);
	y1 = max(y1, 0.0);
	float a = exp(-y0 / H);
	float b = exp(-y1 / H);
	float dy = y0 - y1;
	return abs(dy) < 1.0 ? a : H * (b - a) / dy;
}

varying vec3 wpos;

vec2 nm(sampler2D tex, vec2 uv) {
	return texture(tex, uv).xy * 2.0 - 1.0;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz + scroll;
	float t = TIME;
	float dist = length(CAMERA_POSITION_WORLD - wpos);
	float near_detail = 1.0 - smoothstep(600.0, 7000.0, dist);
	vec2 swell = nm(normal_large, p / 1400.0 + vec2(t * 0.0021, t * 0.0013));
	vec2 waves = nm(normal_large, p / 260.0 - vec2(t * 0.0075, -t * 0.0050));
	vec2 chop = nm(normal_small, p / 48.0 + vec2(t * 0.021, t * 0.016));
	vec2 slope = swell * 0.55 + waves * 0.45 + chop * 0.35 * near_detail;
	slope *= mix(1.0, 0.45, smoothstep(2000.0, 20000.0, dist));
	vec3 n_world = normalize(vec3(slope.x, 1.0, slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float thickness = clamp((-view.z - (-VERTEX.z)) / shallow_depth, 0.0, 1.0);

	ALBEDO = mix(shallow_color, deep_color, thickness);
	ALPHA = mix(0.6, 0.97, thickness);
	ROUGHNESS = mix(0.07, 0.24, smoothstep(300.0, 9000.0, dist));
	SPECULAR = 0.5;
	// distant water converges to the horizon haze, like the land does
	if (haze_density > 0.0) {
		float haze = 1.0 - exp(-haze_density * dist * haze_mean(CAMERA_POSITION_WORLD.y, wpos.y));
		// fade into the sky's own horizon colour for this direction, so sea and sky meet without a seam
		vec3 hc = haze_color;
		if (dot(sun_xz, sun_xz) > 0.25) {
			vec2 dh = normalize(wpos.xz - CAMERA_POSITION_WORLD.xz + vec2(1e-5));
			float toward = pow(clamp(dot(dh, sun_xz) * 0.5 + 0.5, 0.0, 1.0), 3.0);
			hc = mix(hor_away, hor_toward, toward);
		}
		FOG = vec4(hc, clamp(haze, 0.0, 0.985) * 0.8);
		// the farthest water fades out, so the sea meets the sky's own horizon with no seam (seen from high up)
		ALPHA *= 1.0 - smoothstep(0.6, 0.985, haze);
	}
}
