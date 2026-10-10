extends Node
## Dedicated FlightOut server: the authority. Runs the same FlightModel as the clients for every jet, applies
## each pilot's numbered inputs in order, and sends snapshots. Needs no graphics:
##   FlightOut --headless -- --server [--port=27015] [--name="My server"] [--netsim=...]
## Up to 16 players, each with a parking slot at one of the airfields (scripts/world/spawn_layout.gd).
##
## Input timing: each player's jet only advances when its next input has arrived, so the server applies exactly
## the input stream the client predicted with (a late packet delays that jet by a tick, invisible to others,
## instead of causing a correction). A backlog is worked off two ticks at a time; a truly lost input is
## replaced by repeating the previous one after a short wait.

const P := preload("res://scripts/net/protocol.gd")
const Link := preload("res://scripts/net/link.gd")
const FlightModel := preload("res://scripts/sim/flight_model.gd")
const Layout := preload("res://scripts/world/spawn_layout.gd")
const SPEC := "res://data/aircraft/su27.tres"
const LOST_INPUT_WAIT := 8           # ticks to wait for a missing input before repeating the last one
const MAX_LEAD := 120.0              # ticks: a lead claimed beyond 1 s is not believed
const BACKLOG := 6                   # queued inputs beyond this are worked off two per tick

class Player:
	var id := 0
	var peer: ENetPacketPeer
	var name := ""
	var slot := -1
	var fm
	var joined := false
	var queue := {}                  # client tick -> cmd
	var next_tick := -1              # next client tick to apply
	var ack := 0                     # last client tick applied
	var last_cmd: Array = []
	var waiting := 0
	var sim_tick := 0                # ticks simulated (the jet's own clock, for smooth interpolation)
	var lead := 0.0                  # how far the player's own game runs ahead of this simulation (ticks, smoothed)

var link: Link
var port := P.DEFAULT_PORT
var server_name := "FlightOut server"
var tick := 0
var players := {}                    # id -> Player
var _by_peer := {}                   # peer -> Player
var _spec: Resource
var _weather_sent := {}
# development: `--server-stats=<file.csv>` logs once a second how the simulation keeps up
var _stats: FileAccess
var _st_t0 := 0
var _st_ticks := 0
var _st_sum := 0
var _st_max := 0
var _st_stalls := 0                  # player ticks that had no input yet (the jet waited)
var _st_repeats := 0                 # lost inputs replaced by the previous one


func _ready() -> void:
	name = "Server"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = arg.trim_prefix("--port=").to_int()
		elif arg.begins_with("--server-stats="):
			_stats = FileAccess.open(arg.trim_prefix("--server-stats="), FileAccess.WRITE)
			_stats.store_line("wall,ticks,avg_us,max_us,stalls,repeats,queues")
		elif arg.begins_with("--name="):
			server_name = arg.trim_prefix("--name=").strip_edges().left(48)
	Engine.max_fps = 240                         # a headless server needs no more than its physics rate
	WorldData.load_world()
	_spec = load(SPEC)
	link = Link.new()
	var err := link.host.create_host_bound("*", port, P.MAX_PLAYERS + 2, P.CHANNELS)
	if err != OK:
		push_error("Server: cannot listen on UDP port %d (error %d)" % [port, err])
		get_tree().quit(2)
		return
	link.host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	print("FlightOut server '%s' listening on UDP %d  (protocol %d, up to %d players)%s" % [server_name, port, P.VERSION,
		P.MAX_PLAYERS, "  netsim on" if link.simulating else ""])


func _physics_process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_physics_tick()
	if _stats:
		var us := Time.get_ticks_usec() - t0
		_st_ticks += 1
		_st_sum += us
		_st_max = maxi(_st_max, us)
		if t0 - _st_t0 >= 1000000:
			var q := PackedStringArray()
			for p: Player in players.values():
				q.append(str(p.queue.size()))
			_stats.store_line("%.3f,%d,%d,%d,%d,%d,%s" % [Time.get_unix_time_from_system(), _st_ticks, _st_sum / maxi(_st_ticks, 1),
				_st_max, _st_stalls, _st_repeats, "/".join(q)])
			_stats.flush()
			_st_t0 = t0
			_st_ticks = 0
			_st_sum = 0
			_st_max = 0
			_st_stalls = 0
			_st_repeats = 0


func _physics_tick() -> void:
	_service()
	tick += 1
	for p: Player in players.values():
		if p.joined:
			_advance(p)
	if tick % P.SNAPSHOT_EVERY == 0:
		_send_snapshots()
	_check_weather()
	link.pump()


# ------------------------------------------------------------------ network events

