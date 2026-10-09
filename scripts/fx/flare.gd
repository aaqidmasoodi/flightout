extends Node3D
## A decoy flare: a burning pellet thrown out of the jet, falling and slowing hard in the air, glowing for a few
## seconds and leaving a smoke trail that shows its arc (scripts/fx/trail.gd). Visual only for now: the seeker logic
## that decoys missiles comes with the weapons. Follows the floating origin like everything in scene space.

const BURN := 4.5                  # s
const DRAG := 0.9                  # 1/s: a flare loses most of the jet's speed within a couple of seconds
const SMOKE := {"lifetime": 10.0, "sample": 0.05, "width": 0.5, "growth": 1.3, "fade_in": 0.05,
	"color": Color(0.95, 0.95, 0.96), "opacity": 0.8, "wisp": 0.5, "self_lit": 0.35}

var _vel := Vector3.ZERO
var _t := 0.0
var _glow: MeshInstance3D
var _mat: StandardMaterial3D


## Thrown from `pos` (scene) with the launcher's velocity plus an ejection kick.
func launch(pos: Vector3, vel: Vector3) -> void:
	global_position = pos
	_vel = vel
	_glow = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(1.4, 1.4)
	_glow.mesh = q
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.albedo_texture = _dot()
	_mat.albedo_color = Color(1.0, 0.85, 0.55)
	_mat.emission_enabled = false
	_mat.disable_receive_shadows = true
	_glow.material_override = _mat
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glow)
	WorldData.origin_shifted.connect(func(d: Vector3):
		global_position -= d
		reset_physics_interpolation())
	preload("res://scripts/fx/trail.gd").attach(self, Vector3.ZERO, SMOKE, func(): return 1.0 if _t < BURN else 0.0)


func _physics_process(delta: float) -> void:
	_t += delta
	if _t > BURN + 0.3:
		queue_free()
		return
	_vel += Vector3(0.0, -9.81, 0.0) * delta
	_vel *= exp(-DRAG * delta)
	global_position += _vel * delta
	# a burning flare flickers and dies down at the end
	var k := 1.0 - smoothstep(BURN - 0.8, BURN, _t)
	_mat.albedo_color = Color(1.0, 0.85, 0.55) * (2.2 + 0.9 * sin(_t * 47.0) * sin(_t * 31.0)) * k


static var _dot_tex: Texture2D

## A soft round glow.
static func _dot() -> Texture2D:
	if _dot_tex:
		return _dot_tex
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.18, Color(1, 1, 1, 0.9))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_dot_tex = t
	return t
