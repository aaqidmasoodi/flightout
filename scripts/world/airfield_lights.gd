extends Node3D
## Runway edge, threshold and approach lights plus a PAPI for each landing direction.
## PAPI: four lights left of the touchdown zone. On a 3 degree glide you see two white and two red;
## all white = too high, all red = too low.

const PAPI_ANGLES := [3.5, 3.17, 2.83, 2.5]   # innermost (next to the runway) to outermost

var _papi: Array = []   # [{pos, angle, mat}]
var _white: StandardMaterial3D
var _red: StandardMaterial3D


func _ready() -> void:
	_white = _lamp_mat(Color(1.0, 0.97, 0.88), 6.0)
	_red = _lamp_mat(Color(1.0, 0.12, 0.08), 6.0)
	var green := _lamp_mat(Color(0.2, 1.0, 0.4), 6.0)
	var edge: Array[Vector3] = []
	var thresh: Array[Vector3] = []
	var approach: Array[Vector3] = []
	for r in WorldData.runways:
		var dir: Vector3 = r.dir
		var right := dir.cross(Vector3.UP).normalized()
		var th: Vector3 = r.threshold
		var half: float = r.width / 2.0 + 1.0
		var n := int(r.length / 60.0)
		for i in n + 1:
			for s in [-1.0, 1.0]:
				edge.append(th + dir * (i * 60.0) + right * (half * s) + Vector3.UP * 0.25)
		for k in 9:
			thresh.append(th + right * lerpf(-r.width / 2.0, r.width / 2.0, k / 8.0) - dir * 2.0 + Vector3.UP * 0.25)
		# approach lane: centreline every 30 m out to 900 m, crossbar at 300 m
		for k in range(1, 31):
			var p: Vector3 = th - dir * (k * 30.0)
			p.y = WorldData.ground_height(p.x, p.z) + 1.5
			approach.append(p)
			if k == 10:
				for c in range(-5, 6):
					var q := p + right * (c * 3.0)
					q.y = WorldData.ground_height(q.x, q.z) + 1.5
					approach.append(q)
		# PAPI units on the left of the landing direction, abeam the aim point (instrument runway only)
		if not r.get("ils", false):
			continue
		var aim: Vector3 = th + dir * WorldData.AIM_DISTANCE
		for i in 4:
			var pos: Vector3 = aim - right * (r.width / 2.0 + 15.0 + i * 9.0) + Vector3.UP * 1.2
			var m := _lamp_mat(Color.WHITE, 8.0)
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(4.0, 2.0, 1.5)
			box.mesh = bm
			box.material_override = m
			box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(box)
			box.global_position = pos
			_papi.append({"pos": pos, "angle": PAPI_ANGLES[i], "mat": m})
	_add_lights(edge, _white, Vector3(0.5, 0.35, 0.5))
	_add_lights(thresh, green, Vector3(0.7, 0.4, 0.7))
	_add_lights(approach, _white, Vector3(0.8, 0.5, 0.8))


func _lamp_mat(c: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _add_lights(points: Array[Vector3], mat: StandardMaterial3D, size: Vector3) -> void:
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


func _process(_delta: float) -> void:
	var ac := get_tree().get_first_node_in_group("player_aircraft") as Node3D
	if ac == null:
		return
	var eye := ac.global_position + Vector3.UP * 1.3
	for p in _papi:
		var v: Vector3 = eye - p.pos
		var elev := rad_to_deg(atan2(v.y, Vector2(v.x, v.z).length()))
		var m: StandardMaterial3D = p.mat
		var c := Color(1.0, 0.97, 0.88) if elev > p.angle else Color(1.0, 0.12, 0.08)
		m.albedo_color = c
		m.emission = c
