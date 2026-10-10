// The clouds' shadows, for surfaces the sun lights (shaders/clouds_shadow.glsl makes the map; scripts/world/
// volumetric_clouds.gd publishes it). Needs `global uniform vec3 sun_dir;` declared first (it is, by
// terrain_shadow.gdshaderinc).
//
// Two kinds of surface use it:
//   * shaders with their own light() (terrain, trees): the sunlight at each point, per pixel or per tree.
//   * everything in the engine's own lighting (the jets, buildings) gets the sunlight at the camera instead: the
//     sky system scales the sun by it (cloud_sun_cam). The shaders here divide that back out, so each point gets
//     its own: cloud_sun_ratio().
global uniform sampler2D cloud_shadow0 : filter_linear;
global uniform sampler2D cloud_shadow1 : filter_linear;
global uniform sampler2D cloud_shadow_info : filter_nearest;
global uniform float cloud_sun_cam;        // the sunlight the engine's sun already carries (0..1)

float _cloud_cascade(sampler2D s, vec4 inf, vec2 q, float y, out float w) {
	vec2 uv = (q - inf.xy) / (2.0 * inf.z) + 0.5;
	vec2 e = abs(uv - 0.5) * 2.0;
	w = 1.0 - smoothstep(0.85, 0.98, max(e.x, e.y));
	if (w <= 0.0) {
		return 0.0;
	}
	vec4 v = textureLod(s, uv, 0.0);
	return v.x * (1.0 - clamp((y - v.y) / max(v.z - v.y, 1.0), 0.0, 1.0));
}

// Optical depth of cloud between a point and the sun. mp: map x, true height, map z.
float cloud_od(vec3 mp) {
	vec4 i2 = texelFetch(cloud_shadow_info, ivec2(2, 0), 0);
	if (i2.y < 0.5 || sun_dir.y <= -0.05) {
		return 0.0;
	}
	float ly = max(sun_dir.y, 0.06);
	vec2 q = mp.xz + sun_dir.xz * (i2.x - mp.y) / ly;
	float w0;
	float w1;
	float od0 = _cloud_cascade(cloud_shadow0, texelFetch(cloud_shadow_info, ivec2(0, 0), 0), q, mp.y, w0);
	float od1 = _cloud_cascade(cloud_shadow1, texelFetch(cloud_shadow_info, ivec2(1, 0), 0), q, mp.y, w1);
	return mix(od1 * w1, od0, w0);
}

// The sunlight getting through that much cloud: the direct beam, plus a little the cloud scatters on forward (a
// thin cloud's shadow is not black; under a thick deck nothing of the sun is left but the sky's own light).
// The same in scripts/world/sky_system.gd (cloud_transmit).
float cloud_transmit(float od) {
	return exp(-od) * 0.8 + exp(-od * 0.03) * 0.2;
}

// This point's sunlight, relative to what the engine's sun already carries (see above).
float cloud_sun_ratio(vec3 mp) {
	return cloud_transmit(cloud_od(mp)) / max(cloud_sun_cam, 0.02);
}
