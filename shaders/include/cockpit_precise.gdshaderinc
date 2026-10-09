// Precise cockpit vertex transform.
//
// The world is kilometres across and the GPU works in 32-bit floats: at 7 km from the origin a position can
// only be stored to about half a millimetre, and to several millimetres further out. Godot builds each vertex's
// view-space position as view * model, two huge translations that cancel, so the cockpit (a few centimetres to
// a metre from the eye) jitters against the eye by up to a millimetre every frame. On a panel 0.7 m away that
// is one to two pixels, more when zoomed in: the whole cockpit seems to vibrate and fine text and lamps shimmer.
//
// scripts/aircraft/cockpit.gd computes model -> eye for every cockpit mesh from small, aircraft-relative numbers
// only (the eye and the mesh are both fixed in the aircraft, so the aircraft's world position cancels exactly)
// and passes it per instance as three rows. The main camera pass uses it; shadow and other passes (which use
// another view) fall back to Godot's usual transform.
instance uniform vec4 ck_r0 = vec4(1.0, 0.0, 0.0, 0.0);
instance uniform vec4 ck_r1 = vec4(0.0, 1.0, 0.0, 0.0);
instance uniform vec4 ck_r2 = vec4(0.0, 0.0, 1.0, 0.0);
instance uniform float ck_on = 0.0;

void ck_transform(inout vec3 v, inout vec3 n, inout vec3 t, inout vec3 b, mat4 mv, mat3 mvn, mat4 inv_view, mat4 main_inv_view) {
	if (ck_on > 0.5 && all(equal(inv_view[3].xyz, main_inv_view[3].xyz))) {
		mat4 m = transpose(mat4(ck_r0, ck_r1, ck_r2, vec4(0.0, 0.0, 0.0, 1.0)));
		mat3 r = mat3(m);
		v = (m * vec4(v, 1.0)).xyz;
		n = r * n;
		t = r * t;
		b = r * b;
	} else {
		v = (mv * vec4(v, 1.0)).xyz;
		n = normalize(mvn * n);
		t = normalize(mvn * t);
		b = normalize(mvn * b);
	}
}
