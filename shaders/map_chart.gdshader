shader_type canvas_item;
// The map screen's chart (scripts/ui/map_view.gd): the shaded relief, crisp inside the playable region (Kashmir,
// data/maps/<map>/region_mask.png from tools/build_region.py) and pushed back outside it: blurred, greyed and
// darkened, so the land around is there for orientation but the eye stays on where you can fly. The chart's own
// rectangle fades into the background at its edges instead of ending in a hard square.

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform float zoom_lod = 0.0;         // log2 of chart texels per screen pixel (the level the chart is seen at)
uniform vec4 bg : source_color = vec4(0.07, 0.08, 0.09, 1.0);

void fragment() {
	float inside = texture(mask_tex, UV).r;
	vec3 sharp = texture(TEXTURE, UV).rgb;
	// outside: a few levels coarser than the chart is seen at, from a ring of samples so the blur is round
	float lod = max(zoom_lod, 0.0) + 2.5;
	vec2 tx = vec2(textureSize(TEXTURE, 0));
	vec2 r = exp2(lod) / tx;
	vec3 soft = textureLod(TEXTURE, UV, lod).rgb * 0.4;
	soft += textureLod(TEXTURE, UV + vec2(r.x, 0.0), lod).rgb * 0.15;
	soft += textureLod(TEXTURE, UV - vec2(r.x, 0.0), lod).rgb * 0.15;
	soft += textureLod(TEXTURE, UV + vec2(0.0, r.y), lod).rgb * 0.15;
	soft += textureLod(TEXTURE, UV - vec2(0.0, r.y), lod).rgb * 0.15;
	float grey = dot(soft, vec3(0.299, 0.587, 0.114));
	vec3 outside = mix(bg.rgb, mix(vec3(grey), soft, 0.35) * vec3(0.8, 0.84, 0.9), 0.5);
	vec3 c = mix(outside, sharp, inside);
	// the chart's edges: faded into the background over the outer 8 %
	vec2 e = min(UV, 1.0 - UV);
	float edge = smoothstep(0.0, 0.08, min(e.x, e.y * tx.y / tx.x));     // (the same width in x and y)
	COLOR = vec4(mix(bg.rgb, c, edge), 1.0);
}
