shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
// Stratus deck for overcast and rain: a thick-looking layer seen from above or below, which thins out
// when the camera passes through it.

uniform sampler2D noise_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 top_color : source_color = vec3(0.9);
uniform vec3 bottom_color : source_color = vec3(0.45);
uniform float amount = 0.0;
uniform vec2 drift = vec2(0.0);
uniform float deck_alt = 1900.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz + drift;
	float n = texture(noise_tex, p / 9000.0).r * 0.65 + texture(noise_tex, p / 2100.0 + 0.3).r * 0.35;
	float above = step(deck_alt, CAMERA_POSITION_WORLD.y);
	float dist = length(CAMERA_POSITION_WORLD - wpos);
	float near = smoothstep(80.0, 600.0, abs(CAMERA_POSITION_WORLD.y - deck_alt) + dist * 0.02);
	vec3 c = mix(bottom_color, top_color, above);
	c *= 0.85 + 0.3 * n;
	ALBEDO = c;
	ALPHA = clamp(amount * (0.9 + 0.35 * n), 0.0, 1.0) * near * (1.0 - smoothstep(30000.0, 55000.0, dist));
}
