extends Node3D
## Airfield lighting for every runway in data/maps/<map>/airfields.json: edge lights, threshold (green) and runway
## end (red) bars, an approach light lane and a PAPI for each landing direction.
##
## Heights: nothing here is copied from a threshold. Each fixture is placed on the surface it really stands on:
##   - on or beside the runway: the runway's own straight profile between its two ends (the same line the runway mesh
##     follows and tools/build_kashmir.py levels the ground to, 45 m either side), so a sloping runway (Leh climbs
##     about 20 m along its length) has its lights on it from end to end
##   - beyond the runway (approach lights): the terrain under each fixture
## The Earth's curvature is applied in the shader (shaders/airfield_light.gdshader) exactly as for the terrain and the
## runway, so distant lights sink with the ground instead of floating above it.
##
## Each airfield gets its own MultiMeshes, placed at the airfield and holding fixture offsets relative to it (small,
## precise numbers). A child of the World node: it moves with the floating origin.
##
## PAPI: four units left of the touchdown aim point. On a 3 degree glide you see two white and two red; all white =
## too high, all red = too low. Bright enough to use in daylight.

const SHADER := preload("res://shaders/airfield_light.gdshader")
const RUNWAY_LIFT := 0.12          # the runway mesh above the levelled ground (scripts/world/airfields.gd)
const FIXTURE := 0.35              # light centre above the surface it stands on
const EDGE_SPACING := 60.0
const EDGE_OUT := 1.5              # edge lights this far outside the paved edge
const APPROACH_STEP := 30.0
const APPROACH_LEN := 900.0
const PAPI_ANGLES := [3.5, 3.17, 2.83, 2.5]   # innermost (next to the runway) to outermost
const PAPI_RANGE := 25000.0        # PAPIs further than this from the viewer are not updated

const WHITE := Color(1.0, 0.93, 0.78)
const GREEN := Color(0.25, 1.0, 0.45)
const RED := Color(1.0, 0.1, 0.06)
const APPROACH := Color(1.0, 0.95, 0.85)

var _papi: Array = []   # [{mm, i, pos (map coordinates), angle}]


func _ready() -> void:
	var lamp := _material(0.6, 2.5, 6.0, false)
	var papi := _material(1.4, 3.0, 9.0, true)
	for a in WorldData.airfields:
		var centre := Vector3(float(a.x), 0.0, float(a.z))
		var lamps: Array = []    # [offset, color, custom]
		var units: Array = []    # PAPI: [offset, angle]
		for r in a.runways:
			_runway(r, centre, lamps, units)
		if lamps.is_empty():
			continue
		var site := Node3D.new()
		site.name = String(a.id)
		site.position = centre
		add_child(site)
		_instances(site, lamps, lamp)
		var mm := _instances(site, units.map(func(u): return [u[0], WHITE, u[2]]), papi)
		for i in units.size():
			_papi.append({"mm": mm, "i": i, "pos": centre + units[i][0], "angle": units[i][1]})


