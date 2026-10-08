extends RefCounted
## Asks a server for its name, pilot count and protocol version over a short ENet connection, and measures the
## round trip. Used by the Multiplayer screen to show live server status. Call poll() every frame.

const P := preload("res://scripts/net/protocol.gd")
const TIMEOUT := 4.0

var address := ""
var state := "idle"                  # idle, probing, online, offline
var name := ""
var players := 0
var capacity := 0
var version := 0
var ping_ms := 0

var _host: ENetConnection
var _peer: ENetPacketPeer
var _sent := 0
var _nonce := 0
var _deadline := 0.0


func start(addr: String) -> void:
	stop()
	address = addr
	var host := addr.strip_edges()
	var port := P.DEFAULT_PORT
	if host.count(":") == 1:
		port = host.get_slice(":", 1).to_int()
		host = host.get_slice(":", 0)
	_host = ENetConnection.new()
	if _host.create_host(1, P.CHANNELS) != OK:
		state = "offline"
		return
	_host.compress(ENetConnection.COMPRESS_RANGE_CODER)
	_peer = _host.connect_to_host(host, port, P.CHANNELS)
	if _peer == null:
		state = "offline"
		_host.destroy()
		_host = null
		return
	state = "probing"
	_deadline = Time.get_ticks_msec() / 1000.0 + TIMEOUT


func poll() -> void:
	if _host == null:
		return
	if Time.get_ticks_msec() / 1000.0 > _deadline:
		state = "offline"
		stop()
		return
	for guard in 32:
		var ev: Array = _host.service(0)
		match ev[0]:
			ENetConnection.EVENT_NONE, ENetConnection.EVENT_ERROR:
				break
			ENetConnection.EVENT_CONNECT:
				_nonce = randi()
				_sent = Time.get_ticks_usec()
				var b := StreamPeerBuffer.new()
				b.put_u8(P.C_INFO)
				b.put_u32(_nonce)
				_peer.send(P.CH_EVENTS, b.data_array, ENetPacketPeer.FLAG_RELIABLE)
				_host.flush()
			ENetConnection.EVENT_RECEIVE:
				var b := P.reader((ev[1] as ENetPacketPeer).get_packet())
				if b.get_u8() == P.S_INFO and b.get_available_bytes() >= 8:
					version = b.get_u16()
					players = b.get_u8()
					capacity = b.get_u8()
					if b.get_u32() == _nonce:
						name = b.get_utf8_string()
						ping_ms = int((Time.get_ticks_usec() - _sent) / 1000)
						state = "online"
						stop()
						return
			ENetConnection.EVENT_DISCONNECT:
				if state == "probing":
					state = "offline"
				stop()
				return


func stop() -> void:
	if _host:
		if _peer and _peer.get_state() == ENetPacketPeer.STATE_CONNECTED:
			_peer.peer_disconnect_now()
		_host.destroy()
	_host = null
	_peer = null
