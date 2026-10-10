shader_type spatial;
render_mode world_vertex_coords, blend_mix, depth_draw_never, cull_disabled, diffuse_lambert_wrap, specular_disabled, shadows_disabled;
// A trail ribbon (scripts/fx/trail.gd): wingtip vortices, vapour, contrails, missile smoke.
//
// The script keeps a ring of points the emitter passed through (scene position, birth time, intensity) in a small
// float texture; this static strip mesh is laid along them here, on the GPU: a Catmull-Rom spline through the points
// (so an S-turn stays an S), turned to face the camera, widening and fading with age. The first segment runs from the
// newest stored point to the emitter's live position, so the ribbon is always attached to the jet, every frame.
// Strip vertex: UV.x = position along the trail in points (0 = the live head, 1 = newest stored point, ...),
// UV.y = side (-1 / +1).

uniform sampler2D points : filter_nearest;     // row 0: xyz scene position, w birth time; row 1: r intensity
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform int cap = 64;                 // ring size
uniform int head = 0;                 // ring index of the newest stored point
uniform int count = 0;                // stored points
uniform vec4 live = vec4(0.0);        // xyz emitter position now, w intensity now
uniform vec3 shift = vec3(0.0);       // floating origin moves since the points were stored (scene = stored - shift)
uniform float now = 0.0;              // the trail's clock (seconds; stops while the game is paused)
uniform float lifetime = 2.0;
uniform float width0 = 0.5;           // metres at birth
uniform float growth = 0.5;           // metres of width added per second of age
uniform float fade_in = 0.0;          // seconds before a point shows (contrails form a little behind the nozzle)
uniform vec4 color : source_color = vec4(1.0);
uniform float opacity = 0.6;
uniform float wisp = 0.5;             // how broken up (noise) the ribbon looks
uniform float self_lit = 0.0;         // extra brightness in daylight: smoke and vapour scatter sunlight from every side
global uniform vec3 sun_dir;

varying float v_alpha;
varying float v_side;
varying float v_birth;
varying float v_age;

vec4 pt(int j) {
	if (j <= 0) {
		return vec4(live.xyz, now);
	}
	vec4 p = texelFetch(points, ivec2((head - (j - 1) + cap * 4) % cap, 0), 0);
	return vec4(p.xyz - shift, p.w);
}

float inten(int j) {
	if (j <= 0) {
		return live.w;
	}
	return texelFetch(points, ivec2((head - (j - 1) + cap * 4) % cap, 1), 0).r;
}

void vertex() {
	float u = UV.x;
	int k = int(floor(u));
	float t = u - float(k);
	int last = count;                 // index of the oldest stored point
	if (k >= last) {
		// beyond the stored points: collapse onto the oldest one (zero area, nothing drawn)
		k = max(last - 1, 0);
		t = last > 0 ? 1.0 : 0.0;
	}
	vec4 a = pt(k);
	vec4 b = pt(min(k + 1, last));
	vec3 p0 = k > 0 ? pt(k - 1).xyz : 2.0 * a.xyz - b.xyz;
	vec3 p3 = k + 2 <= last ? pt(k + 2).xyz : 2.0 * b.xyz - a.xyz;
	vec3 p1 = a.xyz;
	vec3 p2 = b.xyz;
	// Catmull-Rom position and tangent
	float t2 = t * t;
	float t3 = t2 * t;
	vec3 pos = 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3);
	vec3 tan = 0.5 * ((p2 - p0) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (3.0 * p1 - p0 - 3.0 * p2 + p3) * t2);
	if (dot(tan, tan) < 1e-8) {
		tan = p2 - p1 + vec3(0.0, 0.0, 1e-4);
	}
	float birth = mix(a.w, b.w, t);
	float age = max(now - birth, 0.0);
	float life = age / lifetime;
	float i = mix(inten(k), inten(min(k + 1, last)), t);
	v_alpha = (last == 0 || life >= 1.0) ? 0.0 : i * (1.0 - smoothstep(0.3, 1.0, life)) * smoothstep(0.0, max(fade_in, 1e-4), age);
	float w = width0 + growth * age;
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - pos);
	vec3 side = normalize(cross(normalize(tan), to_cam));
	VERTEX = pos + side * UV.y * w * 0.5;
	NORMAL = to_cam;
	v_side = UV.y;
	v_birth = birth;
	v_age = age;
}

void fragment() {
	if (v_alpha <= 0.001) {
		discard;
	}
	// soft across the ribbon, broken up along it (the noise is fixed to the air, by birth time, so it does not crawl)
	float across = 1.0 - v_side * v_side;
	float n = texture(noise_tex, vec2(v_birth * 0.9, v_side * 0.35 + v_age * 0.05)).r;
	float n2 = texture(noise_tex, vec2(v_birth * 3.1 + 0.37, v_side * 0.8)).r;
	float body = mix(1.0, smoothstep(0.25, 0.75, n * 0.65 + n2 * 0.35), wisp);
	ALPHA = clamp(v_alpha * opacity * across * across * body, 0.0, 1.0);
	ALBEDO = color.rgb;
	EMISSION = color.rgb * self_lit * smoothstep(-0.05, 0.25, sun_dir.y);
	ROUGHNESS = 1.0;
	BACKLIGHT = color.rgb * 0.6;       // sunlight through the vapour
}