func _service() -> void:
	for guard in 256:
		var ev: Array = link.host.service(0)
		var type: int = ev[0]
		if type == ENetConnection.EVENT_NONE or type == ENetConnection.EVENT_ERROR:
			break
		var peer: ENetPacketPeer = ev[1]
		match type:
			ENetConnection.EVENT_CONNECT:
				peer.set_timeout(0, 4000, 8000)
				var pl := Player.new()
				pl.peer = peer
				_by_peer[peer] = pl
			ENetConnection.EVENT_DISCONNECT:
				_drop(peer)
			ENetConnection.EVENT_RECEIVE:
				var data := peer.get_packet()
				link.bytes_in += data.size()
				if _by_peer.has(peer) and data.size() > 0:
					_receive(_by_peer[peer], data)


func _receive(pl: Player, data: PackedByteArray) -> void:
	var b := P.reader(data)
	match b.get_u8():
		P.C_HELLO:
			_hello(pl, b)
		P.C_INPUT:
			if not pl.joined:
				return
			for c in P.decode_input(b):
				var t: int = c[0]
				if t > pl.ack and not pl.queue.has(t):
					pl.queue[t] = c
					if pl.next_tick < 0:
						pl.next_tick = t
			var lead := P.decode_input_lead(b)
			if lead >= 0.0:
				# the client measures it every snapshot and smooths it; smoothed again here, so other players'
				# predictions never see a step
				pl.lead = lerpf(pl.lead, minf(lead, MAX_LEAD), 0.1)
			if pl.next_tick >= 0:
				for t in pl.queue.keys():
					if t < pl.next_tick:
						pl.queue.erase(t)
		P.C_BYE:
			pl.peer.peer_disconnect_later()
		P.C_INFO:
			# server-list probe: name, pilots, capacity and protocol, echoing the probe's nonce, then hang up
			if pl.joined:
				return
			var nonce := b.get_u32() if b.get_available_bytes() >= 4 else 0
			var out := StreamPeerBuffer.new()
			out.put_u8(P.S_INFO)
			out.put_u16(P.VERSION)
			out.put_u8(players.size())
			out.put_u8(P.MAX_PLAYERS)
			out.put_u32(nonce)
			out.put_utf8_string(server_name)
			link.send(pl.peer, P.CH_EVENTS, out.data_array, true)
			pl.peer.peer_disconnect_later()


func _hello(pl: Player, b: StreamPeerBuffer) -> void:
	if pl.joined:
		return
	var ver := b.get_u16()
	var nm := b.get_utf8_string().strip_edges().left(20)
	if ver != P.VERSION:
		_reject(pl, "Version mismatch: this server runs FlightOut protocol %d, you have %d. Update the game." % [P.VERSION, ver])
		return
	var used := {}
	for o: Player in players.values():
		used[o.slot] = true
	var slot := -1
	for s in P.MAX_PLAYERS:
		if not used.has(s):
			slot = s
			break
	if slot < 0:
		_reject(pl, "Server is full (%d pilots)." % P.MAX_PLAYERS)
		return
	var id := 1
	while players.has(id):
		id += 1
	pl.id = id
	pl.slot = slot
	pl.name = nm if nm != "" else "Pilot %d" % id
	pl.fm = FlightModel.new()
	pl.fm.setup(_spec, WorldData.atmosphere, WorldData.ground_height, WorldData.is_water, 7)
	pl.fm.respawn(Layout.parking_slot(slot))
	pl.joined = true
	players[id] = pl
	var w := P.S_WELCOME
	var out := StreamPeerBuffer.new()
	out.put_u8(w)
	out.put_u8(id)
	out.put_u8(slot)
	out.put_u32(tick)
	out.put_u8(P.MAX_PLAYERS)
	P.put_weather(out, _weather())
	out.put_utf8_string(server_name)
	var others := players.values().filter(func(o): return o.id != id)
	out.put_u8(others.size())
	for o: Player in others:
		out.put_u8(o.id); out.put_u8(o.slot); out.put_utf8_string(o.name)
	link.send(pl.peer, P.CH_EVENTS, out.data_array, true)
	var j := StreamPeerBuffer.new()
	j.put_u8(P.S_JOIN); j.put_u8(id); j.put_u8(slot); j.put_utf8_string(pl.name)
	_broadcast(j.data_array, true, id)
	print("Join: %s (id %d, slot %02d at %s), %d/%d" % [pl.name, id, slot + 1, preload("res://scripts/world/spawn_layout.gd").group_of(slot)[0], players.size(), P.MAX_PLAYERS])


