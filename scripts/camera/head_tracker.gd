extends RefCounted
## Head tracking input from OpenTrack (or anything that sends its "UDP over network" output): each packet is six
## little-endian doubles, x, y, z (centimetres) and yaw, pitch, roll (degrees), on UDP port 4242 by default.
## In OpenTrack choose Output: "UDP over network", host 127.0.0.1, port as set here. If an axis moves the wrong
## way, invert it in OpenTrack (Options, Output). The cockpit camera adds the pose to the mouse look, and the
## head's position to the eye, so you can lean around the cockpit and look past the seat.

var enabled := false
var port := 4242
var yaw := 0.0                 # degrees, + to the left (the camera's convention)
var pitch := 0.0               # degrees, + up
var roll := 0.0                # degrees, + right ear down
var pos := Vector3.ZERO        # metres, jet axes (x right, y up, z back)
var _udp: PacketPeerUDP
var _last_ms := -100000


func configure(on: bool, p: int) -> void:
	if on == enabled and p == port and (_udp != null) == on:
		return
	enabled = on
	port = p
	if _udp:
		_udp.close()
		_udp = null
	if on:
		_udp = PacketPeerUDP.new()
		if _udp.bind(port, "127.0.0.1") != OK:
			push_warning("Head tracking: could not listen on UDP port %d" % port)
			_udp = null


## True while poses are arriving (a tracker that stops sending lets go of the view within half a second).
func active() -> bool:
	return _udp != null and Time.get_ticks_msec() - _last_ms < 500


func poll() -> void:
	if _udp == null:
		return
	var latest := PackedByteArray()
	while _udp.get_available_packet_count() > 0:
		latest = _udp.get_packet()
	if latest.size() < 48:
		return
	var x := latest.decode_double(0)
	var y := latest.decode_double(8)
	var z := latest.decode_double(16)
	var yw := latest.decode_double(24)
	var pt := latest.decode_double(32)
	var rl := latest.decode_double(40)
	if is_nan(x + y + z + yw + pt + rl):
		return
	# OpenTrack: yaw + to the right, x + to the right, z + back (towards the screen's viewer), centimetres
	yaw = -clampf(yw, -180.0, 180.0)
	pitch = clampf(pt, -90.0, 90.0)
	roll = clampf(rl, -60.0, 60.0)
	pos = Vector3(clampf(x * 0.01, -0.25, 0.25), clampf(y * 0.01, -0.12, 0.1), clampf(z * 0.01, -0.25, 0.15))
	_last_ms = Time.get_ticks_msec()
