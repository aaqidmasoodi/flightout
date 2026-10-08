shader_type sky;
// FlightOut sky: colour from the sun's elevation, sun disc and glow, moon, stars, and a weather-driven cloud layer.
// Directions are world space (north -Z, east +X, up +Y). Values are linear HDR, tonemapped by the Environment.

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);      // towards the sun
uniform vec3 moon_dir = vec3(0.0, -1.0, 0.0);
uniform float sun_elev = 45.0;                    // degrees
uniform float cloud_coverage = 0.3;               // 0 clear .. 1 overcast deck
uniform float overcast = 0.0;                     // 0..1 greys the whole sky
uniform float haze = 0.0;                         // 0..1 fog / rain whiteout near the horizon
uniform vec2 cloud_drift = vec2(0.0);
uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable;

float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

vec3 base_sky(vec3 d, vec3 s, float e) {
	float day = smoothstep(-8.0, 12.0, e);
	float golden = (1.0 - smoothstep(3.0, 20.0, e)) * smoothstep(-12.0, -1.0, e);
	vec3 zen = mix(vec3(0.0025, 0.0045, 0.012), vec3(0.11, 0.27, 0.62), day);
	vec3 hor = mix(vec3(0.012, 0.02, 0.04), vec3(0.58, 0.71, 0.86), day);
	vec2 dh = normalize(d.xz + vec2(1e-5));
	vec2 sh = normalize(s.xz + vec2(1e-5));
	float toward = pow(dot(dh, sh) * 0.5 + 0.5, 3.0);
	hor = mix(hor, vec3(1.0, 0.4, 0.13), golden * toward);
	hor = mix(hor, vec3(0.3, 0.22, 0.38), golden * (1.0 - toward) * 0.65);
	zen = mix(zen, vec3(0.05, 0.08, 0.22), golden * 0.7);
	float up = clamp(d.y, 0.0, 1.0);
	vec3 c = mix(zen, hor, pow(1.0 - up, 4.0));
	if (d.y < 0.0) {
		c = mix(hor, hor * 0.3, smoothstep(0.0, -0.35, d.y));
	}
	// atmospheric glow around the sun (Mie), stronger and warmer near the horizon
	float mu = max(dot(d, s), 0.0);
	float sun_up = smoothstep(-7.0, 1.0, e);
	c += vec3(1.0, 0.78, 0.55) * pow(mu, 10.0) * 0.32 * sun_up * (1.0 + 1.5 * golden);
	c += vec3(1.0, 0.82, 0.62) * pow(mu, 120.0) * 0.9 * sun_up;
	return c;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 s = normalize(sun_dir);
	float e = sun_elev;
	float day = smoothstep(-8.0, 12.0, e);
	float golden = (1.0 - smoothstep(3.0, 20.0, e)) * smoothstep(-12.0, -1.0, e);
	vec3 c = base_sky(d, s, e);

	// overcast greys the sky (lighter by day, near black at night)
	vec3 grey = mix(vec3(0.012, 0.014, 0.02), vec3(0.33, 0.35, 0.39), day);
	grey = mix(grey, grey * vec3(1.15, 0.85, 0.7), golden * 0.6);
	c = mix(c, grey, overcast);

	float mu = dot(d, s);
	if (!AT_CUBEMAP_PASS) {
		// stars and moon, only at night and above the horizon
		float night = 1.0 - smoothstep(-14.0, -3.0, e);
		if (night > 0.0 && d.y > 0.0) {
			vec3 p = d * 260.0;
			vec3 cell = floor(p);
			float h = hash3(cell);
			if (h > 0.986) {
				vec3 centre = vec3(hash3(cell + 1.7), hash3(cell + 3.1), hash3(cell + 5.3)) * 0.6 + 0.2;
				float b = smoothstep(0.22, 0.0, length(fract(p) - centre));
				float tw = 0.7 + 0.3 * sin(TIME * (2.0 + h * 5.0) + h * 80.0);
				c += vec3(0.9, 0.93, 1.0) * b * tw * (h - 0.986) * 140.0 * night * (1.0 - overcast) * smoothstep(0.0, 0.15, d.y);
			}
		}
		vec3 m = normalize(moon_dir);
		float mm = dot(d, m);
		if (m.y > -0.05) {
			float disc = smoothstep(0.99986, 0.99990, mm);
			c += vec3(0.85, 0.88, 0.95) * disc * 2.2 * (1.0 - 0.85 * overcast) * (0.25 + 0.75 * night);
			c += vec3(0.5, 0.6, 0.8) * pow(max(mm, 0.0), 400.0) * 0.12 * night * (1.0 - overcast);
		}
		// sun disc
		float disc = smoothstep(0.99994, 0.99997, mu);
		c += vec3(1.0, 0.9, 0.75) * disc * 40.0 * smoothstep(-1.0, 1.0, e) * (1.0 - smoothstep(0.55, 0.95, cloud_coverage)) * (1.0 - overcast);
	}

	// cloud layer projected onto a dome
	if (d.y > 0.0 && cloud_coverage > 0.01) {
		vec2 uv = d.xz / (d.y + 0.12) * 0.32 + cloud_drift;
		float n = texture(cloud_tex, uv * 0.55).r * 0.62 + texture(cloud_tex, uv * 1.9 + vec2(0.37, 0.71)).r * 0.38;
		float edge = 1.0 - cloud_coverage;
		float dens = smoothstep(edge - 0.08, edge + 0.22, n) * smoothstep(0.0, 0.14, d.y);
		vec3 sun_col = mix(vec3(1.0, 0.55, 0.32), vec3(1.0, 0.98, 0.95), smoothstep(2.0, 25.0, e));
		vec3 lit = mix(vec3(0.03, 0.035, 0.05), vec3(0.95, 0.96, 0.98), day) * mix(vec3(1.0), sun_col, 0.6);
		vec3 shade = mix(vec3(0.015, 0.018, 0.026), vec3(0.42, 0.45, 0.52), day);
		shade = mix(shade, shade * vec3(1.2, 0.8, 0.75), golden);
		float thick = smoothstep(0.55, 1.0, n);
		vec3 cc = mix(lit, shade, thick * (0.4 + 0.6 * overcast));
		cc += vec3(1.0, 0.8, 0.55) * pow(max(mu, 0.0), 6.0) * (1.0 - thick) * 0.8 * smoothstep(-4.0, 6.0, e);   // silver lining
		c = mix(c, cc, dens * 0.95);
	}
	// haze: fog and rain wash out the lower sky
	c = mix(c, grey * 1.05, haze * (1.0 - smoothstep(0.0, 0.5, d.y)));
	COLOR = c;
}
