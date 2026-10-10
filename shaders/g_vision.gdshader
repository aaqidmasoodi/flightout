shader_type canvas_item;
// G effects on the pilot's vision (scripts/aircraft/pilot_g.gd): under positive G the colour drains out first
// (grey-out), then the edges darken and close in (tunnel vision), then everything goes black. Under negative G
// the view reddens (red-out). Only drawn while any of it is showing.

uniform sampler2D screen : hint_screen_texture, filter_linear;
uniform float grey = 0.0;        // 0..1 colour lost
uniform float tunnel = 0.0;      // 0..1 how far the dark edges have closed in
uniform float black = 0.0;       // 0..1 blacked out
uniform float red = 0.0;         // 0..1 red-out
uniform float aspect = 1.777;

void fragment() {
	vec3 c = texture(screen, SCREEN_UV).rgb;
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(l) * 0.92, grey);
	c *= 1.0 - 0.35 * grey;
	vec2 d = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
	float r = length(d);
	float radius = mix(1.25, 0.1, tunnel);
	float v = 1.0 - smoothstep(radius * 0.45, radius, r);
	c *= mix(1.0, v, smoothstep(0.0, 0.15, tunnel));
	c = mix(c, vec3(0.0), black);
	vec3 rc = vec3(l * 0.9 + 0.12, l * 0.08, l * 0.06);
	c = mix(c, rc, red * 0.85);
	c *= 1.0 - 0.6 * red * smoothstep(0.3, 1.0, r);
	COLOR = vec4(c, 1.0);
}
