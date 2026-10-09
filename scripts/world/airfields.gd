extends Node3D
## Runways of a large map's airfields (data/maps/<map>/airfields.json, built by tools/build_airfields.py from
## OurAirports). Each runway is drawn on the terrain, which tools/build_kashmir.py has levelled to the runway's
## straight profile, with the procedural runway shader (markings, designators from the runway's own numbers).
## A child of the World node: it moves with the floating origin.

const RUNWAY_SHADER := preload("res://shaders/runway.gdshader")
const LIFT := 0.12                 # above the levelled ground


func build(fields: Array) -> void:
	var tex: Dictionary = preload("res://scripts/world/surface_materials.gd").terrain_textures()
	for a in fields:
		var site := Node3D.new()
		site.name = String(a.id)
		add_child(site)
		for r in a.runways:
			_runway(site, r, tex)


func _runway(site: Node3D, r: Dictionary, tex: Dictionary) -> void:
	var A := Vector3(r.a[0], r.a[1], r.a[2])
	var B := Vector3(r.b[0], r.b[1], r.b[2])
	var flat := Vector3(B.x - A.x, 0.0, B.z - A.z)
	var length := flat.length()
	var u := flat / length
	var side := Vector3(-u.z, 0.0, u.x)             # to the right when looking from A towards B
	var hw: float = float(r.width) * 0.5
	var lift := Vector3(0.0, LIFT, 0.0)
	# vertices relative to the runway's start (small numbers: precise), quads every ~100 m along the length
	var n := maxi(1, int(length / 100.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in n:
		var t0 := float(k) / n
		var t1 := float(k + 1) / n
		var p0 := (B - A) * t0 + lift
		var p1 := (B - A) * t1 + lift
		var v := [p0 + side * hw, p0 - side * hw, p1 + side * hw, p1 - side * hw]
		var uv := [Vector2(0.0, t0), Vector2(1.0, t0), Vector2(0.0, t1), Vector2(1.0, t1)]
		for i in [0, 1, 2, 1, 3, 2]:          # clockwise seen from above (front faces)
			st.set_normal(Vector3.UP)
			st.set_uv(uv[i])
			st.add_vertex(v[i])
	var mi := MeshInstance3D.new()
	mi.name = "Runway_%s_%s" % [r.ids[0], r.ids[1]]
	mi.mesh = st.commit()
	mi.position = A
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = RUNWAY_SHADER
	m.set_shader_parameter("detail_tex", tex.detail)
	m.set_shader_parameter("width_m", float(r.width))
	m.set_shader_parameter("length_m", length)
	m.set_shader_parameter("start_digits", _digits(String(r.ids[0])))
	m.set_shader_parameter("end_digits", _digits(String(r.ids[1])))
	mi.material_override = m
	site.add_child(mi)


## "07L" -> (0, 7); "13" -> (1, 3)
static func _digits(id: String) -> Vector2i:
	var num := ""
	for c in id:
		if c >= "0" and c <= "9":
			num += c
	var v := clampi(num.to_int(), 1, 36)
	return Vector2i(v / 10, v % 10)
