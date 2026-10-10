extends Node
## Network client (child of the Game autoload, so it survives scene changes).
##
## Your jet: predicted. Every tick its input command is applied here at once and kept with the resulting state.
## When a snapshot says which of our ticks the server has applied, our state for that tick is compared with the
## server's; if they differ, the jet rewinds to the server state and replays the inputs since (Aircraft.rewind),
## and the difference is blended out of the view so nothing jumps.
##
## Other jets, as DCS does it: drawn at the present moment, predicted forward from their latest snapshot (dead
## reckoning with velocity, acceleration and turn rates: aircraft move predictably, so the prediction is close), and
## every new snapshot is blended in over a fraction of a second (projective velocity blending) instead of snapping
## to it, so corrections never show as jumps or shaking. They are placed every simulation tick like our own jet, and
## the engine's physics interpolation draws both between ticks with the same fraction: in close formation the two
## jets move together at 170 m/s, so any difference in timing between them would show directly on screen.

signal joined
signal failed(reason: String)
signal disconnected(reason: String)
signal roster_changed

const P := preload("res://scripts/net/protocol.gd")
const Link := preload("res://scripts/net/link.gd")
const AircraftScript := preload("res://scripts/aircraft/aircraft.gd")
const SPEC := "res://data/aircraft/su27.tres"
const HISTORY := 360                 # ticks of inputs and states kept (3 s)
const BLEND_TIME := 0.25            # s over which a new snapshot is blended into the jet as shown
const MAX_PREDICT := 2.0             # s a jet is predicted past its newest snapshot (a stalled stream) before it holds
const ACCEL_TIME := 0.5              # s of prediction that use the acceleration; beyond, velocity only (stays sane)
const SNAP_DISTANCE := 200.0         # m: further than this from where it is shown (a respawn), the jet is moved at once
const MAX_HORIZON := 60.0            # ticks (0.5 s): never predicted further ahead than this (a very bad connection)
const CONNECT_TIMEOUT := 8.0

enum { IDLE, CONNECTING, ONLINE }

var state := IDLE
var link: Link
var peer: ENetPacketPeer
var my_id := 0
var my_slot := 0
var server_name := ""
var server_address := ""
var roster := {}                     # id -> {"name", "slot"}
var aircraft: Node3D                 # our predicted jet (set by the flight scene)
var world_root: Node3D               # where remote jets are created (set by the flight scene)

# prediction
var tick := 0
var _cmds := {}
var _states := {}
var _send_counter := 0
var _last_ack := 0

# remote jets: id -> {"node", "snaps": [[jet tick, data]], the clock, the prediction and the blend (see _predict)}
var _remotes := {}
var _offset := 0.0                   # server tick minus local clock (in ticks)
var _have_clock := false
var _jitter := 1.0                   # ticks
var interp_delay := 0.0              # ticks the remote jets are predicted ahead of their newest snapshot (stats)
# the network delay, measured in simulation ticks from our own inputs and the server's acknowledgements (so it
# includes everything: both trips, the server's input buffer, and any simulated lag), see _measure
var trip_ticks := 0.0                # round trip, smoothed
var lead_ticks := 0.0                # how far our own jet runs ahead of the server's simulation of it, smoothed
var _have_trip := false
var _no_lead := "--net-no-lead" in OS.get_cmdline_user_args()   # development: ignore the owners' leads (to compare)

# stats for the optional overlay
var rtt_ms := 0.0
var loss_pct := 0.0
var corrections := 0
var rewind_ms := 0.0                 # total time spent re-simulating after corrections
var rewind_max_ms := 0.0             # the longest single correction (one frame's worth of replay)
var snap_log: PackedStringArray      # development (scripts/dev/formation.gd): every remote snapshot as it arrives
var log_snaps := false
var server_queue := 0
var kbps_in := 0.0
var kbps_out := 0.0
var _stat_t := 0.0
var _last_in := 0
var _last_out := 0
var _deadline := 0.0
var _reason := ""


var _log: FileAccess                 # development: --netlog=file.csv records how remote jets are shown each frame


func _ready() -> void:
	name = "NetClient"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--netlog="):
			_log = FileAccess.open(arg.trim_prefix("--netlog="), FileAccess.WRITE)
	process_physics_priority = 100   # after the jet has simulated this tick
	process_priority = -10           # remote jets are placed before the camera reads anything
	WorldData.origin_shifted.connect(_on_origin_shifted)


