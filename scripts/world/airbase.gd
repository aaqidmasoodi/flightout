extends Node3D
## Airbase detail built at load from AirbaseLayout: 16 hardened shelters with sliding steel doors and lit bays,
## dispersal lanes with markings and blue edge lights, apron floodlights, a turning radar, windsocks,
## ILS antennas, ground vehicles. All static geometry is merged per material, so the whole base is a
## handful of draw calls. Shelters also get a collision shell (layer 2) so the camera can't pass through them.

const L := preload("res://scripts/world/airbase_layout.gd")
const STRUCTURE_LAYER := 2          # physics layer bit for buildings (camera collision)
const DETAIL_RANGE := 3500.0        # small props and markings fade out beyond this

var map: Node3D                     # the imported world scene, for its pavement materials

var _flood_mat: StandardMaterial3D
var _night_lights: Array[Light3D] = []
var _radar: Node3D
var _socks: Array[Node3D] = []
var _t := 0.0
var _check := 0.0
var _night := -1


## Triangle buffer with explicit normals. Winding is fixed up automatically against the normal,
## so every face is front-facing from the side its normal points to.
class Buf:
	var st := SurfaceTool.new()
	var count := 0

	func _init() -> void:
		st.begin(Mesh.PRIMITIVE_TRIANGLES)

	func tri(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
		if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
			var t := b
			b = c
			c = t
			var tn := nb
			nb = nc
			nc = tn
		st.set_normal(na)
		st.add_vertex(a)
		st.set_normal(nb)
		st.add_vertex(b)
		st.set_normal(nc)
		st.add_vertex(c)
		count += 3

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		tri(a, b, c, n, n, n)
		tri(a, c, d, n, n, n)

	func quad_n(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
		tri(a, b, c, na, nb, nc)
		tri(a, c, d, na, nc, nd)

	func box(xf: Transform3D, mn: Vector3, mx: Vector3) -> void:
		var c := (mn + mx) * 0.5
		var h := (mx - mn) * 0.5
		var axes := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
		for i in 3:
			var n: Vector3 = axes[i]
			var u: Vector3 = axes[(i + 1) % 3] * h[(i + 1) % 3]
			var v: Vector3 = axes[(i + 2) % 3] * h[(i + 2) % 3]
			for s: float in [-1.0, 1.0]:
				var f := c + n * s * h[i]
				var nn := (xf.basis * (n * s)).normalized()
				quad(xf * (f - u - v), xf * (f + u - v), xf * (f + u + v), xf * (f - u + v), nn)

	## Flat ground strip through `pts` (y already set), `width` metres wide.
	func strip(pts: Array, width: float) -> void:
		for i in pts.size() - 1:
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i + 1]
			var ta: Vector3 = (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)])
			var tb: Vector3 = (pts[mini(i + 2, pts.size() - 1)] - pts[i])
			var sa := ta.cross(Vector3.UP).normalized() * width * 0.5
			var sb := tb.cross(Vector3.UP).normalized() * width * 0.5
			quad(a - sa, b - sb, b + sb, a + sa, Vector3.UP)

	func mesh(mat: Material) -> ArrayMesh:
		if count == 0:
			return null
		var m := st.commit()
		m.surface_set_material(0, mat)
		return m


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var concrete := _concrete_mat(Color(0.56, 0.57, 0.54), Color(0.68, 0.68, 0.65))
	var pave := _pavement(_map_color("Apron", Color(0.55, 0.55, 0.53)), 5.0)
	var lane_mat := _pavement(_map_color("Taxiway", Color(0.36, 0.36, 0.35)), 0.0)
	# the imported apron and taxiways get the same pavement, so old and new surfaces match
	if map:
		for n in map.find_children("*", "MeshInstance3D", true, false):
			var nm := String(n.name)
			if nm == "Apron":
				(n as MeshInstance3D).material_override = pave
			elif nm.begins_with("Taxiway"):
				(n as MeshInstance3D).material_override = lane_mat
	var steel := _concrete_mat(Color(0.20, 0.23, 0.20), Color(0.34, 0.38, 0.33))
	steel.metallic = 0.45
	steel.roughness = 0.6
	var paint := _paint_mat(Color(0.86, 0.66, 0.10))
	var olive := _paint_mat(Color(0.27, 0.31, 0.21))
	var dark := _paint_mat(Color(0.06, 0.06, 0.06))
	var interior := _lamp_mat(Color(1.0, 0.92, 0.8), 1.6)
	_flood_mat = _lamp_mat(Color(1.0, 0.95, 0.82), 0.3)

	var shell := Buf.new()     # shelter concrete (also the collision shell)
	var conc := Buf.new()      # other concrete
	var metal := Buf.new()
	var floor_b := Buf.new()
	var lanes := Buf.new()
	var marks := Buf.new()
	var props := Buf.new()     # olive vehicles and carts
	var black := Buf.new()     # tyres, vents, rails
	var lamps := Buf.new()
	var blue: Array[Vector3] = []
	var red: Array[Vector3] = []

	for i in L.MAX_SLOTS:
		var xf := L.shelter_transform(i)
		_shelter(xf, shell, metal, floor_b, black, props, lamps)
		_shelter_number(xf, i + 1)
		var bay := OmniLight3D.new()
		bay.light_color = Color(1.0, 0.88, 0.7)
		bay.light_energy = 1.4
		bay.omni_range = 24.0
		bay.shadow_enabled = false
		bay.distance_fade_enabled = true
		bay.distance_fade_begin = 400.0
		bay.distance_fade_length = 150.0
		add_child(bay)
		bay.position = xf * Vector3(0.0, 7.0, L.DEPTH * 0.5)

	_lanes(lanes, marks, blue)
	_taxiway_lights(blue)
	_floodlights(metal, red)
	_radar_station(conc, metal, red)
	_tower_top(metal, red)
	_ils(metal, red)
	_vehicles(props, black, metal)
	_windsock(Vector3(-70.0, 0.0, 6900.0), metal)
	_windsock(Vector3(-70.0, 0.0, 5100.0), metal)

	var shell_mesh := shell.mesh(concrete)
	_add(shell_mesh, true, 0.0)
	_add(conc.mesh(concrete), true, 0.0)
	_add(metal.mesh(steel), true, 0.0)
	_add(floor_b.mesh(pave), false, 0.0)
	_add(lanes.mesh(lane_mat), false, 0.0)
	_add(marks.mesh(paint), false, DETAIL_RANGE)
	_add(props.mesh(olive), true, DETAIL_RANGE)
	_add(black.mesh(dark), false, DETAIL_RANGE)
	_add(lamps.mesh(interior), false, DETAIL_RANGE)
	_add_lights(blue, _lamp_mat(Color(0.25, 0.45, 1.0), 5.0), Vector3(0.35, 0.3, 0.35))
	_add_lights(red, _lamp_mat(Color(1.0, 0.1, 0.05), 5.0), Vector3(0.5, 0.5, 0.5))

	# collision shell for the camera (and later for ground contact)
	var body := StaticBody3D.new()
	body.collision_layer = STRUCTURE_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var tri := shell_mesh.create_trimesh_shape() as ConcavePolygonShape3D
	tri.backface_collision = true
	shape.shape = tri
	body.add_child(shape)
	add_child(body)
	_update_lights(true)


