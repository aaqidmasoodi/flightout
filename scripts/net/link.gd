extends RefCounted
## ENet transport with a built-in network simulator. Every packet either side sends goes through send(), so
## lag, jitter and loss can be dialled in to prove the netcode stays smooth on a bad connection:
##   FlightOut -- --netsim=150,40,3    (one-way lag ms, jitter +/- ms, loss % of unreliable packets)
## Reliable packets keep their order under simulated jitter, as ENet guarantees for real.

const P := preload("res://scripts/net/protocol.gd")

var host := ENetConnection.new()
var sim_lag := 0.0
var sim_jitter := 0.0
var sim_loss := 0.0
var bytes_out := 0
var bytes_in := 0
var packets_dropped := 0

var _queue: Array = []              # [due, peer, channel, data, flags], sorted by due
var _last_reliable_due := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--netsim="):
			var v := arg.trim_prefix("--netsim=").split(",")
			sim_lag = (v[0].to_float() if v.size() > 0 else 0.0) / 1000.0
			sim_jitter = (v[1].to_float() if v.size() > 1 else 0.0) / 1000.0
			sim_loss = (v[2].to_float() if v.size() > 2 else 0.0) / 100.0


var simulating: bool:
	get: return sim_lag > 0.0 or sim_jitter > 0.0 or sim_loss > 0.0


func send(peer: ENetPacketPeer, channel: int, data: PackedByteArray, reliable: bool) -> void:
	if peer == null:
		return
	var flags := ENetPacketPeer.FLAG_RELIABLE if reliable else ENetPacketPeer.FLAG_UNSEQUENCED
	bytes_out += data.size()
	if not simulating:
		peer.send(channel, data, flags)
		return
	if not reliable and _rng.randf() < sim_loss:
		packets_dropped += 1
		return
	var now := Time.get_ticks_usec() / 1e6
	var due := now + maxf(sim_lag + _rng.randf_range(-sim_jitter, sim_jitter), 0.0)
	if reliable:
		due = maxf(due, _last_reliable_due)
		_last_reliable_due = due
	var item := [due, peer, channel, data, flags]
	var i := _queue.size()
	while i > 0 and _queue[i - 1][0] > due:
		i -= 1
	_queue.insert(i, item)


## Sends whatever the simulator has held back long enough, then flushes ENet.
func pump() -> void:
	if not _queue.is_empty():
		var now := Time.get_ticks_usec() / 1e6
		while not _queue.is_empty() and _queue[0][0] <= now:
			var it: Array = _queue.pop_front()
			var peer: ENetPacketPeer = it[1]
			if is_instance_valid(peer) and peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
				peer.send(it[2], it[3], it[4])
	host.flush()


## Drops queued packets for a peer that has gone.
func forget(peer: ENetPacketPeer) -> void:
	_queue = _queue.filter(func(it): return it[1] != peer)


func close() -> void:
	_queue.clear()
	host.destroy()
