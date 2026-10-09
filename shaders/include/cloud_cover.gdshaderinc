// Cloud cover for transparent surfaces. The volumetric clouds are composited BEFORE the transparent pass, so
// glass, the HUD, flames and particles draw over the clouds correctly. Transparent things that can sit far
// BEHIND a cloud (the sea, other jets' afterburners) use this to hide behind it: the cloud pass writes, per
// pixel, the clouds' transmittance (r) and the distance where they start (g, in km).
global uniform sampler2D cloud_layer;

// 1 = nothing in front of this surface, 0 = fully hidden by clouds in front of it
float cloud_visibility(vec2 screen_uv, float dist_m) {
	vec4 l = textureLod(cloud_layer, screen_uv, 0.0);
	float front = l.g * 1000.0;
	return mix(1.0, clamp(l.r, 0.0, 1.0), smoothstep(front, front + 150.0, dist_m));
}