func _process(delta: float) -> void:
	_t += delta
	if _radar:
		_radar.rotation.y = fposmod(_t * TAU / 6.0, TAU)   # one sweep every 6 s
	var wind: float = WorldData.atmosphere.wind_speed
	var flutter := sin(_t * 2.7) * 0.6 + sin(_t * 7.3) * 0.4
	for s in _socks:
		s.rotation.y = flutter * 0.05 * clampf(wind / 8.0, 0.0, 1.0)
	_check -= delta
	if _check <= 0.0:
		_check = 0.5
		_update_lights(false)


func _update_lights(force: bool) -> void:
	var h: float = WorldData.time_of_day
	var night := 1 if (h < 6.4 or h > 18.3) else 0
	if night != _night or force:
		_night = night
		for l in _night_lights:
			l.visible = night == 1
		_flood_mat.emission_energy_multiplier = 7.0 if night == 1 else 0.25
	# windsocks follow the wind
	var spd: float = WorldData.atmosphere.wind_speed
	var from: float = deg_to_rad(WorldData.atmosphere.wind_from_deg)
	var down := Vector3(-sin(from), 0.0, cos(from))           # heading the air moves towards
	var droop := deg_to_rad(lerpf(78.0, 4.0, clampf(spd / 12.0, 0.0, 1.0)))
	var fwd := (down * cos(droop) + Vector3.DOWN * sin(droop)).normalized()
	for s in _socks:
		var p := s.get_parent() as Node3D
		p.basis = Basis.looking_at(fwd, Vector3.UP if absf(fwd.y) < 0.99 else Vector3.BACK)


