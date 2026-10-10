extends RefCounted
## The pilot's head in the cockpit, moving with the jet the way a body strapped into a seat does (DCS-style "head
## movement by G"). It is what makes the jet feel heavy: the head sinks and settles as you pull, lifts a little as
## you push, swings outward in a skid, is pushed back by the take-off run and the afterburner and thrown forward by
## the brakes, and bumps on touchdown and over the taxiway. Plus the airframe's vibration (buffet near the stall,
## the transonic shudder, the runway's roughness, the afterburner's rumble) felt through the seat.
##
## Model: the specific force the pilot feels (the jet's acceleration minus gravity, in the jet's own axes, in G)
## is low-passed so only body-sized motions get through (turbulence gusts and solver noise never become a jitter
## of the eye: the cockpit is 0.7 m from it, and a millimetre of eye motion per frame shows), and the head
## follows the resulting push on a damped spring (the neck): a short, deliberate lag, a slight overshoot, then it
## settles. Rotation: a small nod under G and a lag against the roll rate. All in the jet's axes, stepped with the
## simulation (120 Hz) and drawn interpolated between steps, so it is as smooth as everything else in the cockpit.
##
## The HUD is collimated (scripts/aircraft/cockpit.gd): its symbols stay on the world while the head moves, and
## the glass and frame move around them, as in a real jet.

const G := 9.80665
# metres of head travel per G of push, beyond the 1 G of sitting still (and the limits the seat and harness allow)
const GAIN := Vector3(0.03, 0.0105, 0.024)            # sideways, up and down, fore and aft (sustained push)
const ONSET := Vector3(0.025, 0.012, 0.03)             # extra for a change in push, which then washes out
const ONSET_TAU := 1.2                                 # s: how long the onset "kick" lasts before it settles
const LIMIT_LO := Vector3(-0.08, -0.09, -0.05)         # left, down (under G), forward (braking: the harness holds)
const LIMIT_HI := Vector3(0.08, 0.045, 0.07)           # right, up (pushing: the canopy is close), back (into the seat)
const NECK_HZ := 1.7                                   # the neck's natural frequency
const NECK_DAMPING := 0.5                              # < 1: the overshoot that reads as weight
const INPUT_HZ := 3.0                                  # only motions slower than this move the head
const NOD_PER_G := 0.7                                 # degrees the head nods forward per G
const ROLL_LAG := 0.03                                 # radians of head roll per rad/s of roll rate (lags the roll)

var amount := 1.0                                      # 0 off, 0.5 reduced, 1 full (setting cockpit/head_motion)
var shake_amount := 1.0                                # setting cockpit/shake

var _pos := Vector3.ZERO                               # head offset now (jet axes, metres)
var _vel := Vector3.ZERO
var _prev_pos := Vector3.ZERO                          # last step's, to interpolate between steps
var _rot := Vector3.ZERO                               # nod (x), roll (z) radians
var _prev_rot := Vector3.ZERO
var _f := Vector3(0.0, 1.0, 0.0)                       # low-passed specific force (G, jet axes)
var _f_slow := Vector3(0.0, 1.0, 0.0)                  # ... and slower still: the difference is the onset
var _last_vel := Vector3.ZERO
var _have := false
var _shake := 0.0                                      # current shake amplitude (degrees) and its character
var _shake_lo := 0.0                                   # share of the low, rough rumble (runway, taxiway)
var _phase := PackedFloat32Array()


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	for i in 12:
		_phase.append(rng.randf() * TAU)


func reset() -> void:
	_pos = Vector3.ZERO
	_vel = Vector3.ZERO
	_prev_pos = Vector3.ZERO
	_rot = Vector3.ZERO
	_prev_rot = Vector3.ZERO
	_f = Vector3(0.0, 1.0, 0.0)
	_f_slow = _f
	_have = false