## The scene origin moved (our jet crossed a cell): everything kept in scene coordinates moves with it.
func _on_origin_shifted(delta: Vector3) -> void:
	for id in _remotes:
		var r: Dictionary = _remotes[id]
		for sn in r.snaps:
			sn[1].pos = (sn[1].pos as Vector3) - delta
		r.shown_p = (r.shown_p as Vector3) - delta
		r.b_p = (r.b_p as Vector3) - delta
		if is_instance_valid(r.node):
			# moved now, interpolation reset after this tick's placement (_physics_process), as for our own jet
			(r.node as Node3D).global_position -= delta
			r.reset = true


var online: bool:
	get: return state == ONLINE


func _now_ticks() -> float:
	return Time.get_ticks_usec() / 1e6 * P.TICK_RATE


## The simulation clock in ticks (the current physics step).
func _sim_now() -> float:
	return float(Engine.get_physics_frames())


# ------------------------------------------------------------------ connection

## address: "host" or "host:port"
func connect_to(address: String, callsign: String) -> void:
	disconnect_from_server("")
	var host := address.strip_edges()
	var port := P.DEFAULT_PORT
	var colon := host.rfind(":")
	if colon > 0 and host.count(":") == 1:
		port = host.substr(colon + 1).to_int()
		host = host.substr(0, colon)
	if host == "":
		host = "127.0.0.1"
	server_address = "%s:%d" % [host, port]
	link = Link.new()
	if link.host.create_host(1, P.CHANNELS) != OK:
		failed.emit("Could not open a network socket.")
		return
	link.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	peer = link.host.connect_to_host(host, port, P.CHANNELS)
	if peer == null:
		failed.emit("Could not resolve %s." % host)
		link = null
		return
	set_meta("callsign", callsign)
	state = CONNECTING
	_deadline = Time.get_ticks_msec() / 1000.0 + CONNECT_TIMEOUT


func disconnect_from_server(reason: String = "") -> void:
	if state == IDLE and link == null:
		return
	if state == ONLINE:
		print("Net: leaving after %d corrections (longest %.1f ms), ping %d ms, loss %.1f%%%s" % [corrections, rewind_max_ms,
			int(rtt_ms), loss_pct, ("  (" + reason + ")") if reason != "" else ""])
	var was_online := state == ONLINE
	if peer and link:
		var b := StreamPeerBuffer.new()
		b.put_u8(P.C_BYE)
		peer.send(P.CH_EVENTS, b.data_array, ENetPacketPeer.FLAG_RELIABLE)
		link.host.flush()
		peer.peer_disconnect()
		link.host.flush()
	if link:
		link.close()
	link = null
	peer = null
	state = IDLE
	_cmds.clear()
	_states.clear()
	for id in _remotes.keys():
		_remove_remote(id)
	roster.clear()
	_have_clock = false
	_have_trip = false
	trip_ticks = 0.0
	lead_ticks = 0.0
	_last_ack = 0
	_own_ack = 0
	_own_state = []
	tick = 0
	aircraft = null
	WorldData.clear_server_weather()
	if was_online and reason != "":
		disconnected.emit(reason)


# ------------------------------------------------------------------ per tick

func _physics_process(_delta: float) -> void:
	if link == null:
		return
	_service()
	_reconcile_newest()
	if state == CONNECTING and Time.get_ticks_msec() / 1000.0 > _deadline:
		disconnect_from_server("")
		failed.emit("No answer from %s. Check the address, and that the server is running and reachable (UDP %d)." % [server_address, P.DEFAULT_PORT])
		return
	if link:
		link.pump()
	if state == ONLINE:
		# other jets: placed on this tick, drawn between ticks by physics interpolation like our own
		var now := _sim_now()
		for id in _remotes.keys():
			var r: Dictionary = _remotes[id]
			if not is_instance_valid(r.node):
				_remotes.erase(id)
				continue
			if r.snaps.is_empty():
				continue
			_predict(r, now)
			if not r.placed or r.reset:
				# first placement, or the scene origin moved this tick: our own jet is drawn without
				# interpolation on this tick (aircraft.gd resets it after placing), so this one is too
				r.placed = true
				r.reset = false
				(r.node as Node3D).reset_physics_interpolation()


## The predicted jet asks for its tick number, then hands back the command it applied and the state it reached.
func next_tick() -> int:
	tick += 1
	return tick