# ------------------------------------------------------------------ shelters

func _shelter(xf: Transform3D, shell: Buf, metal: Buf, floor_b: Buf, black: Buf, props: Buf, lamps: Buf) -> void:
	const SEG := 24
	var d: float = L.DEPTH
	var wi: float = L.INNER_HALF_WIDTH
	var hi: float = L.INNER_HEIGHT
	var wo := wi + 1.3
	var ho := hi + 1.4
	var back := d + 1.3
	var b := xf.basis
	for k in SEG:
		var t0 := PI * k / SEG
		var t1 := PI * (k + 1) / SEG
		var o0 := Vector3(wo * cos(t0), ho * sin(t0), 0.0)
		var o1 := Vector3(wo * cos(t1), ho * sin(t1), 0.0)
		var i0 := Vector3(wi * cos(t0), hi * sin(t0), 0.0)
		var i1 := Vector3(wi * cos(t1), hi * sin(t1), 0.0)
		var no0 := b * Vector3(cos(t0) / wo, sin(t0) / ho, 0.0).normalized()
		var no1 := b * Vector3(cos(t1) / wo, sin(t1) / ho, 0.0).normalized()
		var ni0 := -(b * Vector3(cos(t0) / wi, sin(t0) / hi, 0.0).normalized())
		var ni1 := -(b * Vector3(cos(t1) / wi, sin(t1) / hi, 0.0).normalized())
		var zb := Vector3(0.0, 0.0, back)
		var zd := Vector3(0.0, 0.0, d)
		shell.quad_n(xf * o0, xf * o1, xf * (o1 + zb), xf * (o0 + zb), no0, no1, no1, no0)
		shell.quad_n(xf * i0, xf * i1, xf * (i1 + zd), xf * (i0 + zd), ni0, ni1, ni1, ni0)
		# back wall: inner face and outer cap
		shell.tri(xf * Vector3(0.0, 0.0, d), xf * (i0 + zd), xf * (i1 + zd), -b.z, -b.z, -b.z)
		shell.tri(xf * Vector3(0.0, 0.0, back), xf * (o0 + zb), xf * (o1 + zb), b.z, b.z, b.z)
		# ribs: shallow concrete bands over the vault every 6 m
		for r in range(1, 6):
			var z := r * 6.0
			var e0 := Vector3(o0.x * 1.018, o0.y * 1.018, z)
			var e1 := Vector3(o1.x * 1.018, o1.y * 1.018, z)
			shell.quad_n(xf * (e0 - Vector3(0, 0, 0.4)), xf * (e1 - Vector3(0, 0, 0.4)), xf * (e1 + Vector3(0, 0, 0.4)), xf * (e0 + Vector3(0, 0, 0.4)), no0, no1, no1, no0)

	# headwall: two pillars and a lintel around the door opening, with a coping on top
	var hw := 23.5
	shell.box(xf, Vector3(-hw, 0.0, -1.5), Vector3(-wi, 11.5, 0.6))
	shell.box(xf, Vector3(wi, 0.0, -1.5), Vector3(hw, 11.5, 0.6))
	shell.box(xf, Vector3(-wi, 8.6, -1.5), Vector3(wi, 11.5, 0.6))
	shell.box(xf, Vector3(-hw - 0.4, 11.5, -1.9), Vector3(hw + 0.4, 12.1, 1.0))
	# buttresses tying the headwall to the vault
	for s: float in [-1.0, 1.0]:
		shell.box(xf, Vector3(minf(s * 13.0, s * 21.0), 0.0, 0.6), Vector3(maxf(s * 13.0, s * 21.0), 6.0, 3.5))

	# sliding doors, parked open in front of the pillars, on rails
	for s: float in [-1.0, 1.0]:
		var x0 := minf(s * 11.3, s * 23.1)
		var x1 := maxf(s * 11.3, s * 23.1)
		metal.box(xf, Vector3(x0, 0.15, -2.7), Vector3(x1, 8.9, -1.9))
		for r in 5:
			var rx := lerpf(x0 + 1.0, x1 - 1.0, r / 4.0)
			metal.box(xf, Vector3(rx - 0.18, 0.15, -2.95), Vector3(rx + 0.18, 8.9, -2.7))
		metal.box(xf, Vector3(x0, 3.9, -2.95), Vector3(x1, 4.3, -2.7))
	metal.box(xf, Vector3(-hw, 8.95, -2.9), Vector3(hw, 9.5, -1.5))   # roller track
	black.box(xf, Vector3(-hw, 0.0, -2.55), Vector3(hw, 0.1, -2.35))
	black.box(xf, Vector3(-hw, 0.0, -2.25), Vector3(hw, 0.1, -2.05))

	# exhaust vent on the back wall
	black.box(xf, Vector3(-3.0, 1.5, back), Vector3(3.0, 6.0, back + 0.6))
	for r in 6:
		metal.box(xf, Vector3(-3.2, 1.7 + r * 0.75, back + 0.6), Vector3(3.2, 1.9 + r * 0.75, back + 1.0))

	# floor and pad, a hair above the terrain
	var up := Vector3.UP
	floor_b.quad(xf * Vector3(-wi, 0.07, -1.5), xf * Vector3(wi, 0.07, -1.5), xf * Vector3(wi, 0.07, d), xf * Vector3(-wi, 0.07, d), up)
	floor_b.quad(xf * Vector3(-13.0, 0.065, -1.5), xf * Vector3(13.0, 0.065, -1.5), xf * Vector3(20.0, 0.065, -L.LEAD_IN), xf * Vector3(-20.0, 0.065, -L.LEAD_IN), up)

	# bay lights along the vault
	for s: float in [-1.0, 1.0]:
		var x := s * 4.5
		var y := hi * sqrt(1.0 - pow(x / wi, 2.0)) - 0.25
		for k in 8:
			var z := 4.0 + k * 4.0
			lamps.box(xf, Vector3(x - 0.12, y - 0.08, z), Vector3(x + 0.12, y, z + 1.5))

	# ground power cart beside the pad
	props.box(xf, Vector3(15.0, 0.35, -9.5), Vector3(16.8, 1.5, -6.5))
	black.box(xf, Vector3(14.9, 0.0, -9.2), Vector3(16.9, 0.45, -8.6))
	black.box(xf, Vector3(14.9, 0.0, -7.4), Vector3(16.9, 0.45, -6.8))


