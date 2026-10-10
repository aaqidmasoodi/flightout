extends Node
## Condensation an aircraft leaves in the air (scripts/fx/trail.gd ribbons), driven by what the aircraft is doing:
##   - wingtip vortices: thin white lines from the wingtips when the wing pulls hard (high G or high angle of
##     attack). The low pressure in the tip vortex condenses the water in the air, so they show more in humid air
##     and lower down, hardly at all in dry, thin air, and never in gentle flight.
##   - vapour over the wing roots: the Su-27's big LERX vortices fill with vapour in hard pulls and at high
##     alpha, a short wide sheet right over the wing that is gone a few metres behind the jet.
##   - engine contrails: when the air is cold enough (about -40 C and below, roughly 9 km and up in standard air) the
##     exhaust's water freezes into long white trails that stay for tens of seconds and spread with time. They are
##     what shows a jet miles away at altitude.
## Everything reads the aircraft's own readouts (G, alpha, speed, altitude, engine), which remote jets estimate from
## their motion, so other players' jets show the same. Settings: graphics/vapour.

## Every trail is a preset of the same ribbon (scripts/fx/trail.gd). Lifetimes from how the real things behave:
##   - contrails (FAA / EPA contrail fact sheet): in dry air the ice evaporates as the exhaust mixes, and the trail is
##     gone within seconds to a minute or so (short-lived); only in ice-supersaturated air do they persist for
##     minutes to hours and spread. So the lifetime follows the weather: clear skies give a trail a few kilometres
##     long that dissolves behind the jet, an overcast, humid sky a long persistent one (CONTRAIL_LIFE).
##   - missile smoke: the motor burns only a few seconds (about 2 s for an R-73, 5 to 8 s for longer range missiles)
##     but the smoke it leaves hangs in the air much longer, dense and white at first, then thinning and spreading.
##     It is what you see of a missile, so it must read clearly against the sky (whiter, self-lit).
const VORTEX := {"lifetime": 1.4, "sample": 0.025, "width": 0.3, "growth": 0.5, "fade_in": 0.03,
	"color": Color(0.97, 0.98, 1.0), "opacity": 0.6, "wisp": 0.55, "self_lit": 0.2}
const LERX := {"lifetime": 0.07, "sample": 0.012, "width": 1.0, "growth": 38.0, "fade_in": 0.0,
	"color": Color(0.97, 0.98, 1.0), "opacity": 0.35, "wisp": 0.8, "self_lit": 0.2}
const CONTRAIL := {"lifetime": 20.0, "sample": 0.2, "width": 1.6, "growth": 0.9, "fade_in": 0.18,
	"color": Color(0.97, 0.98, 1.0), "opacity": 0.7, "wisp": 0.35, "self_lit": 0.1, "ab_glow": true}
## contrail lifetime (s) by weather: clear, scattered, broken, overcast, fog, rain (drier air: shorter trails)
const CONTRAIL_LIFE := [12.0, 20.0, 35.0, 70.0, 30.0, 50.0]
## Missile motor smoke: dense and white near the missile, hanging for half a minute while it thins and spreads.
const SMOKE := {"lifetime": 35.0, "sample": 0.08, "width": 1.2, "growth": 1.0, "fade_in": 0.0,
	"color": Color(0.95, 0.95, 0.96), "opacity": 0.95, "wisp": 0.35, "self_lit": 0.35}

## Emitters in the model's own coordinates (Su-27: +X left wing, +Z nose), from its light and nozzle empties.
const POINTS := {"su27": {
	"tips": [Vector3(7.35, -0.3, -4.9), Vector3(-7.35, -0.3, -4.9)],
	"lerx": [Vector3(1.9, 0.45, -1.2), Vector3(-1.9, 0.45, -1.2)],
	"nozzles": [Vector3(1.25, -0.44, -9.6), Vector3(-1.25, -0.44, -9.6)]}}

var aircraft: Node3D
var _trails: Array = []
var _on := true


func setup(ac: Node3D, model: Node3D) -> void:
	aircraft = ac
	var id := String(ac.spec.id) if ac.get("spec") != null and ac.spec != null else "su27"
	var pts: Dictionary = POINTS.get(id, POINTS.su27)
	# model space -> aircraft space (the model is turned around inside the aircraft node)
	var m := model.transform
	for p in pts.tips:
		_trails.append(load("res://scripts/fx/trail.gd").attach(ac, m * p, VORTEX, _vortex))
	for p in pts.lerx:
		_trails.append(load("res://scripts/fx/trail.gd").attach(ac, m * p, LERX, _lerx))
	var con := CONTRAIL.duplicate()
	con.lifetime = CONTRAIL_LIFE[clampi(WorldData.conditions, 0, 5)]
	for p in pts.nozzles:
		_trails.append(load("res://scripts/fx/trail.gd").attach(ac, m * p, con, _contrail))
	Settings.changed.connect(func(_k, _v): _on = bool(Settings.get_value("graphics/vapour")))
	_on = bool(Settings.get_value("graphics/vapour"))


func _exit_tree() -> void:
	# the jet is going (respawn, disconnect): its trails fade out on their own (their anchor is gone)
	pass


## How readily vapour condenses: humid weather and low altitude more, dry thin air high up less.
func _humidity() -> float:
	var w := [0.55, 0.7, 0.85, 1.0, 1.25, 1.3]
	var base: float = w[clampi(WorldData.conditions, 0, 5)]
	var alt: float = WorldData.to_world(aircraft.global_position).y
	return base * (1.0 - 0.55 * smoothstep(3000.0, 11000.0, alt))


func _vortex() -> float:
	if not _on or aircraft.crashed or aircraft.speed < 70.0:
		return 0.0
	var g := absf(float(aircraft.g_load))
	var aoa := float(aircraft.aoa_deg)
	var lift := maxf(smoothstep(3.2, 7.0, g), smoothstep(13.0, 24.0, aoa) * 0.8)
	return clampf(lift * _humidity(), 0.0, 1.0)


func _lerx() -> float:
	if not _on or aircraft.crashed or aircraft.speed < 70.0:
		return 0.0
	var g := absf(float(aircraft.g_load))
	var aoa := float(aircraft.aoa_deg)
	var lift := maxf(smoothstep(5.0, 8.5, g), smoothstep(17.0, 28.0, aoa))
	return clampf(lift * _humidity() * 1.1, 0.0, 1.0)


func _contrail() -> float:
	if not _on or aircraft.crashed or aircraft.speed < 60.0:
		return 0.0
	var alt: float = WorldData.to_world(aircraft.global_position).y
	var t_c: float = preload("res://scripts/sim/atmosphere.gd").temperature(alt) - 273.15
	# Appleman: persistent contrails below about -40 C; a short faint band above that
	var cold := smoothstep(-36.0, -46.0, t_c)
	return cold * (0.55 + 0.45 * clampf(float(aircraft.engine), 0.0, 1.0))