func record(cmd: Array, s: Array) -> void:
	var t: int = cmd[0]
	_cmds[t] = cmd
	_states[t] = s
	_cmds.erase(t - HISTORY)
	_states.erase(t - HISTORY)
	_send_counter += 1
	if _send_counter >= P.INPUT_SEND_EVERY and state == ONLINE:
		_send_counter = 0
		var batch := []
		for k in range(maxi(t - P.INPUT_REDUNDANCY + 1, _last_ack + 1), t + 1):
			if _cmds.has(k):
				batch.append(_cmds[k])
		if not batch.is_empty():
			link.send(peer, P.CH_STATE, P.encode_input(batch, lead_ticks), false)


func _service() -> void:
	for guard in 256:
		if link == null:
			return
		var ev: Array = link.host.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE:
			break
		if type == ENetConnection.EVENT_ERROR:
			disconnect_from_server("Network error.")
			return
		match type:
			ENetConnection.EVENT_CONNECT:
				peer.set_timeout(0, 4000, 8000)
				var b := StreamPeerBuffer.new()
				b.put_u8(P.C_HELLO)
				b.put_u16(P.VERSION)
				b.put_utf8_string(String(get_meta("callsign", "")))
				link.send(peer, P.CH_EVENTS, b.data_array, true)
			ENetConnection.EVENT_DISCONNECT:
				var was := state
				var why := _reason if _reason != "" else ("Connection to the server was lost." if was == ONLINE else "")
				_reason = ""
				disconnect_from_server(why)
				if was == CONNECTING:
					failed.emit(why if why != "" else "The server closed the connection.")
				return
			ENetConnection.EVENT_RECEIVE:
				var data: PackedByteArray = (ev[1] as ENetPacketPeer).get_packet()
				link.bytes_in += data.size()
				if data.size() > 0:
					_receive(data)


func _receive(data: PackedByteArray) -> void:
	var b := P.reader(data)
	match b.get_u8():
		P.S_WELCOME:
			my_id = b.get_u8()
			my_slot = b.get_u8()
			var stick := b.get_u32()
			b.get_u8()
			WorldData.set_server_weather(P.get_weather(b))
			server_name = b.get_utf8_string()
			roster.clear()
			roster[my_id] = {"name": String(get_meta("callsign", "")), "slot": my_slot}
			for i in b.get_u8():
				var id := b.get_u8()
				var slot := b.get_u8()
				roster[id] = {"name": b.get_utf8_string(), "slot": slot}
			_offset = stick - _now_ticks()
			_have_clock = false
			tick = 0
			_last_ack = 0
			_own_ack = 0
			_own_state = []
			state = ONLINE
			joined.emit()
			roster_changed.emit()
		P.S_REJECT:
			_reason = b.get_utf8_string()
		P.S_JOIN:
			var id := b.get_u8()
			var slot := b.get_u8()
			roster[id] = {"name": b.get_utf8_string(), "slot": slot}
			roster_changed.emit()
		P.S_LEAVE:
			var id := b.get_u8()
			roster.erase(id)
			_remove_remote(id)
			roster_changed.emit()
		P.S_WEATHER:
			WorldData.set_server_weather(P.get_weather(b))
		P.S_SNAPSHOT:
			if state == ONLINE:
				_snapshot(b)