func _shelter_number(xf: Transform3D, n: int) -> void:
	var lbl := Label3D.new()
	lbl.text = "%02d" % n
	lbl.font_size = 220
	lbl.pixel_size = 0.008
	lbl.modulate = Color(0.08, 0.08, 0.08)
	lbl.outline_size = 0
	lbl.shaded = true
	lbl.double_sided = false
	lbl.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	lbl.visibility_range_end = 1500.0
	add_child(lbl)
	lbl.global_transform = xf * Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 10.5, -1.53))


# ------------------------------------------------------------------ lanes and lights

func _lanes(lanes: Buf, marks: Buf, blue: Array[Vector3]) -> void:
	var up := Vector3.UP
	var y := L.ELEVATION
	var hw: float = L.LANE_HALF_WIDTH
	for lane: float in L.LANES:
		var x0: float = L.TAXIWAY_EAST_X
		var x1: float = L.LANE_END_X
		lanes.quad(Vector3(x0, y + 0.06, lane - hw), Vector3(x1, y + 0.06, lane - hw), Vector3(x1, y + 0.06, lane + hw), Vector3(x0, y + 0.06, lane + hw), up)
		# centreline and hold line
		marks.strip([Vector3(x0, y + 0.1, lane), Vector3(x1 - 12.0, y + 0.1, lane)], 0.3)
		for k in 2:
			var hx := x0 + 7.0 + k * 0.9
			marks.strip([Vector3(hx, y + 0.1, lane - hw + 0.5), Vector3(hx, y + 0.1, lane + hw - 0.5)], 0.3)
		# blue edge lights, with gaps where the shelter pads join
		var mouths := []
		for s in L.shelters():
			if is_equal_approx(s.lane, lane):
				mouths.append(s.door)
		for side: float in [-1.0, 1.0]:
			var x := x0 + 12.0
			while x <= x1:
				var gap := false
				for m: Vector3 in mouths:
					if signf(m.z - lane) == side and absf(m.x - x) < 22.0:
						gap = true
				if not gap:
					blue.append(Vector3(x, y + 0.25, lane + side * (hw + 0.6)))
				x += 30.0
		for k in 3:
			blue.append(Vector3(x1 + 0.6, y + 0.25, lane + (k - 1) * hw * 0.9))
	# lead-in lines: off the centreline, round a 20 m curve, straight into the bay to the parking spot
	for s in L.shelters():
		var door: Vector3 = s.door
		var lane: float = s.lane
		var sgn := signf(door.z - lane)
		const R := 20.0
		var c := Vector3(door.x - R, y + 0.1, lane + sgn * R)
		var pts := [Vector3(door.x - R - 12.0, y + 0.1, lane)]
		for k in 13:
			var a := PI * 0.5 * k / 12.0
			pts.append(c + Vector3(R * sin(a), 0.0, -sgn * R * cos(a)))
		pts.append(Vector3(door.x, y + 0.1, door.z + sgn * (L.JET_INSET - 9.0)))
		marks.strip(pts, 0.3)
		# stop bar where the nose wheel parks
		var stop := door + Vector3(0.0, 0.1, sgn * (L.JET_INSET - 9.0))
		marks.strip([stop + Vector3(-2.0, 0.0, 0.0), stop + Vector3(2.0, 0.0, 0.0)], 0.4)


