shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
// Procedural runway (45 m x 3000 m, ICAO-style markings). Every marking is computed analytically and box-filtered
// against the pixel's footprint, so it is razor sharp up close and fades into the asphalt only once it is thinner
// than a pixel, with no premature mip blur and no shimmer at grazing angles.
// UV: x across the width (0..1), y along the length (0 = north end, 1 = south end).

uniform sampler2D detail_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float width_m = 45.0;
uniform float length_m = 3000.0;
// designators: at the UV y = 0 end (read landing towards +y) and at the y = 1 end
uniform ivec2 start_digits = ivec2(1, 8);
uniform ivec2 end_digits = ivec2(3, 6);

// exact coverage of the interval [-h, h] by a pixel of width w centred at q (1D box filter)
float cover(float q, float h, float w) {
	return clamp(min(q + 0.5 * w, h) - max(q - 0.5 * w, -h), 0.0, w) / w;
}

// coverage of an axis-aligned rectangle (centre c, half size hs) by the pixel at p with footprint fw
float rect(vec2 p, vec2 c, vec2 hs, vec2 fw) {
	vec2 q = p - c;
	return cover(q.x, hs.x, fw.x) * cover(q.y, hs.y, fw.y);
}

// seven-segment runway digit in local metres: u across (0 at digit centre), v up (0 at the digit's base), 9 m tall
float digit(int n, vec2 l, vec2 fw) {
	// segment flags: a b c d e f g
	bool a = n != 1 && n != 4;
	bool b = n != 5 && n != 6;
	bool c = n != 2;
	bool d = n != 1 && n != 4 && n != 7;
	bool e = n == 0 || n == 2 || n == 6 || n == 8;
	bool f = n == 0 || n == 4 || n == 5 || n == 6 || n == 8 || n == 9;
	bool g = n != 0 && n != 1 && n != 7;
	if (n == 1) {
		return rect(l, vec2(0.0, 4.5), vec2(0.45, 4.5), fw);
	}
	float s = 0.0;
	float hw = 1.5;     // half width of the digit
	float st = 0.45;    // half stroke
	if (a) s = max(s, rect(l, vec2(0.0, 9.0 - st), vec2(hw, st), fw));
	if (g) s = max(s, rect(l, vec2(0.0, 4.5), vec2(hw, st), fw));
	if (d) s = max(s, rect(l, vec2(0.0, st), vec2(hw, st), fw));
	if (b) s = max(s, rect(l, vec2(hw - st, 6.75), vec2(st, 2.25), fw));
	if (c) s = max(s, rect(l, vec2(hw - st, 2.25), vec2(st, 2.25), fw));
	if (e) s = max(s, rect(l, vec2(-hw + st, 2.25), vec2(st, 2.25), fw));
	if (f) s = max(s, rect(l, vec2(-hw + st, 6.75), vec2(st, 2.25), fw));
	return s;
}

// everything painted near one runway end, in that end's frame: x across, y = metres from the threshold edge
float end_markings(vec2 p, vec2 fw, int d1, int d2, bool flip_x) {
	float m = 0.0;
	// threshold "piano keys": 12 stripes, 1.8 m wide, 30 m long, starting 6 m in
	for (int k = 0; k < 6; k++) {
		float cx = 2.7 + float(k) * 3.6;
		m = max(m, rect(p, vec2(cx, 21.0), vec2(0.9, 15.0), fw));
		m = max(m, rect(p, vec2(-cx, 21.0), vec2(0.9, 15.0), fw));
	}
	// designator, read by an aircraft landing over this threshold
	vec2 l = p;
	if (flip_x) {
		l.x = -l.x;
	}
	l.y -= 48.0;
	m = max(m, digit(d1, l + vec2(2.6, 0.0), fw));
	m = max(m, digit(d2, l - vec2(2.6, 0.0), fw));
	// aiming point: two 50 m x 8 m blocks starting 400 m from the threshold
	m = max(m, rect(p, vec2(13.5, 425.0), vec2(4.0, 25.0), fw));
	m = max(m, rect(p, vec2(-13.5, 425.0), vec2(4.0, 25.0), fw));
	// touchdown zone bars (22.5 m x 1.8 m) at 150 m intervals: 3, 2, 2, 1, 1 per side
	float zones[5] = float[5](150.0, 600.0, 750.0, 900.0, 1050.0);
	int bars[5] = int[5](3, 2, 2, 1, 1);
	for (int z = 0; z < 5; z++) {
		for (int b = 0; b < 3; b++) {
			if (b >= bars[z]) {
				break;
			}
			float cx = 10.4 + float(b) * 3.3;
			m = max(m, rect(p, vec2(cx, zones[z] + 11.25), vec2(0.9, 11.25), fw));
			m = max(m, rect(p, vec2(-cx, zones[z] + 11.25), vec2(0.9, 11.25), fw));
		}
	}
	return m;
}

void fragment() {
	vec2 p = vec2((UV.x - 0.5) * width_m, UV.y * length_m);    // metres: x across, y from the north end
	vec2 fw = max(fwidth(p), vec2(0.002));
	float m = 0.0;
	// edge lines (0.9 m) along the full length
	m = max(m, rect(p, vec2(width_m * 0.5 - 0.75, length_m * 0.5), vec2(0.45, length_m * 0.5), fw));
	m = max(m, rect(p, vec2(-width_m * 0.5 + 0.75, length_m * 0.5), vec2(0.45, length_m * 0.5), fw));
	// centreline: 30 m dashes, 20 m gaps, between the designators
	float yc = p.y - 70.0;
	if (yc > 0.0 && p.y < length_m - 70.0) {
		float q = mod(yc, 50.0) - 15.0;
		m = max(m, cover(p.x, 0.45, fw.x) * cover(q, 15.0, fw.y));
	}
	// north end: runway 18 (landing southbound, travelling +y); south end: runway 36 (landing northbound)
	m = max(m, end_markings(vec2(-p.x, p.y), fw, start_digits.x, start_digits.y, false));
	m = max(m, end_markings(vec2(p.x, length_m - p.y), fw, end_digits.x, end_digits.y, false));

	// asphalt with subtle variation, worn paint, tyre marks in the touchdown zones
	vec2 wp = p;
	float n1 = texture(detail_tex, wp / 7.0).r;
	float n2 = texture(detail_tex, wp / 61.0 + 0.3).r;
	vec3 asphalt = vec3(0.052, 0.054, 0.058) * (0.82 + 0.3 * n1) * (0.9 + 0.2 * n2);
	float from_end = min(p.y, length_m - p.y);
	float tyre_zone = smoothstep(120.0, 220.0, from_end) * (1.0 - smoothstep(650.0, 950.0, from_end));
	float tracks = smoothstep(7.0, 2.0, abs(abs(p.x) - 4.5)) * tyre_zone;
	asphalt *= 1.0 - 0.45 * tracks * (0.6 + 0.4 * texture(detail_tex, vec2(p.x / 1.5, p.y / 40.0)).r);
	vec3 paint = vec3(0.78, 0.78, 0.76) * (0.8 + 0.2 * n1) * (1.0 - 0.35 * tracks);
	ALBEDO = mix(asphalt, paint, m);
	ROUGHNESS = mix(0.9, 0.75, m);
	SPECULAR = 0.3;
}