func _snapshot(b: StreamPeerBuffer) -> void:
	var stick := b.get_u32()
	var tod := b.get_float()
	var ack := b.get_u32()
	var queue := b.get_u8()
	var own := []
	if b.get_u8() == 1:
		own = P.get_state(b)
	var n := b.get_u8()
	var jets := []
	for i in n:
		var jd: Dictionary = P.get_jet(b)
		# to scene coordinates (the jet's frame minus ours; whole cells, so the difference is exact)
		var lp: Vector3 = jd.pos
		jd.pos = Vector3(float(jd.ox - WorldData.origin_x) + lp.x, lp.y, float(jd.oz - WorldData.origin_z) + lp.z)
		jets.append(jd)
	WorldData.time_of_day = tod
	# clock: adopt earlier-arriving (less delayed) samples quickly, later ones slowly; track jitter
	var sample := stick - _now_ticks()
	if not _have_clock:
		_offset = sample
		_have_clock = true
	elif sample > _offset:
		_offset = lerpf(_offset, sample, 0.25)
	else:
		_offset = lerpf(_offset, sample, 0.01)
	_jitter = lerpf(_jitter, absf(sample - _offset), 0.05)
	# our own jet: only the newest server state matters; it is reconciled once, after every packet that arrived this
	# tick has been read (a burst of snapshots would otherwise replay the inputs once per snapshot)
	if not own.is_empty() and ack > _last_ack and ack > _own_ack:
		_own_ack = ack
		_own_state = own
		_own_queue = queue
	# remote jets: each keeps its own timeline (its simulation tick), so stalls on the server never show
	var now := _sim_now()
	for d in jets:
		var id: int = d.id
		if not _remotes.has(id):
			_create_remote(id)
			if not _remotes.has(id):
				continue
		var r: Dictionary = _remotes[id]
		var t: int = d.t
		var js := float(t) - now
		# the jet's clock: its tick now = our tick + offset, smoothed over about ten snapshots (the drawing clock
		# that follows it changes pace by 1 % at most, so what jitter is left never shows)
		if r.snaps.is_empty():
			r.offset = js
			r.lead = d.lead
		else:
			r.offset = lerpf(r.offset, js, 0.1)
			r.lead = lerpf(r.lead, d.lead, 0.05)
		r.arrived = now
		if log_snaps:
			snap_log.append("%.4f,%d,%d,%.2f,%.2f" % [Time.get_unix_time_from_system(), id, t, js, r.offset])
		var snaps: Array = r.snaps
		var i := snaps.size()
		while i > 0 and snaps[i - 1][0] > t:
			i -= 1
		if i > 0 and snaps[i - 1][0] == t:
			continue
		# acceleration from the velocity change since the previous snapshot (the server's state is exact)
		# (lightly smoothed: wheels on a bumpy runway shake the velocity from one snapshot to the next)
		d.acc = Vector3.ZERO
		if i > 0:
			var pv: Dictionary = snaps[i - 1][1]
			var dt := float(t - snaps[i - 1][0]) / P.TICK_RATE
			if dt > 0.0:
				var raw: Vector3 = ((d.vel as Vector3) - (pv.vel as Vector3)) / dt
				d.acc = (pv.acc as Vector3).lerp(raw.limit_length(120.0), 0.5)
		snaps.insert(i, [t, d])
		while snaps.size() > 16:
			snaps.pop_front()


## The delay to the server and back, from what we know exactly: when this snapshot was sent, the server had
## applied our inputs up to `ack`, and `server_queue` more were waiting; we are at `tick` now. So the round trip is
## tick - ack - queue, and our jet runs ahead of the server's by the queue plus the trip up (half the round trip).
## Every player's lead goes to the others with their jet, so each game can predict the other jets by the whole
## delay, sender's side included, and draw them where they are now (DCS, DIS dead reckoning to the present).
var _own_ack := 0                    # newest own-jet server state received this tick, waiting to be reconciled
var _own_state: Array = []
var _own_queue := 0


func _reconcile_newest() -> void:
	if _own_ack <= _last_ack or _own_state.is_empty():
		return
	_last_ack = _own_ack
	server_queue = _own_queue
	_measure(_own_ack)
	_reconcile(_own_ack, _own_state)
	_own_state = []


func _measure(ack: int) -> void:
	var trip := maxf(float(tick - ack - server_queue), 0.0)
	var lead := float(server_queue) + trip * 0.5
	if not _have_trip:
		trip_ticks = trip
		lead_ticks = lead
		_have_trip = true
	else:
		trip_ticks = lerpf(trip_ticks, trip, 0.05)
		lead_ticks = lerpf(lead_ticks, lead, 0.05)


func _reconcile(ack: int, server_state: Array) -> void:
	if aircraft == null or not is_instance_valid(aircraft):
		return
	var mine: Array = _states.get(ack, [])
	if mine.is_empty() or _differs(mine, server_state):
		corrections += 1
		var t0 := Time.get_ticks_usec()
		aircraft.rewind(server_state, ack, _cmds, _states, tick)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		rewind_ms += ms
		rewind_max_ms = maxf(rewind_max_ms, ms)
	for t in _cmds.keys():
		if t <= ack - 2:
			_cmds.erase(t)
			_states.erase(t)