func _taxiway_lights(blue: Array[Vector3]) -> void:
	var y := L.ELEVATION + 0.25
	var z := 4650.0
	while z <= 7350.0:
		var near_link := false
		for lz: float in [4650.0, 6000.0, 7350.0]:
			near_link = near_link or absf(z - lz) < 20.0
		if not near_link:
			blue.append(Vector3(169.4, y, z))
		var near_east := z > 5690.0 and z < 6310.0
		for lz: float in L.LANES:
			near_east = near_east or absf(z - lz) < 20.0
		if not near_east:
			blue.append(Vector3(193.6, y, z))
		z += 60.0


func _floodlights(metal: Buf, red: Array[Vector3]) -> void:
	var y := L.ELEVATION
	var masts := [
		[Vector3(210.0, y, 5690.0), Vector3(330.0, y, 5900.0)],
		[Vector3(505.0, y, 5690.0), Vector3(400.0, y, 5900.0)],
		[Vector3(210.0, y, 6310.0), Vector3(330.0, y, 6100.0)],
		[Vector3(505.0, y, 6310.0), Vector3(400.0, y, 6100.0)],
	]
	for lane: float in L.LANES:
		masts.append([Vector3(L.LANE_END_X + 8.0, y, lane), Vector3(L.LANE_END_X - 90.0, y, lane)])
		masts.append([Vector3(L.TAXIWAY_EAST_X + 15.0, y, lane - 16.0), Vector3(290.0, y, lane)])
	var head_buf := Buf.new()
	for m in masts:
		var base: Vector3 = m[0]
		var aim: Vector3 = m[1]
		var t := Transform3D(Basis(), base)
		metal.box(t, Vector3(-0.35, 0.0, -0.35), Vector3(0.35, 25.0, 0.35))
		metal.box(t, Vector3(-1.0, 0.0, -1.0), Vector3(1.0, 0.6, 1.0))
		var face := Vector3(aim.x - base.x, 0.0, aim.z - base.z).normalized()
		var hb := Basis.looking_at(face, Vector3.UP)
		head_buf.box(Transform3D(hb, base + Vector3(0.0, 24.6, 0.0)), Vector3(-1.8, -0.4, -0.9), Vector3(1.8, 0.4, -0.3))
		red.append(base + Vector3(0.0, 25.4, 0.0))
		var spot := SpotLight3D.new()
		spot.light_color = Color(1.0, 0.93, 0.8)
		spot.light_energy = 6.0
		spot.spot_range = 170.0
		spot.spot_angle = 52.0
		spot.spot_attenuation = 0.6
		spot.shadow_enabled = false
		spot.distance_fade_enabled = true
		spot.distance_fade_begin = 2500.0
		spot.distance_fade_length = 500.0
		add_child(spot)
		var pos := base + Vector3(0.0, 24.3, 0.0)
		spot.global_transform = Transform3D(Basis.looking_at((aim - pos).normalized(), Vector3.UP), pos)
		_night_lights.append(spot)
	_add(head_buf.mesh(_flood_mat), false, 0.0)