## All fixtures of one runway (both landing directions), as offsets from the airfield `centre`.
func _runway(r: Dictionary, centre: Vector3, lamps: Array, units: Array) -> void:
	var A := Vector3(r.a[0], r.a[1], r.a[2])
	var B := Vector3(r.b[0], r.b[1], r.b[2])
	var flat := Vector3(B.x - A.x, 0.0, B.z - A.z)
	var length := flat.length()
	if length < 100.0:
		return
	var u := flat / length                               # A towards B
	var side := Vector3(-u.z, 0.0, u.x)
	var hw: float = float(r.width) * 0.5
	var surf := func(along: float, across: float) -> Vector3:
		# a point on the runway's straight profile (along: m from A, across: m to the right of A->B)
		var t := clampf(along / length, 0.0, 1.0)
		var p := A + u * along + side * across
		p.y = lerpf(A.y, B.y, t) + RUNWAY_LIFT + FIXTURE
		return p - centre
	var omni := Vector3.ZERO
	var to_a := Vector3(-u.x, -u.z, 1.0)                 # shines back past A (towards arrivals landing A->B)
	var to_b := Vector3(u.x, u.z, 1.0)
	# edge lights, evenly spaced from end to end
	var n := maxi(1, roundi(length / EDGE_SPACING))
	for k in n + 1:
		var along := length * k / n
		for s in [-1.0, 1.0]:
			lamps.append([surf.call(along, s * (hw + EDGE_OUT)), WHITE, omni])
	# threshold / end bars across each end: green towards the approach, red towards the runway
	var bar := maxi(5, int(r.width / 4.0))
	for k in bar + 1:
		var across := lerpf(-hw, hw, float(k) / bar)
		var pa: Vector3 = surf.call(0.0, across)
		var pb: Vector3 = surf.call(length, across)
		lamps.append([pa, GREEN, to_a])
		lamps.append([pa, RED, to_b])
		lamps.append([pb, GREEN, to_b])
		lamps.append([pb, RED, to_a])
	# for each landing direction: approach lane on the terrain and the PAPI
	for end in [[A, u, side], [B, -u, -side]]:
		var th: Vector3 = end[0]
		var dir: Vector3 = end[1]
		var right: Vector3 = end[2]
		var face := Vector3(-dir.x, -dir.z, 1.0)
		var steps := int(APPROACH_LEN / APPROACH_STEP)
		for k in range(1, steps + 1):
			var p: Vector3 = th - dir * (k * APPROACH_STEP)
			var row: Array = [0.0]
			if k == 10:
				row = [-15.0, -12.0, -9.0, -6.0, -3.0, 0.0, 3.0, 6.0, 9.0, 12.0, 15.0]   # crossbar at 300 m
			for c in row:
				var q: Vector3 = p + right * float(c)
				q.y = WorldData.ground_height(q.x, q.z) + FIXTURE + 0.25
				lamps.append([q - centre, APPROACH, face])
		var along_aim: float = WorldData.AIM_DISTANCE if th == A else length - WorldData.AIM_DISTANCE
		for i in 4:
			var off: float = -(hw + 15.0 + i * 9.0)       # left of the landing direction
			var across := off if th == A else -off
			var p: Vector3 = surf.call(along_aim, across)
			p.y += 0.5                                     # PAPI boxes stand a little higher
			units.append([p, PAPI_ANGLES[i], face])


func _material(size: float, min_px: float, intensity: float, day_on: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("size_m", size)
	m.set_shader_parameter("min_px", min_px)
	m.set_shader_parameter("intensity", intensity)
	m.set_shader_parameter("day_on", day_on)
	return m


func _instances(site: Node3D, items: Array, mat: ShaderMaterial) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = items.size()
	var box := AABB()
	for i in items.size():
		var p: Vector3 = items[i][0]
		mm.set_instance_transform(i, Transform3D(Basis(), p))
		mm.set_instance_color(i, items[i][1])
		var c: Vector3 = items[i][2]
		mm.set_instance_custom_data(i, Color(c.x, c.y, c.z, 0.0))
		box = AABB(p, Vector3.ZERO) if i == 0 else box.expand(p)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the discs are sized and sunk (curvature) in the shader: keep the culling box generous, mostly downwards
	mmi.custom_aabb = box.grow(200.0).merge(AABB(box.position - Vector3(0.0, 1500.0, 0.0), Vector3(1.0, 1.0, 1.0)))
	site.add_child(mmi)
	return mm


func _process(_delta: float) -> void:
	if _papi.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := WorldData.to_world(cam.global_position)
	for p in _papi:
		var v: Vector3 = eye - p.pos
		var flat := Vector2(v.x, v.z).length()
		if flat > PAPI_RANGE:
			continue
		# what the curvature hides at this distance lowers the eye, as it does the light (shader) on screen
		var elev := rad_to_deg(atan2(v.y - flat * flat * WorldData.EARTH_CURVE, flat))
		p.mm.set_instance_color(p.i, WHITE if elev > p.angle else RED)
