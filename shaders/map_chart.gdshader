shader_type canvas_item;
// The map screen's chart (scripts/ui/map_view.gd): the shaded relief, as it is, over the whole map. Drawn over a
// larger rectangle than the chart itself (`pad` on every side): beyond the chart's edge the relief carries on as its
// own mirror image, more and more blurred, and fades into the background over a long, soft ramp, so the chart has
// no hard square edge.

uniform float pad = 0.35;             // the extra on each side, as a share of the chart's own width / height
uniform float aspect = 1.0;           // the chart's height / width
uniform vec4 bg : source_color = vec4(0.07, 0.08, 0.09, 1.0);
uniform int dbg = 0;                  // development (--map-debug=N): 1 the fade, 2 the soft copy only, 3 the sharp chart only
uniform sampler2D soft_tex : filter_linear, repeat_disable;   // the chart at 1/16 (scripts/ui/map_view.gd)

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 uv = UV * (1.0 + 2.0 * pad) - pad;
	// signed distance to the chart's edge, in widths of the chart (negative inside), along an irregular line (the
	// distance to a rectangle's edge alone left a rounded square)
	vec2 o = max(max(-uv, uv - 1.0), vec2(0.0));
	vec2 inn = min(uv, 1.0 - uv);
	float d = length(vec2(o.x, o.y * aspect)) > 0.0 ? length(vec2(o.x, o.y * aspect)) : -min(inn.x, inn.y * aspect);
	float n = vnoise(uv * vec2(3.0, 3.0 * aspect) + 7.3) * 0.65 + vnoise(uv * vec2(7.0, 7.0 * aspect) + 1.7) * 0.35;
	d += (n - 0.5) * 0.14;
	// mirrored back into the chart
	vec2 m = clamp(1.0 - abs(1.0 - abs(uv)), vec2(0.0), vec2(1.0));
	// blurred: a ring of samples from a small copy of the chart (its own coarse mip levels showed blocks), from a
	// little inside the edge: the chart's outermost strip lies partly outside the terrain data
	vec2 r = 1.6 / vec2(textureSize(soft_tex, 0));
	vec3 c = texture(soft_tex, m).rgb * 0.2;
	for (int k = 0; k < 8; k++) {
		float a = float(k) * 0.785398 + 0.3;
		c += texture(soft_tex, clamp(m + vec2(cos(a), sin(a)) * r, vec2(0.0), vec2(1.0))).rgb * 0.1;
	}
	c = mix(texture(TEXTURE, m).rgb, c, smoothstep(-0.11, -0.05, d));
	// a long, soft fade into the background
	float keep = 1.0 - smoothstep(-0.14, 0.2, d);
	keep = keep * keep * (3.0 - 2.0 * keep);
	COLOR = vec4(mix(bg.rgb, c, keep), 1.0);
	if (dbg == 1) {
		COLOR = vec4(vec3(keep), 1.0);
	} else if (dbg == 2) {
		COLOR = vec4(texture(soft_tex, m).rgb, 1.0);
	} else if (dbg == 3) {
		COLOR = vec4(texture(TEXTURE, m).rgb, 1.0);
	}
}