func _radar_station(conc: Buf, metal: Buf, red: Array[Vector3]) -> void:
	var base := Vector3(660.0, L.ELEVATION, 5650.0)
	var t := Transform3D(Basis(), base)
	conc.box(t, Vector3(-5.0, 0.0, -5.0), Vector3(5.0, 3.2, 5.0))
	conc.box(t, Vector3(6.0, 0.0, -4.0), Vector3(14.0, 3.5, 4.0))     # equipment hut
	metal.box(t, Vector3(-0.6, 3.2, -0.6), Vector3(0.6, 11.0, 0.6))
	_radar = Node3D.new()
	add_child(_radar)
	_radar.position = base + Vector3(0.0, 11.0, 0.0)
	var a := Buf.new()
	var tilt := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-14.0)), Vector3(0.0, 1.6, 0.0))
	a.box(tilt, Vector3(-5.5, -1.3, -0.15), Vector3(5.5, 1.3, 0.15))
	a.box(Transform3D(), Vector3(-0.3, 0.0, -0.3), Vector3(0.3, 0.6, 0.3))
	a.box(Transform3D(), Vector3(-0.12, 0.6, 0.0), Vector3(0.12, 0.85, 3.0))
	var mi := MeshInstance3D.new()
	mi.mesh = a.mesh(_steel_light())
	_radar.add_child(mi)
	red.append(base + Vector3(0.0, 14.5, 0.0))


func _tower_top(metal: Buf, red: Array[Vector3]) -> void:
	var t := Transform3D(Basis(), Vector3(300.0, 63.1, 5600.0))
	metal.box(t, Vector3(-0.12, 0.0, -0.12), Vector3(0.12, 7.0, 0.12))
	metal.box(t, Vector3(3.0, 0.0, 3.0), Vector3(3.2, 3.0, 3.2))
	metal.box(t, Vector3(-6.6, -5.1, -6.6), Vector3(6.6, -4.95, 6.6))   # cab balcony
	red.append(t * Vector3(0.0, 7.2, 0.0))


func _ils(metal: Buf, red: Array[Vector3]) -> void:
	# localizer array beyond the far end of runway 36, glideslope mast abeam its touchdown zone
	var z := 4500.0 - 300.0
	var y := WorldData.ground_height(0.0, z)
	for k in 14:
		var x := lerpf(-19.5, 19.5, k / 13.0)
		metal.box(Transform3D(), Vector3(x - 0.08, y, z - 0.08), Vector3(x + 0.08, y + 3.2, z + 0.08))
		metal.box(Transform3D(), Vector3(x - 0.9, y + 2.6, z - 0.05), Vector3(x + 0.9, y + 2.7, z + 0.05))
	metal.box(Transform3D(), Vector3(-20.0, y + 1.0, z - 0.1), Vector3(20.0, y + 1.15, z + 0.1))
	var g := Vector3(-120.0, L.ELEVATION, 7200.0)
	metal.box(Transform3D(), g + Vector3(-0.3, 0.0, -0.3), g + Vector3(0.3, 15.0, 0.3))
	metal.box(Transform3D(), g + Vector3(-1.5, 0.0, 1.0), g + Vector3(1.5, 2.4, 4.0))
	red.append(g + Vector3(0.0, 15.3, 0.0))