static func _differs(a: Array, s: Array) -> bool:
	# positions compared in world terms: the two frames may differ by whole cells (indices 56, 57: ox, oz)
	var fa := Vector3(float(a[56]) - float(s[56]), 0.0, float(a[57]) - float(s[57])) if a.size() > 57 and s.size() > 57 else Vector3.ZERO
	if ((a[0] as Vector3) + fa).distance_to(s[0]) > 0.02:
		return true
	if (a[1] as Vector3).distance_to(s[1]) > 0.05:
		return true
	var qa := Quaternion((a[2] as Basis).orthonormalized())
	var qs := Quaternion((s[2] as Basis).orthonormalized())
	if qa.angle_to(qs) > 0.002:
		return true
	if (a[3] as Vector3).distance_to(s[3]) > 0.01:
		return true
	for i in [6, 8, 10, 12, 26, 33, 44, 45, 46, 47, 55]:   # 55: avionics master mode
		if i < a.size() and i < s.size() and a[i] != s[i]:
			return true
	return absf(float(a[54][0]) - float(s[54][0])) > 0.5


# ------------------------------------------------------------------ remote jets

func _create_remote(id: int) -> void:
	if world_root == null or not is_instance_valid(world_root) or id == my_id:
		return
	var ac: Node3D = AircraftScript.new()
	ac.spec = load(SPEC)
	ac.net_mode = AircraftScript.NetMode.REMOTE
	ac.name = "Remote_%d" % id
	ac.callsign = roster.get(id, {}).get("name", "Pilot %d" % id)
	world_root.add_child(ac)
	_remotes[id] = {"node": ac, "snaps": [], "offset": 0.0, "clock": 0.0, "base": -1, "placed": false, "reset": false,
		"shown_p": Vector3.ZERO, "shown_v": Vector3.ZERO, "shown_q": Quaternion.IDENTITY, "shown_w": Vector3.ZERO,
		"b_p": Vector3.ZERO, "b_v": Vector3.ZERO, "b_q": Quaternion.IDENTITY, "b_w": Vector3.ZERO, "b_t": 0.0, "shown_t": 0.0,
		"stale": false, "lead": 0.0, "arrived": 0.0}

func _remove_remote(id: int) -> void:
	if _remotes.has(id):
		var n = _remotes[id].node
		if is_instance_valid(n):
			n.queue_free()
		_remotes.erase(id)


func _process(delta: float) -> void:
	if state != ONLINE:
		return
	_stats(delta)


## The jet's state at time `rt` (its own ticks), predicted from snapshot `d` taken at tick `t`: position, velocity
## and orientation, with the acceleration for the first part and the body turn rates throughout.
static func _reckon(d: Dictionary, t: int, rt: float) -> Array:
	var dt := clampf((rt - float(t)) / P.TICK_RATE, -0.5, MAX_PREDICT)
	var ta := clampf(dt, -ACCEL_TIME, ACCEL_TIME)
	var a: Vector3 = d.acc
	var pos: Vector3 = (d.pos as Vector3) + (d.vel as Vector3) * dt + a * (0.5 * ta * ta) + a * ta * (dt - ta)
	var vel: Vector3 = (d.vel as Vector3) + a * ta
	var w: Vector3 = d.omega
	var rot: Quaternion = (d.rot as Quaternion) * (Quaternion(w.normalized(), w.length() * dt) if w.length() > 1e-5 else Quaternion.IDENTITY)
	return [pos, vel, rot.normalized()]


