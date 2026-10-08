shader_type canvas_item;
// Frosted glass: blurred copy of what is behind the panel, darkened toward a tint.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float lod = 3.2;
uniform vec4 tint : source_color = vec4(0.03, 0.035, 0.045, 0.62);

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * 7.0;
	vec3 c = vec3(0.0);
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			c += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, lod).rgb;
		}
	}
	c /= 9.0;
	COLOR = vec4(mix(c, tint.rgb, tint.a), 1.0);
}