func _vehicles(props: Buf, black: Buf, metal: Buf) -> void:
	# fuel bowsers and a tug parked along the east edge of the apron
	var spots := [Vector3(505.0, L.ELEVATION, 5860.0), Vector3(505.0, L.ELEVATION, 5872.0), Vector3(505.0, L.ELEVATION, 5884.0), Vector3(508.0, L.ELEVATION, 6120.0)]
	for i in spots.size():
		var t := Transform3D(Basis(Vector3.UP, PI * 0.5), spots[i])
		if i < 3:
			props.box(t, Vector3(-1.25, 0.9, -4.6), Vector3(1.25, 3.2, -2.4))     # cab
			metal.box(t, Vector3(-1.2, 1.0, -2.2), Vector3(1.2, 3.1, 4.4))       # tank
			props.box(t, Vector3(-1.3, 0.6, -4.6), Vector3(1.3, 1.0, 4.6))        # chassis
			for wz: float in [-3.6, 1.6, 3.4]:
				black.box(t, Vector3(-1.35, 0.0, wz - 0.55), Vector3(1.35, 1.1, wz + 0.55))
		else:
			props.box(t, Vector3(-1.2, 0.4, -2.2), Vector3(1.2, 1.4, 2.2))
			props.box(t, Vector3(-0.9, 1.4, 0.4), Vector3(0.9, 2.5, 1.8))
			for wz: float in [-1.4, 1.4]:
				black.box(t, Vector3(-1.3, 0.0, wz - 0.45), Vector3(1.3, 0.9, wz + 0.45))


func _windsock(at: Vector3, metal: Buf) -> void:
	var base := Vector3(at.x, WorldData.ground_height(at.x, at.z), at.z)
	var t := Transform3D(Basis(), base)
	metal.box(t, Vector3(-0.1, 0.0, -0.1), Vector3(0.1, 6.3, 0.1))
	metal.box(t, Vector3(-0.6, 0.0, -0.6), Vector3(0.6, 0.3, 0.6))
	var pivot := Node3D.new()
	add_child(pivot)
	pivot.position = base + Vector3(0.0, 6.2, 0.0)
	var sock := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.22
	cyl.bottom_radius = 0.5
	cyl.height = 3.6
	cyl.radial_segments = 12
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	sock.mesh = cyl
	var m := _paint_mat(Color(1.0, 0.38, 0.05))
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	sock.material_override = m
	sock.transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 0.0, -1.8))
	var flutter := Node3D.new()
	pivot.add_child(flutter)
	flutter.add_child(sock)
	_socks.append(flutter)


# ------------------------------------------------------------------ helpers

func _add(mesh: ArrayMesh, shadows: bool, range_end: float) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if range_end > 0.0:
		mi.visibility_range_end = range_end
		mi.visibility_range_end_margin = range_end * 0.1
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mi)


func _add_lights(points: Array[Vector3], mat: Material, size: Vector3) -> void:
	if points.is_empty():
		return
	var mesh := BoxMesh.new()
	mesh.size = size
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = points.size()
	for i in points.size():
		mm.set_instance_transform(i, Transform3D(Basis(), points[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _map_color(node_name: String, fallback: Color) -> Color:
	if map:
		for n in map.find_children(node_name, "MeshInstance3D", true, false):
			var m := (n as MeshInstance3D).get_active_material(0) as BaseMaterial3D
			if m:
				return m.albedo_color
	return fallback


static var _pave_noise: NoiseTexture2D

func _pavement(c: Color, joints: float) -> ShaderMaterial:
	if _pave_noise == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.03
		noise.fractal_octaves = 4
		_pave_noise = NoiseTexture2D.new()
		_pave_noise.width = 256
		_pave_noise.height = 256
		_pave_noise.seamless = true
		_pave_noise.generate_mipmaps = true
		_pave_noise.noise = noise
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/pavement.gdshader")
	m.set_shader_parameter("base_color", Color(c.r, c.g, c.b))
	m.set_shader_parameter("joint_spacing", joints)
	m.set_shader_parameter("noise_tex", _pave_noise)
	return m


func _concrete_mat(dark_c: Color, light_c: Color) -> StandardMaterial3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.55
	var grad := Gradient.new()
	grad.set_color(0, dark_c)
	grad.set_color(1, light_c)
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = noise
	tex.color_ramp = grad
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.06, 0.06, 0.06)
	m.roughness = 0.93
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


func _steel_light() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.57, 0.55)
	m.metallic = 0.6
	m.roughness = 0.45
	return m


func _paint_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.75
	return m


func _lamp_mat(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m
