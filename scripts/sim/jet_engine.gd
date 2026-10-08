extends RefCounted
## One turbofan: core spool (N2) dynamics, thrust curve, afterburner ignition and staging, fuel flow.
## Pure data: safe to run on a server.

var n2 := 0.0               # core speed, % of max
var ab := 0.0               # afterburner stage 0..1
var ab_lit := false
var running := true
var thrust := 0.0           # N, this engine
var fuel_flow := 0.0        # kg/s, this engine
var _ab_timer := 0.0

# parameters (from AircraftSpec)
var idle_n2 := 68.0
var thrust_idle := 2000.0
var thrust_dry := 79400.0
var thrust_ab := 122600.0
var ab_threshold := 0.85
var ab_delay := 0.7          # s from AB request to light
var ab_rate := 0.9           # stage per second
var tau_spool_up := 3.5      # s near idle (fast near max)
var tau_spool_down := 2.2
var tsfc_dry := 1.9e-5       # kg/(N s)
var tsfc_ab := 5.4e-5


func configure(sp) -> void:
	idle_n2 = sp.engine_idle_n2
	thrust_idle = sp.thrust_idle_n
	thrust_dry = sp.thrust_dry_n
	thrust_ab = sp.thrust_ab_n
	ab_threshold = sp.ab_threshold
	ab_delay = sp.ab_ignition_delay
	ab_rate = sp.ab_stage_rate
	tau_spool_up = sp.spool_up_time
	tau_spool_down = sp.spool_down_time
	tsfc_dry = sp.tsfc_dry
	tsfc_ab = sp.tsfc_ab
	n2 = idle_n2


func step(dt: float, throttle: float, has_fuel: bool, density_ratio: float, mach: float) -> void:
	running = has_fuel
	var dry_cmd := clampf(throttle / ab_threshold, 0.0, 1.0)
	var target := (idle_n2 + dry_cmd * (100.0 - idle_n2)) if running else 18.0   # windmilling when dry
	# spool: slow near idle, quicker near the top (like real turbofans)
	var frac := clampf((n2 - idle_n2) / (100.0 - idle_n2), 0.0, 1.0)
	var tau := lerpf(tau_spool_up, tau_spool_up * 0.35, frac) if target > n2 else tau_spool_down
	n2 += (target - n2) * (1.0 - exp(-dt / maxf(tau, 0.05)))
	# afterburner: needs throttle in the AB range and the core near max, lights after a delay, then stages up
	var ab_req := clampf((throttle - ab_threshold) / (1.0 - ab_threshold), 0.0, 1.0) if running else 0.0
	if ab_req > 0.0 and n2 > 96.0:
		if not ab_lit:
			_ab_timer += dt
			if _ab_timer >= ab_delay:
				ab_lit = true
	else:
		ab_lit = false
		_ab_timer = 0.0
	var ab_target := ab_req if ab_lit else 0.0
	ab = move_toward(ab, ab_target, (ab_rate if ab_target > ab else ab_rate * 2.5) * dt)
	# thrust
	var core := clampf((n2 - idle_n2) / (100.0 - idle_n2), 0.0, 1.0)
	var dry := (thrust_idle + (thrust_dry - thrust_idle) * pow(core, 1.6)) if running else 0.0
	if n2 < idle_n2 and running:
		dry = thrust_idle * clampf(n2 / idle_n2, 0.0, 1.0)
	var lapse := clampf(density_ratio, 0.05, 1.0) * (1.0 + 0.25 * clampf(mach, 0.0, 1.8))
	var lapse_ab := clampf(density_ratio, 0.05, 1.0) * (1.0 + 0.55 * clampf(mach, 0.0, 2.0))
	var dry_t := dry * lapse
	var ab_t := (thrust_ab - thrust_dry) * ab * lapse_ab
	thrust = dry_t + ab_t
	fuel_flow = (dry_t * tsfc_dry + ab_t * tsfc_ab) if running else 0.0