## Places a remote jet for this tick: predicted to the present from its newest snapshot, and blended from where it
## was shown towards that prediction over BLEND_TIME whenever a newer snapshot takes over (projective velocity
## blending: the old path is carried on with a velocity that turns smoothly into the new one, and the position
## slides from the old path onto the new over the same time). No jumps, no shaking, whatever the network does.
func _predict(r: Dictionary, now: float) -> void:
	var snaps: Array = r.snaps
	# the present for this jet: its clock eases onto the estimate (1 % at most, never a jump), except when it is far
	# out while the jet stands or rolls slowly (a player joining while loading), or two seconds out: then at once
	# the jet's tick on the server when this snapshot left, plus the trip down to us (half our round trip), plus
	# how far its owner's game runs ahead of the server (its lead): where the owner sees it now
	var horizon := clampf(trip_ticks * 0.5 + (0.0 if _no_lead else float(r.lead)), 0.0, MAX_HORIZON)
	var target: float = now + r.offset + horizon
	var newest: Dictionary = snaps[-1][1]
	var err: float = target - float(r.clock)
	# (standing or taxiing, a step of a few ticks is a few centimetres to a metre: the jet takes its full horizon at once,
	# e.g. right after joining, instead of easing into it for many seconds)
	if r.base < 0 or absf(err) > 240.0 or ((newest.vel as Vector3).length() < 25.0 and absf(err) > 6.0):
		r.clock = target
	else:
		r.clock = float(r.clock) + 1.0 + clampf(err * 0.01, -0.01, 0.01)
	var rt: float = r.clock
	# predicted from the newest snapshot at or before that time (normally the newest of all)
	var bi := snaps.size() - 1
	while bi > 0 and float(snaps[bi][0]) > rt:
		bi -= 1
	var t: int = snaps[bi][0]
	var bd: Dictionary = snaps[bi][1]
	interp_delay = rt - float(snaps[-1][0])
	r.stale = now - float(r.arrived) > P.TICK_RATE * 0.25          # no snapshot for a quarter of a second
	var now_state := _reckon(bd, t, rt)
	var pos: Vector3 = now_state[0]
	var vel: Vector3 = now_state[1]
	var rot: Quaternion = now_state[2]
	if r.base != t:
		# a newer snapshot: start blending from the jet as it is shown now
		var first: bool = r.base < 0
		r.base = t
		r.b_p = r.shown_p
		r.b_v = r.shown_v
		r.b_q = r.shown_q
		r.b_w = r.shown_w
		r.b_t = r.shown_t                            # the time the shown state belongs to (the previous tick)
		if first or (pos - (r.shown_p as Vector3)).length() > SNAP_DISTANCE:
			r.b_p = pos
			r.b_v = vel
			r.b_q = rot
			r.b_w = bd.omega
			r.b_t = rt - BLEND_TIME * P.TICK_RATE
			r.reset = true
	var since: float = (rt - float(r.b_t)) / P.TICK_RATE
	var k := clampf(since / BLEND_TIME, 0.0, 1.0)
	var show_p := pos
	var show_v := vel
	var show_q := rot
	if k < 1.0:
		var acc: Vector3 = bd.acc
		var vb: Vector3 = (r.b_v as Vector3).lerp(vel, k)
		var old_p: Vector3 = (r.b_p as Vector3) + vb * since + acc * (0.5 * since * since)
		show_p = old_p.lerp(pos, k)
		show_v = vb.lerp(vel, k)
		var bw: Vector3 = r.b_w
		var old_q: Quaternion = (r.b_q as Quaternion) * (Quaternion(bw.normalized(), bw.length() * since) if bw.length() > 1e-5 else Quaternion.IDENTITY)
		show_q = old_q.normalized().slerp(rot, k)
	r.shown_p = show_p
	r.shown_v = show_v
	r.shown_q = show_q
	r.shown_w = bd.omega
	r.shown_t = rt
	if _log:
		_log.store_line("%.5f,%.4f,%.4f,%.4f,%.2f,%.2f" % [Time.get_ticks_usec() / 1e6, show_p.x, show_p.y, show_p.z, rt - float(t), k])
	r.node.apply_remote(show_p, show_q, show_v, bd.omega, bd, P.TICK_DT)


func _stats(delta: float) -> void:
	_stat_t += delta
	if _stat_t < 0.5 or peer == null:
		return
	rtt_ms = peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
	loss_pct = peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / float(ENetPacketPeer.PACKET_LOSS_SCALE) * 100.0
	kbps_in = (link.bytes_in - _last_in) / _stat_t / 1024.0
	kbps_out = (link.bytes_out - _last_out) / _stat_t / 1024.0
	_last_in = link.bytes_in
	_last_out = link.bytes_out
	_stat_t = 0.0


func stats_text() -> String:
	return "PING %d ms   TRIP %d ms   LEAD %d ms   LOSS %.1f%%   IN %.1f KB/s   OUT %.1f KB/s\nPREDICT %d ms   CORRECTIONS %d   SERVER BUFFER %d%s" % [
		int(rtt_ms), int(trip_ticks / P.TICK_RATE * 1000.0), int(lead_ticks / P.TICK_RATE * 1000.0), loss_pct, kbps_in, kbps_out, int(interp_delay / P.TICK_RATE * 1000.0), corrections, server_queue,
		"   NETSIM" if link and link.simulating else ""]
