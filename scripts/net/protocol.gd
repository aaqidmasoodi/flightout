extends RefCounted
## FlightOut network protocol. Binary, versioned, little-endian, built on ENet (UDP).
##
## Model: server-authoritative with client-side prediction.
##   Client -> server: numbered input commands, 120 per second, sent 60 times a second with redundancy.
##   Server -> client: snapshots 30 times a second: every jet (compact) plus the recipient's own full state
##                     and the last input tick the server applied for it (for reconciliation).
## Channel 0 carries unreliable state (inputs, snapshots); channel 1 carries reliable events (join, leave, weather).

const VERSION := 4                     # 2: avionics master mode in the input toggles and the state; 3: floating origin (jet frames); 4: Kashmir map, slots at three airfields
const DEFAULT_PORT := 27015
const MAX_PLAYERS := 16
const TICK_RATE := 120                 # simulation ticks per second (2 substeps each = 240 Hz physics)
const TICK_DT := 1.0 / 120.0
const SUBSTEPS := 2
const SNAPSHOT_EVERY := 4              # server sends a snapshot every 4 ticks (30 Hz)
const INPUT_SEND_EVERY := 2            # client sends inputs every 2 ticks (60 Hz)
const INPUT_REDUNDANCY := 10           # each input packet repeats the last 10 ticks: survives 4 lost packets in a row
const CH_STATE := 0
const CH_EVENTS := 1
const CHANNELS := 2

## Official FlightOut servers, shown first on the Multiplayer screen (a server list service will replace this).
const OFFICIAL_SERVERS := [
	{"name": "FlightOut London", "region": "Europe  ·  London", "address": "play.flightout.app"},
]

enum {
	C_HELLO = 1, C_INPUT = 2, C_BYE = 3, C_INFO = 4,
	S_WELCOME = 64, S_REJECT = 65, S_JOIN = 66, S_LEAVE = 67, S_SNAPSHOT = 68, S_WEATHER = 69, S_INFO = 70,
}


# ------------------------------------------------------------------ input commands
## An input command: [tick, pitch, roll, yaw, throttle, brake, toggles]. Axis values are always the
## dequantised network values, so the client predicts with exactly what the server will apply.

static func make_cmd(tick: int, pitch: float, roll: float, yaw: float, throttle: float, brake: float, toggles: int) -> Array:
	return [tick, _axis(pitch), _axis(roll), _axis(yaw), roundf(clampf(throttle, 0.0, 1.0) * 65535.0) / 65535.0,
		roundf(clampf(brake, 0.0, 1.0) * 255.0) / 255.0, toggles & 0x3FFFFFF]


static func _axis(v: float) -> float:
	return roundf(clampf(v, -1.0, 1.0) * 32767.0) / 32767.0


