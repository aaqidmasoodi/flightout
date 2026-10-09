extends Node
## Network client (child of the Game autoload, so it survives scene changes).
##
## Your jet: predicted. Every tick its input command is applied here at once and kept with the resulting state.
## When a snapshot says which of our ticks the server has applied, our state for that tick is compared with the
## server's; if they differ, the jet rewinds to the server state and replays the inputs since (Aircraft.rewind),
## and the difference is blended out of the view so nothing jumps.
##
## Other jets: drawn slightly in the past, between two snapshots, along Hermite curves built from position and
## velocity. The delay adapts to the measured jitter, so late or bunched packets never show; if snapshots stop,
## the jet is extrapolated briefly and blended back when they resume.

signal joined
signal failed(reason: String)
signal disconnected(reason: String)
signal roster_changed

const P := preload("res://scripts/net/protocol.gd")
const Link := preload("res://scripts/net/link.gd")
const AircraftScript := preload("res://scripts/aircraft/aircraft.gd")
const SPEC := "res://data/aircraft/su27.tres"
const HISTORY := 360                 # ticks of inputs and states kept (3 s)
const MAX_EXTRAPOLATE := 0.3         # s a remote jet may coast on its last velocity
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

# remote jets: id -> {"node", "snaps": [[server_tick, data]], "off_p", "off_q", "extrap"}
var _remotes := {}
var _offset := 0.0                   # server tick minus local clock (in ticks)
var _have_clock := false
var _jitter := 1.0                   # ticks
var interp_delay := 8.0              # ticks behind the newest snapshot that remote jets are drawn

# stats for the optional overlay
var rtt_ms := 0.0
var loss_pct := 0.0
var corrections := 0
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
		if is_instance_valid(r.node):
			(r.node as Node3D).global_position -= delta
			(r.node as Node3D).reset_physics_interpolation()


var online: bool:
	get: return state == ONLINE


func _now_ticks() -> float:
	return Time.get_ticks_usec() / 1e6 * P.TICK_RATE


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
		print("Net: leaving after %d corrections, ping %d ms, loss %.1f%%%s" % [corrections, int(rtt_ms), loss_pct,
			("  (" + reason + ")") if reason != "" else ""])
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
	_last_ack = 0
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
	if state == CONNECTING and Time.get_ticks_msec() / 1000.0 > _deadline:
		disconnect_from_server("")
		failed.emit("No answer from %s. Check the address, and that the server is running and reachable (UDP %d)." % [server_address, P.DEFAULT_PORT])
		return
	if link:
		link.pump()


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
			link.send(peer, P.CH_STATE, P.encode_input(batch), false)


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
	server_queue = b.get_u8()
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
	# reconcile our own jet
	if not own.is_empty() and ack > _last_ack:
		_last_ack = ack
		_reconcile(ack, own)
	# remote jets: each keeps its own timeline (its simulation tick), so stalls on the server never show
	var now := _now_ticks()
	for d in jets:
		var id: int = d.id
		if not _remotes.has(id):
			_create_remote(id)
			if not _remotes.has(id):
				continue
		var r: Dictionary = _remotes[id]
		var t: int = d.t
		var js := t - now
		if not r.have:
			r.offset = js
			r.render = js
			r.have = true
		elif js > r.offset:
			r.offset = lerpf(r.offset, js, 0.1)       # less delayed than we thought: adopt fairly quickly
		else:
			r.offset = lerpf(r.offset, js, 0.01)      # more delayed: only slowly (it is usually one late packet)
		r.jitter = lerpf(r.jitter, absf(js - r.offset), 0.05)
		var snaps: Array = r.snaps
		var i := snaps.size()
		while i > 0 and snaps[i - 1][0] > t:
			i -= 1
		if i > 0 and snaps[i - 1][0] == t:
			continue
		snaps.insert(i, [t, d])
		while snaps.size() > 40:
			snaps.pop_front()