## One simulation step. fm: the jet's flight model (scripts/sim/flight_model.gd).
func physics_step(dt: float, fm) -> void:
	_prev_pos = _pos
	_prev_rot = _rot
	if fm == null or dt <= 0.0:
		return
	var b: Basis = (fm.rot as Basis).orthonormalized()
	var v: Vector3 = fm.vel
	if not _have:
		_last_vel = v
		_have = true
	var acc := (v - _last_vel) / dt
	_last_vel = v
	var f := b.transposed() * (acc + Vector3(0.0, G, 0.0)) / G
	if f.length() > 15.0 or bool(fm.crashed):
		# a reset, a respawn, a correction from the server or a crash: not something a body would feel
		reset()
		_last_vel = v
		_have = true
		return
	_f = _f.lerp(f, 1.0 - exp(-TAU * INPUT_HZ * dt))
	_f_slow = _f_slow.lerp(_f, 1.0 - exp(-dt / ONSET_TAU))
	var push := _f - Vector3(0.0, 1.0, 0.0)
	# onset: the body feels a change of push most (the "kick" of the take-off roll, of a pull, of the touchdown),
	# then settles to the sustained part (as motion platforms wash out)
	var onset := _f - _f_slow
	# the head moves against the push: sinks under G, back under acceleration, outward in a skid
	var target := -(push * GAIN + onset * ONSET) * amount
	target = target.clamp(LIMIT_LO, LIMIT_HI)
	var w := TAU * NECK_HZ
	_vel += (w * w * (target - _pos) - 2.0 * NECK_DAMPING * w * _vel) * dt
	_pos += _vel * dt
	_pos = _pos.clamp(LIMIT_LO * 1.3, LIMIT_HI * 1.3)
	# a small nod forward under G, and the head lagging behind a roll
	var omega: Vector3 = fm.omega
	var nod := clampf(-push.y * deg_to_rad(NOD_PER_G), deg_to_rad(-3.0), deg_to_rad(1.5)) * amount
	var roll := clampf(-omega.z * ROLL_LAG, deg_to_rad(-2.5), deg_to_rad(2.5)) * amount
	var k := 1.0 - exp(-TAU * NECK_HZ * dt)
	_rot.x += (nod - _rot.x) * k
	_rot.z += (roll - _rot.z) * k
	# vibration through the seat
	var buffet: float = fm.buffet
	var mach: float = fm.mach
	var transonic := smoothstep(0.9, 0.98, mach) * (1.0 - smoothstep(1.02, 1.1, mach))
	var gs := Vector2(v.x, v.z).length()
	var rough := (clampf(gs / 60.0, 0.0, 1.0) * 0.12 + clampf(gs / 15.0, 0.0, 1.0) * 0.05) if bool(fm.wow) else 0.0
	var ab := 0.0
	for e in fm.engines:
		ab = maxf(ab, float(e.ab))
	var brake: float = float(fm.airbrake_pos) * clampf(float(fm.ias) / 200.0, 0.0, 1.0)
	var want := buffet * 0.55 + transonic * 0.16 + rough * 1.3 + ab * 0.035 + brake * 0.07
	_shake += (want - _shake) * (1.0 - exp(-dt / 0.12))
	var lo := rough / maxf(want, 1e-4)
	_shake_lo += (lo - _shake_lo) * (1.0 - exp(-dt / 0.3))


## The head offset (metres) and rotation (radians: x nod, y yaw, z roll) for this rendered frame.
## frac: how far between the last two simulation steps this frame is; t: time (s), for the vibration.
func sample(frac: float, t: float) -> Array:
	var p := _prev_pos.lerp(_pos, frac)
	var r := _prev_rot.lerp(_rot, frac)
	var a := deg_to_rad(_shake) * shake_amount
	if a > 1e-5:
		# airframe vibration: a few incommensurate tones per axis, higher for buffet, lower and rougher on the ground
		var hi := 1.0 - _shake_lo
		var s := Vector3(
			sin(t * TAU * 11.3 + _phase[0]) * 0.6 + sin(t * TAU * 17.9 + _phase[1]) * 0.4,
			sin(t * TAU * 8.7 + _phase[2]) * 0.5 + sin(t * TAU * 13.1 + _phase[3]) * 0.5,
			sin(t * TAU * 9.9 + _phase[4]) * 0.6 + sin(t * TAU * 15.3 + _phase[5]) * 0.4) * hi
		s += Vector3(
			sin(t * TAU * 4.3 + _phase[6]) * 0.5 + sin(t * TAU * 6.9 + _phase[7]) * 0.5,
			sin(t * TAU * 3.7 + _phase[8]) * 0.4 + sin(t * TAU * 7.7 + _phase[9]) * 0.6,
			sin(t * TAU * 5.1 + _phase[10]) * 0.5 + sin(t * TAU * 8.3 + _phase[11]) * 0.5) * _shake_lo
		r += Vector3(s.x, s.z * 0.5, s.y * 0.7) * a
		p += Vector3(s.z, s.x, 0.0) * a * 0.04
	return [p, r]