static func encode_input(cmds: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(C_INPUT)
	b.put_u32(cmds[0][0])
	b.put_u8(cmds.size())
	for c in cmds:
		b.put_16(roundi(c[1] * 32767.0))
		b.put_16(roundi(c[2] * 32767.0))
		b.put_16(roundi(c[3] * 32767.0))
		b.put_u16(roundi(c[4] * 65535.0))
		b.put_u8(roundi(c[5] * 255.0))
		b.put_u32(c[6])
	return b.data_array


static func decode_input(b: StreamPeerBuffer) -> Array:
	var first := b.get_u32()
	var n := b.get_u8()
	var out := []
	for i in n:
		if b.get_available_bytes() < 13:
			break
		var pitch := b.get_16() / 32767.0
		var roll := b.get_16() / 32767.0
		var yaw := b.get_16() / 32767.0
		var thr := b.get_u16() / 65535.0
		var brk := b.get_u8() / 255.0
		var tog := b.get_u32()
		out.append([first + i, pitch, roll, yaw, thr, brk, tog])
	return out


# ------------------------------------------------------------------ full state (owner only)
## FlightModel.get_state() as a tagged list. Floats travel as 32-bit, which is what Vector3/Basis hold anyway.

static func put_state(b: StreamPeerBuffer, s: Array) -> void:
	b.put_u8(s.size())
	for v in s:
		_put_val(b, v)


static func _put_val(b: StreamPeerBuffer, v) -> void:
	match typeof(v):
		TYPE_FLOAT:
			b.put_u8(1); b.put_float(v)
		TYPE_BOOL:
			b.put_u8(2 if v else 3)
		TYPE_INT:
			b.put_u8(4); b.put_64(v)
		TYPE_VECTOR3:
			b.put_u8(5); b.put_float(v.x); b.put_float(v.y); b.put_float(v.z)
		TYPE_BASIS:
			b.put_u8(6)
			for c in [v.x, v.y, v.z]:
				b.put_float(c.x); b.put_float(c.y); b.put_float(c.z)
		TYPE_ARRAY:
			b.put_u8(7); b.put_u8(v.size())
			for e in v:
				_put_val(b, e)
		_:
			b.put_u8(0)


static func get_state(b: StreamPeerBuffer) -> Array:
	var n := b.get_u8()
	var out := []
	for i in n:
		out.append(_get_val(b))
	return out


static func _get_val(b: StreamPeerBuffer):
	match b.get_u8():
		1: return b.get_float()
		2: return true
		3: return false
		4: return b.get_64()
		5: return Vector3(b.get_float(), b.get_float(), b.get_float())
		6:
			var x := Vector3(b.get_float(), b.get_float(), b.get_float())
			var y := Vector3(b.get_float(), b.get_float(), b.get_float())
			var z := Vector3(b.get_float(), b.get_float(), b.get_float())
			return Basis(x, y, z)
		7:
			var n := b.get_u8()
			var a := []
			for i in n:
				a.append(_get_val(b))
			return a
	return null


# ------------------------------------------------------------------ compact jet (everyone else)
## About 64 bytes a jet: exact position and velocity, quantised orientation, rates and surfaces.

const FLAG_GEAR := 1
const FLAG_WOW := 2
const FLAG_FLAPS := 4
const FLAG_AIRBRAKE := 8
const FLAG_CRASHED := 16
const FLAG_CANOPY := 32
const FLAG_LIGHTS := 64
const FLAG_RADAR := 128
const FLAG_RADOME := 256

## sim_tick: how many ticks this jet has been simulated. Remote jets are timed by it (not the server tick),
## so a jet whose inputs arrived late, then caught up, still moves perfectly evenly on other screens.
static func put_jet(b: StreamPeerBuffer, id: int, sim_tick: int, fm) -> void:
	b.put_u8(id)
	b.put_u32(sim_tick)
	b.put_32(roundi(fm.ox)); b.put_32(roundi(fm.oz))     # the jet's frame (whole ORIGIN_CELLs, exact as ints)
	b.put_float(fm.pos.x); b.put_float(fm.pos.y); b.put_float(fm.pos.z)
	b.put_float(fm.vel.x); b.put_float(fm.vel.y); b.put_float(fm.vel.z)
	var q: Quaternion = fm.rot.get_rotation_quaternion()
	if q.w < 0.0:
		q = -q
	b.put_16(roundi(q.x * 32767.0)); b.put_16(roundi(q.y * 32767.0)); b.put_16(roundi(q.z * 32767.0)); b.put_16(roundi(q.w * 32767.0))
	b.put_16(roundi(clampf(fm.omega.x, -7.9, 7.9) * 4096.0))
	b.put_16(roundi(clampf(fm.omega.y, -7.9, 7.9) * 4096.0))
	b.put_16(roundi(clampf(fm.omega.z, -7.9, 7.9) * 4096.0))
	var e0 = fm.engines[0] if fm.engines.size() > 0 else null
	b.put_u8(clampi(roundi((e0.n2 if e0 else 0.0) * 2.0), 0, 255))
	b.put_u8(clampi(roundi((e0.ab if e0 else 0.0) * 255.0), 0, 255))
	b.put_u8(roundi(fm.gear_pos * 255.0))
	b.put_u8(roundi(fm.flap_pos * 255.0))
	b.put_u8(roundi(fm.airbrake_pos * 255.0))
	b.put_8(clampi(roundi(rad_to_deg(fm.elev) * 3.0), -127, 127))
	b.put_8(clampi(roundi(rad_to_deg(fm.ail) * 3.0), -127, 127))
	b.put_8(clampi(roundi(rad_to_deg(fm.rud) * 3.0), -127, 127))
	b.put_8(clampi(roundi(rad_to_deg(fm.steer) * 1.5), -127, 127))
	for i in 3:
		b.put_u8(clampi(roundi(float(fm.gear_comp[i]) * 500.0), 0, 255))
	var f := 0
	if fm.gear_down: f |= FLAG_GEAR
	if fm.wow: f |= FLAG_WOW
	if fm.flaps: f |= FLAG_FLAPS
	if fm.airbrake: f |= FLAG_AIRBRAKE
	if fm.crashed: f |= FLAG_CRASHED
	if fm.canopy_open: f |= FLAG_CANOPY
	if fm.lights_on: f |= FLAG_LIGHTS
	if fm.radar_on: f |= FLAG_RADAR
	if fm.radome_open: f |= FLAG_RADOME
	b.put_u16(f)


static func get_jet(b: StreamPeerBuffer) -> Dictionary:
	var d := {}
	d.id = b.get_u8()
	d.t = b.get_u32()
	d.ox = float(b.get_32())
	d.oz = float(b.get_32())
	d.pos = Vector3(b.get_float(), b.get_float(), b.get_float())     # in the jet's frame: world = pos + (ox, 0, oz)
	d.vel = Vector3(b.get_float(), b.get_float(), b.get_float())
	d.rot = Quaternion(b.get_16() / 32767.0, b.get_16() / 32767.0, b.get_16() / 32767.0, b.get_16() / 32767.0).normalized()
	d.omega = Vector3(b.get_16() / 4096.0, b.get_16() / 4096.0, b.get_16() / 4096.0)
	d.n2 = b.get_u8() / 2.0
	d.ab = b.get_u8() / 255.0
	d.gear_pos = b.get_u8() / 255.0
	d.flap_pos = b.get_u8() / 255.0
	d.airbrake_pos = b.get_u8() / 255.0
	d.elev = deg_to_rad(b.get_8() / 3.0)
	d.ail = deg_to_rad(b.get_8() / 3.0)
	d.rud = deg_to_rad(b.get_8() / 3.0)
	d.steer = deg_to_rad(b.get_8() / 1.5)
	d.comp = [b.get_u8() / 500.0, b.get_u8() / 500.0, b.get_u8() / 500.0]
	d.flags = b.get_u16()
	return d


# ------------------------------------------------------------------ weather and small helpers

static func put_weather(b: StreamPeerBuffer, w: Dictionary) -> void:
	b.put_float(w.wind_from); b.put_float(w.wind_speed); b.put_float(w.turbulence)
	b.put_u32(w.seed); b.put_float(w.time); b.put_float(w.time_scale); b.put_u8(w.conditions)


static func get_weather(b: StreamPeerBuffer) -> Dictionary:
	return {"wind_from": b.get_float(), "wind_speed": b.get_float(), "turbulence": b.get_float(),
		"seed": b.get_u32(), "time": b.get_float(), "time_scale": b.get_float(), "conditions": b.get_u8()}


static func reader(data: PackedByteArray) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	return b
