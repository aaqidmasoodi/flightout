// Cast shadows of the mountains (large maps): a coarse heightmap of the whole map (256 m samples,
// scripts/world/terrain_streamer.gd loads it) is marched towards the sun from every vertex. Shadow maps cannot
// reach this far (a ridge 20 km away shading a valley at sunrise); this is the shading that gives the ground its
// depth and scale from altitude. Set by the sky system: sun_dir (towards the sun).
global uniform sampler2D terrain_overview;
global uniform vec4 overview_rect;     // x0, z0 (map metres), 1 / width, 1 / depth (of the image, in metres)
global uniform float terrain_shadow;   // 1 when the overview is loaded
global uniform vec3 sun_dir;
// the same shadows worked out for the whole map whenever the sun moves (scripts/world/terrain_shadow_bake.gd):
// one lookup instead of a march per vertex, once it is ready
global uniform sampler2D terrain_shadow_map;
global uniform float terrain_shadow_baked;

float baked_shadow(vec2 mp) {
	return textureLod(terrain_shadow_map, (mp - overview_rect.xy) * overview_rect.zw, 0.0).r;
}

float ov_h(vec2 mp) {
	vec2 uv = (mp - overview_rect.xy) * overview_rect.zw;
	// the tiles' height encoding (tools/build_kashmir.py)
	return textureLod(terrain_overview, uv, 0.0).r * (65535.0 * 0.25) - 500.0;
}

// Soft shadow from the coarse heightmap: march towards the sun in growing steps (200 m to about 25 km) and keep the
// lowest clearance of the ray over the ground, measured as an angle (about two degrees of penumbra: the sun's own
// half degree plus the blur of 256 m data).
float macro_shadow_steps(vec3 mp, int steps, float grow) {
	if (terrain_shadow < 0.5) {
		return 1.0;
	}
	float hor = length(sun_dir.xz);
	if (sun_dir.y <= -0.02 || hor < 1e-3) {
		return sun_dir.y > 0.0 ? 1.0 : 0.0;
	}
	vec2 d = sun_dir.xz / hor;
	float tan_e = sun_dir.y / hor;
	float h0 = max(mp.y, ov_h(mp.xz)) + 25.0;
	float s = 1.0;
	float t = 200.0;
	for (int i = 0; i < steps; i++) {
		float ray = h0 + t * tan_e;
		s = min(s, (ray - ov_h(mp.xz + d * t)) / (t * 0.035));
		t *= grow;
	}
	return clamp(0.5 + 0.5 * s, 0.0, 1.0);
}


float macro_shadow(vec3 mp) {
	if (terrain_shadow_baked > 0.5 && terrain_shadow > 0.5) {
		return baked_shadow(mp.xz);
	}
	return macro_shadow_steps(mp, 18, 1.33);
}

// cheaper (trees: evaluated for every vertex of every tree)
float macro_shadow_lite(vec3 mp) {
	if (terrain_shadow_baked > 0.5 && terrain_shadow > 0.5) {
		return baked_shadow(mp.xz);
	}
	return macro_shadow_steps(mp, 9, 1.7);
}
