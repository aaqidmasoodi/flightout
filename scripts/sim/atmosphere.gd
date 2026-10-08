extends RefCounted
## International Standard Atmosphere + wind field + turbulence. Pure data: safe to run on a server.
## World convention: north is -Z, east is +X, up is +Y.

const R := 287.053          # J/(kg K), dry air
const GAMMA := 1.4
const G0 := 9.80665
const T0 := 288.15          # K, sea level
const P0 := 101325.0        # Pa, sea level
const RHO0 := 1.225         # kg/m^3, sea level
const LAPSE := 0.0065       # K/m, troposphere
const TROPOPAUSE := 11000.0

var wind_from_deg := 0.0    # meteorological: direction the wind blows FROM (0 = north)
var wind_speed := 0.0       # m/s at 10 m above the surface
var turbulence := 0.0       # 0..1 intensity
var seed := 1


static func temperature(h: float) -> float:
	return T0 - LAPSE * clampf(h, -500.0, TROPOPAUSE) if h < TROPOPAUSE else 216.65


static func pressure(h: float) -> float:
	if h < TROPOPAUSE:
		return P0 * pow(temperature(h) / T0, G0 / (LAPSE * R))
	var p11 := P0 * pow(216.65 / T0, G0 / (LAPSE * R))
	return p11 * exp(-G0 * (h - TROPOPAUSE) / (R * 216.65))


static func density(h: float) -> float:
	return pressure(h) / (R * temperature(h))


static func speed_of_sound(h: float) -> float:
	return sqrt(GAMMA * R * temperature(h))


## Wind vector (where the air moves TO) at a point and time: boundary-layer profile + turbulence.
func wind_at(p: Vector3, t: float, ground_h: float) -> Vector3:
	var agl := maxf(p.y - ground_h, 0.0)
	var w := Vector3.ZERO
	if wind_speed > 0.0:
		var profile := pow(clampf(agl, 1.0, 600.0) / 10.0, 0.14) * (1.0 + clampf((p.y - 600.0) / 9000.0, 0.0, 1.0) * 0.8)
		var to := deg_to_rad(wind_from_deg + 180.0)
		w = Vector3(sin(to), 0.0, -cos(to)) * wind_speed * profile
	if turbulence > 0.0:
		# smooth deterministic field: a few incommensurate waves in space and time (stronger close to the ground)
		var s := float(seed)
		var x := p.x * 0.011 + s
		var y := p.y * 0.017 - s * 0.5
		var z := p.z * 0.013 + s * 1.7
		var g := Vector3(
			sin(x + t * 0.9) * 0.6 + sin(z * 2.3 - t * 1.7) * 0.4,
			sin(y * 1.9 + t * 1.3) * 0.5 + sin(x * 2.9 + z - t * 2.1) * 0.5,
			sin(z + t * 1.1) * 0.6 + sin(x * 2.1 + t * 1.9) * 0.4)
		var near_ground := 1.0 + 0.8 * (1.0 - clampf(agl / 800.0, 0.0, 1.0))
		w += g * turbulence * (2.5 + wind_speed * 0.25) * near_ground
	return w
