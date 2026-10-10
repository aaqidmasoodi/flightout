extends RefCounted
## The weather map on the CPU: the same texture the clouds are drawn from (generated on the GPU by
## shaders/clouds_weather.glsl, read back once), and the same column of weather the GPU works out
## (shaders/include/clouds_common.glslinc, `column`), so what the simulation knows about the clouds (is it raining
## here, where is the deck's top, is the sun hidden) matches what you see.

const WEATHER_SIZE := 409600.0
const CloudGround = preload("res://scripts/world/cloud_ground.gd")

static var ready := false
static var _img: Image
static var _n := 0


static func set_map(img: Image) -> void:
	_img = img
	_n = img.get_width()
	ready = true


## The weather map at a map position (the clouds' drift `wind` already added): r cover, g type, b height, a
## clustering, each 0..1 around 0.5.
static func sample(map_x: float, map_z: float, wind: Vector2) -> Color:
	if not ready:
		return Color(0.5, 0.5, 0.5, 0.5)
	var u := fposmod((map_x + wind.x) / WEATHER_SIZE, 1.0) * _n - 0.5
	var v := fposmod((map_z + wind.y) / WEATHER_SIZE, 1.0) * _n - 0.5
	var i := int(floor(u))
	var j := int(floor(v))
	var fu := u - i
	var fv := v - j
	var c00 := _img.get_pixel(posmod(i, _n), posmod(j, _n))
	var c10 := _img.get_pixel(posmod(i + 1, _n), posmod(j, _n))
	var c01 := _img.get_pixel(posmod(i, _n), posmod(j + 1, _n))
	var c11 := _img.get_pixel(posmod(i + 1, _n), posmod(j + 1, _n))
	return c00.lerp(c10, fu).lerp(c01.lerp(c11, fu), fv)


## The weather column at a map position, as the GPU sees it: {base, top (true heights), cov, type}.
## fx: the clouds' compositor effect (scripts/world/volumetric_clouds.gd), for the preset and the drift.
static func column(map_x: float, map_z: float, fx) -> Dictionary:
	var w := sample(map_x, map_z, fx.wind)
	var var_k: float = fx.variability
	var type := clampf(float(fx.stratus) + (w.g - 0.5) * 0.9 * var_k, 0.0, 1.0)
	var cov := float(fx.coverage) + (w.r - 0.5) * 0.5 * var_k + (w.a - 0.5) * 0.4 * var_k * (1.0 - type)
	var g2: Vector2 = CloudGround.at(map_x, map_z)
	var g := lerpf(g2.x, g2.y, float(fx.ground_mix))
	var hv := (w.b - 0.5) * float(fx.height_variation)
	var base := g + float(fx.base) + hv
	var depth := maxf(float(fx.top) - float(fx.base), 60.0)
	var tower := lerpf(lerpf(0.55, 1.3, w.a), 1.0, type)
	var top := base + depth * tower + hv * 0.4 * (1.0 - type)
	return {"base": base, "top": top, "cov": pow(clampf(cov, 0.0, 1.0), 1.5), "type": type}
