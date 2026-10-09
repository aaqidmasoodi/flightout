shader_type spatial;
// Plain cockpit surfaces (instrument faces, labels, needles, screens, mirrors) with the precise cockpit transform.
render_mode blend_mix, cull_back, depth_draw_opaque, skip_vertex_transform, fog_disabled;
#include "res://shaders/include/cockpit_precise.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, hint_default_white;
uniform float scissor = 0.0;              // alpha scissor threshold, 0 = opaque
uniform float roughness_v : hint_range(0.0, 1.0) = 0.5;
uniform float metallic_v : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission_c : source_color = vec3(0.0);
uniform float emission_e = 0.0;
// integral (backlit) instrument lighting: the light parts of the face (markings, numerals, needles, legends)
// glow in glow_color, set by scripts/aircraft/cockpit.gd from the cabin lights switch
uniform float glow = 0.0;
uniform float cabin = 0.0;            // faint even lift of the whole surface (cockpit lights)
uniform vec3 glow_color : source_color = vec3(1.0, 0.82, 0.62);
uniform float glow_threshold = 0.45;

void vertex() {
	ck_transform(VERTEX, NORMAL, TANGENT, BINORMAL, MODELVIEW_MATRIX, MODELVIEW_NORMAL_MATRIX, INV_VIEW_MATRIX, MAIN_CAM_INV_VIEW_MATRIX);
}

void fragment() {
	vec4 c = albedo * texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = scissor > 0.0 ? c.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = scissor;
	ROUGHNESS = roughness_v;
	METALLIC = metallic_v;
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	EMISSION = emission_c * emission_e + glow_color * glow * smoothstep(glow_threshold, glow_threshold + 0.35, lum) + c.rgb * cabin;
}