func _reject(pl: Player, reason: String) -> void:
	var out := StreamPeerBuffer.new()
	out.put_u8(P.S_REJECT)
	out.put_utf8_string(reason)
	link.send(pl.peer, P.CH_EVENTS, out.data_array, true)
	link.pump()
	pl.peer.peer_disconnect_later()


func _drop(peer: ENetPacketPeer) -> void:
	var pl: Player = _by_peer.get(peer)
	_by_peer.erase(peer)
	link.forget(peer)
	if pl == null or not pl.joined:
		return
	players.erase(pl.id)
	var out := StreamPeerBuffer.new()
	out.put_u8(P.S_LEAVE)
	out.put_u8(pl.id)
	_broadcast(out.data_array, true, -1)
	print("Leave: %s (id %d), %d/%d" % [pl.name, pl.id, players.size(), P.MAX_PLAYERS])


func _broadcast(data: PackedByteArray, reliable: bool, except_id: int) -> void:
	for o: Player in players.values():
		if o.id != except_id:
			link.send(o.peer, P.CH_EVENTS if reliable else P.CH_STATE, data, reliable)


# ------------------------------------------------------------------ simulation

func _advance(pl: Player) -> void:
	if pl.next_tick < 0:
		return
	var steps := 2 if pl.queue.size() > BACKLOG else 1
	for i in steps:
		var cmd: Array
		if pl.queue.has(pl.next_tick):
			cmd = pl.queue[pl.next_tick]
			pl.queue.erase(pl.next_tick)
			pl.waiting = 0
		elif not pl.queue.is_empty() and pl.waiting >= LOST_INPUT_WAIT and not pl.last_cmd.is_empty():
			# the input for this tick never arrived but later ones did: repeat the last one (keeping its switches)
			cmd = pl.last_cmd.duplicate()
			_st_repeats += 1
			cmd[0] = pl.next_tick
			pl.waiting = 0
		else:
			pl.waiting += 1
			_st_stalls += 1
			return
		_apply(pl, cmd)


func _apply(pl: Player, cmd: Array) -> void:
	var fm = pl.fm
	var fired: int = fm.apply_input(cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6])
	if fired & (1 << FlightModel.T_RESPAWN):
		fm.respawn(Layout.parking_slot(pl.slot))
	var dt := P.TICK_DT / P.SUBSTEPS
	for s in P.SUBSTEPS:
		fm.step(dt)
	fm.events.clear()
	pl.sim_tick += 1
	if pl.sim_tick % 30 == 0:
		WorldData.prefetch_ahead(fm.world_pos(), fm.vel)
	pl.ack = cmd[0]
	pl.next_tick = cmd[0] + 1
	pl.last_cmd = cmd


func _send_snapshots() -> void:
	if players.is_empty():
		return
	# every jet's compact block once, then each recipient gets everyone else's plus its own full state
	var blocks := {}
	for o: Player in players.values():
		if o.joined:
			var jb := StreamPeerBuffer.new()
			P.put_jet(jb, o.id, o.sim_tick, o.fm, o.lead)
			blocks[o.id] = jb.data_array
	for pl: Player in players.values():
		if not pl.joined:
			continue
		var out := StreamPeerBuffer.new()
		out.put_u8(P.S_SNAPSHOT)
		out.put_u32(tick)
		out.put_float(WorldData.time_of_day)
		out.put_u32(pl.ack)
		out.put_u8(mini(pl.queue.size(), 255))
		if pl.ack > 0 and pl.sim_tick > 0:
			out.put_u8(1)
			P.put_state(out, pl.fm.get_state())
		else:
			out.put_u8(0)
		out.put_u8(blocks.size() - (1 if blocks.has(pl.id) else 0))
		for id in blocks:
			if id != pl.id:
				out.put_data(blocks[id])
		link.send(pl.peer, P.CH_STATE, out.data_array, false)


# ------------------------------------------------------------------ weather (server-owned)

func _weather() -> Dictionary:
	var a = WorldData.atmosphere
	return {"wind_from": a.wind_from_deg, "wind_speed": a.wind_speed, "turbulence": a.turbulence, "seed": a.seed,
		"time": WorldData.time_of_day, "time_scale": WorldData.time_scale, "conditions": WorldData.conditions}


func _check_weather() -> void:
	if tick % 120 != 0:
		return
	var w := _weather()
	var key := [w.wind_from, w.wind_speed, w.turbulence, w.seed, w.time_scale, w.conditions]
	if _weather_sent.get("k") == key:
		return
	var first := _weather_sent.is_empty()
	_weather_sent["k"] = key
	if first:
		return
	var out := StreamPeerBuffer.new()
	out.put_u8(P.S_WEATHER)
	P.put_weather(out, w)
	_broadcast(out.data_array, true, -1)