func _reconcile(ack: int, server_state: Array) -> void:
	if aircraft == null or not is_instance_valid(aircraft):
		return
	var mine: Array = _states.get(ack, [])
	if mine.is_empty() or _differs(mine, server_state):
		corrections += 1
		aircraft.rewind(server_state, ack, _cmds, _states, tick)
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
	_remotes[id] = {"node": ac, "snaps": [], "off_p": Vector3.ZERO, "off_q": Quaternion.IDENTITY, "extrap": false,
		"shown_p": Vector3.ZERO, "shown_q": Quaternion.IDENTITY, "have": false, "offset": 0.0, "render": 0.0,
		"jitter": 1.0, "delay": 8.0}


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
	var now := _now_ticks()
	var step := delta * P.TICK_RATE
	for id in _remotes.keys():
		var r: Dictionary = _remotes[id]
		if not is_instance_valid(r.node):
			_remotes.erase(id)
			continue
		if not r.have:
			continue
		# The render clock follows the estimate but may only run up to 3% fast or slow: speed never visibly
		# changes. Only a big disagreement (a stall of half a second or more) is corrected at once.
		var target := clampf(P.SNAPSHOT_EVERY * 1.5 + r.jitter * 3.0 + 2.0, 6.0, 40.0)
		r.delay = move_toward(r.delay, target, step * 0.03)
		var err: float = (r.offset - r.delay) - r.render
		if absf(err) > 60.0:
			r.render = r.offset - r.delay
		else:
			# proportional and rate-limited: the clock eases onto the estimate (about a second), never dithers
			r.render += clampf(err * (1.0 - exp(-delta * 0.8)), -0.03 * step, 0.03 * step)
		interp_delay = r.delay
		_drive(r, now + r.render, delta)


func _drive(r: Dictionary, rt: float, delta: float) -> void:
	var snaps: Array = r.snaps
	if snaps.is_empty():
		return
	var pos: Vector3
	var rot: Quaternion
	var vel: Vector3
	var omega: Vector3
	var d: Dictionary
	var extrap := false
	if rt <= snaps[0][0]:
		d = snaps[0][1]
		pos = d.pos; rot = d.rot; vel = d.vel; omega = d.omega
	elif rt >= snaps[-1][0]:
		d = snaps[-1][1]
		var dt := minf((rt - snaps[-1][0]) / P.TICK_RATE, MAX_EXTRAPOLATE)
		pos = d.pos + d.vel * dt
		vel = d.vel
		omega = d.omega
		var w: Vector3 = d.omega
		rot = (d.rot as Quaternion) * (Quaternion(w.normalized(), w.length() * dt) if w.length() > 1e-5 else Quaternion.IDENTITY)
		extrap = true
	else:
		var i := snaps.size() - 2
		while i > 0 and snaps[i][0] > rt:
			i -= 1
		var a: Dictionary = snaps[i][1]
		var bb: Dictionary = snaps[i + 1][1]
		var span := float(snaps[i + 1][0] - snaps[i][0])
		var u := clampf((rt - snaps[i][0]) / span, 0.0, 1.0)
		var h := span / P.TICK_RATE
		var u2 := u * u
		var u3 := u2 * u
		pos = (2.0 * u3 - 3.0 * u2 + 1.0) * a.pos + (u3 - 2.0 * u2 + u) * h * a.vel + (-2.0 * u3 + 3.0 * u2) * bb.pos + (u3 - u2) * h * bb.vel
		vel = (a.vel as Vector3).lerp(bb.vel, u)
		omega = (a.omega as Vector3).lerp(bb.omega, u)
		rot = (a.rot as Quaternion).slerp(bb.rot, u)
		d = bb if u > 0.5 else a
	# leaving extrapolation (late packets arrived): blend from where the jet was shown, never pop
	if r.extrap and not extrap:
		r.off_p = (r.shown_p as Vector3) - pos
		r.off_q = ((r.shown_q as Quaternion) * rot.inverse()).normalized()
		if (r.off_p as Vector3).length() > 60.0:
			r.off_p = Vector3.ZERO
			r.off_q = Quaternion.IDENTITY
	r.extrap = extrap
	var k := exp(-8.0 * delta)
	r.off_p = (r.off_p as Vector3) * k
	r.off_q = Quaternion.IDENTITY.slerp(r.off_q, k)
	var show_p: Vector3 = pos + r.off_p
	var show_q: Quaternion = ((r.off_q as Quaternion) * rot).normalized()
	r.shown_p = show_p
	r.shown_q = show_q
	if _log:
		_log.store_line("%.5f,%.4f,%.4f,%.4f,%d,%.2f,%.2f" % [Time.get_ticks_usec() / 1e6, show_p.x, show_p.y, show_p.z,
			1 if extrap else 0, interp_delay, rt])
	r.node.apply_remote(show_p, show_q, vel, omega, d, delta)


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
	return "PING %d ms   LOSS %.1f%%   IN %.1f KB/s   OUT %.1f KB/s\nINTERP %d ms   CORRECTIONS %d   SERVER BUFFER %d%s" % [
		int(rtt_ms), loss_pct, kbps_in, kbps_out, int(interp_delay / P.TICK_RATE * 1000.0), corrections, server_queue,
		"   NETSIM" if link and link.simulating else ""]
