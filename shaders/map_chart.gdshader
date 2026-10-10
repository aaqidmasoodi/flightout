shader_type canvas_item;
// The map screen's chart (scripts/ui/map_view.gd): the shaded relief, as it is, over the whole map. Drawn over a
// larger rectangle than the chart itself (`pad` on every side): beyond the chart's edge the relief carries on as its
// own mirror image, more and more blurred, and fades into the background over a long, soft ramp, so the chart has
// no hard square edge.

uniform float pad = 0.35;             // the extra on each side, as a share of the chart's own width / height
uniform float aspect = 1.0;           // the chart's height / width
uniform vec4 bg : source_color = vec4(0.07, 0.08, 0.09, 1.0);

void fragment() {
	vec2 uv = UV * (1.0 + 2.0 * pad) - pad;
	// how far beyond the chart's edge, in widths of the chart (0 inside)
	vec2 o = max(max(-uv, uv - 1.0), vec2(0.0));
	float out_d = length(vec2(o.x, o.y * aspect));
	// mirrored back into the chart
	vec2 m = 1.0 - abs(1.0 - abs(uv));
	m = clamp(m, vec2(0.0), vec2(1.0));
	float lod = 7.0 * smoothstep(0.0, 0.12, out_d);
	vec3 c = textureLod(TEXTURE, m, lod).rgb;
	vec3 sharp = texture(TEXTURE, m).rgb;
	c = mix(sharp, c, smoothstep(0.0, 0.02, out_d));
	// a long, soft fade into the background
	float keep = 1.0 - smoothstep(0.0, 0.3, out_d);
	keep = keep * keep * (3.0 - 2.0 * keep);
	COLOR = vec4(mix(bg.rgb, c, keep), 1.0);
}
