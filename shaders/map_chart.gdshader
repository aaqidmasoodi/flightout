shader_type canvas_item;
// The map screen's chart (scripts/ui/map_view.gd): the shaded relief, as it is, over the whole map. Drawn over a
// larger rectangle than the chart itself (`pad` on every side): beyond the chart's edge the relief carries on as its
// own mirror image, more and more blurred, and fades into the background over a long, soft ramp, so the chart has
// no hard square edge.

uniform float pad = 0.35;             // the extra on each side, as a share of the chart's own width / height
uniform float aspect = 1.0;           // the chart's height / width
uniform vec4 bg : source_color = vec4(0.07, 0.08, 0.09, 1.0);

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
	// how far beyond the chart's edge, in widths of the chart (0 inside)
	vec2 o = max(max(-uv, uv - 1.0), vec2(0.0));
	float out_d = length(vec2(o.x, o.y * aspect));
	// mirrored back into the chart
	vec2 m = 1.0 - abs(1.0 - abs(uv));
	m = clamp(m, vec2(0.0), vec2(1.0));
	// blurred from a ring of samples at a moderate level (the coarsest levels alone showed their texels as blocks)
	float lod = 4.5 * smoothstep(0.0, 0.12, out_d);
	vec2 r = exp2(lod) * 1.5 / vec2(textureSize(TEXTURE, 0));
	vec3 c = textureLod(TEXTURE, m, lod).rgb * 0.2;
	for (int k = 0; k < 8; k++) {
		float a = float(k) * 0.785398 + 0.3;
		c += textureLod(TEXTURE, clamp(m + vec2(cos(a), sin(a)) * r, vec2(0.0), vec2(1.0)), lod).rgb * 0.1;
	}
	vec3 sharp = texture(TEXTURE, m).rgb;
	c = mix(sharp, c, smoothstep(0.0, 0.02, out_d));
	// a long, soft fade into the background, starting a little inside the chart, along an irregular line (the
	// distance to a rectangle's edge alone left a rounded square)
	vec2 inn = min(uv, 1.0 - uv);
	float d = out_d > 0.0 ? out_d : -min(inn.x, inn.y * aspect);
	float n = vnoise(uv * vec2(3.0, 3.0 * aspect) + 7.3) * 0.65 + vnoise(uv * vec2(7.0, 7.0 * aspect) + 1.7) * 0.35;
	d += (n - 0.5) * 0.14;
	float keep = 1.0 - smoothstep(-0.05, 0.26, d);
	keep = keep * keep * (3.0 - 2.0 * keep);
	COLOR = vec4(mix(bg.rgb, c, keep), 1.0);
}
