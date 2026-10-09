extends RefCounted
## The jet's sensor picture for the cockpit displays and the HUD: what the radar sees and what arrives by datalink.
## Presentation only (own jet, client side): it never affects the simulation.
##
## Candidates are other aircraft in the groups "remote_aircraft" (other players) and "ai_aircraft" (AI and dev
## targets). Each becomes a TRACK:
##   radar     the jet's own radar saw it on the last sweep (closed / filled triangle on the displays)
##   datalink  reported by a datalink source such as AWACS (open / hollow triangle). Any node in the group
##             "awacs" is a datalink source; give it `datalink_range` (m) to limit what it reports.
##   iff       "hostile", "friendly" or "unknown", from the candidate's `team` against ours (default hostile)
## The radar is a mechanically scanned set of bars: the antenna sweeps the selected azimuth limits and refreshes
## a contact when the beam passes it, so radar contacts update in steps, once per sweep, like the real thing.
## A LOCK (single target track) follows its target continuously until it leaves the gimbal limits or range.

const RANGES_KM := [10.0, 20.0, 40.0, 80.0, 160.0]
const RANGES_NM := [5.0, 10.0, 20.0, 40.0, 80.0]
const AZ_LIMITS := [60.0, 30.0, 15.0]
const BAR_COUNTS := [4, 2, 1]
const RADAR_RANGE := 120000.0     # m: detection range against a fighter
const GIMBAL := 60.0              # deg: the antenna's mechanical limit (a lock is lost beyond it)
const SWEEP_RATE := 70.0          # deg/s across the scan
const BEAM := 3.5                 # deg: half-width of the beam; a contact is refreshed when the sweep passes it
const RADAR_MEMORY := 6.0         # s a radar contact stays shown without a new hit
const DL_MEMORY := 8.0

var ac: Node3D
var tracks := {}                  # instance id -> track Dictionary
var lock_id := 0                  # instance id of the locked track, 0 when none
var mode := "RWS"                 # RWS (range while search) or TWS (track while scan: shows heading vectors)
var az_i := 0
var bars_i := 0
var range_i := 2
var sweep := 0.0                  # antenna azimuth now (deg, + right)
var datalink_on := true           # show datalink tracks
var _dir := 1.0
var _t := 0.0


func radar_on() -> bool:
	return ac != null and bool(ac.get("radar_on"))


func az_limit() -> float:
	return AZ_LIMITS[az_i]


func bars() -> int:
	return BAR_COUNTS[bars_i]


## Display range in metres (follows the unit setting: km or nautical miles).
func range_m() -> float:
	if int(Settings.get_value("hud/unit_system")) == 1:
		return RANGES_NM[range_i] * 1852.0
	return RANGES_KM[range_i] * 1000.0


func range_label() -> String:
	return str(int(RANGES_NM[range_i] if int(Settings.get_value("hud/unit_system")) == 1 else RANGES_KM[range_i]))


func range_step(d: int) -> void:
	range_i = clampi(range_i + d, 0, RANGES_KM.size() - 1)


## Position relative to the jet: [range m, azimuth deg (+ right), elevation deg (+ up)].
func relative(world: Vector3) -> Array:
	var rel := world - ac.global_position
	var l: Vector3 = ac.fm.rot.orthonormalized().inverse() * rel
	return [rel.length(), rad_to_deg(atan2(l.x, -l.z)), rad_to_deg(atan2(l.y, Vector2(l.x, l.z).length()))]


func _datalink_sources() -> Array:
	return ac.get_tree().get_nodes_in_group("awacs") if ac and ac.is_inside_tree() else []


func update(delta: float) -> void:
	if ac == null or not ac.is_inside_tree() or ac.get("fm") == null:
		return
	_t += delta
	var on := radar_on()
	var lim := az_limit()
	if on:
		sweep += _dir * SWEEP_RATE * delta
		if sweep > lim:
			sweep = lim
			_dir = -1.0
		elif sweep < -lim:
			sweep = -lim
			_dir = 1.0
	var dl_src := _datalink_sources()
	var cands: Array = ac.get_tree().get_nodes_in_group("remote_aircraft") + ac.get_tree().get_nodes_in_group("ai_aircraft")
	var my_team: String = str(ac.get("team")) if ac.get("team") != null else "blue"
	var seen := {}
	for c in cands:
		var n := c as Node3D
		if n == null or n == ac or not n.is_inside_tree():
			continue
		if n.get("crashed") == true:
			continue
		var id := n.get_instance_id()
		seen[id] = true
		var r := relative(n.global_position)
		var dist: float = r[0]
		var vel: Vector3 = n.get("velocity") if n.get("velocity") != null else Vector3.ZERO
		var t: Dictionary = tracks.get(id, {})
		if t.is_empty():
			var team: String = str(n.get("team")) if n.get("team") != null else "red"
			t = {"id": id, "node": n, "callsign": str(n.get("callsign")) if n.get("callsign") != null else "",
				"iff": "friendly" if team == my_team else "hostile", "radar_t": -100.0, "dl_t": -100.0,
				"pos": n.global_position, "vel": vel}
			tracks[id] = t
		# radar: refreshed when the sweeping beam crosses it (or continuously while locked)
		var el_cov := 2.0 + bars() * 2.5
		var in_vol: bool = on and dist < RADAR_RANGE and absf(r[1]) <= lim + BEAM and absf(r[2]) <= el_cov
		if in_vol and (id == lock_id or absf(r[1] - sweep) <= BEAM):
			t.radar_t = _t
			t.pos = n.global_position
			t.vel = vel
		# datalink: every source reports what is within its range, continuously
		for s in dl_src:
			var rng: float = float(s.get("datalink_range")) if s.get("datalink_range") != null else 400000.0
			if (s as Node3D).global_position.distance_to(n.global_position) <= rng:
				t.dl_t = _t
				if _t - float(t.radar_t) > 0.5:
					t.pos = n.global_position
					t.vel = vel
				break
	# forget what is gone or no longer seen
	for id in tracks.keys():
		var t: Dictionary = tracks[id]
		if not seen.has(id) or (not is_radar(t) and not is_dl(t)):
			tracks.erase(id)
	# the lock breaks outside the gimbal or radar range, or with the radar off
	if lock_id != 0:
		var lt: Dictionary = tracks.get(lock_id, {})
		if lt.is_empty() or not on:
			lock_id = 0
		else:
			var r := relative(lt.node.global_position)
			if r[0] > RADAR_RANGE or absf(r[1]) > GIMBAL or absf(r[2]) > GIMBAL:
				lock_id = 0


func is_radar(t: Dictionary) -> bool:
	return _t - float(t.radar_t) < RADAR_MEMORY


func is_dl(t: Dictionary) -> bool:
	return datalink_on and _t - float(t.dl_t) < DL_MEMORY


func locked() -> Dictionary:
	return tracks.get(lock_id, {}) if lock_id != 0 else {}


## Lock a radar track (by id), or the nearest radar track ahead when id is 0. Returns true on success.
func lock(id := 0) -> bool:
	if not radar_on():
		return false
	if id == 0:
		var best := INF
		for k in tracks:
			var t: Dictionary = tracks[k]
			if not is_radar(t) or k == lock_id:
				continue
			var d: float = relative(t.pos)[0]
			if d < best:
				best = d
				id = k
	if id == 0 or not tracks.has(id) or not is_radar(tracks[id]):
		return false
	lock_id = id
	return true


func unlock() -> void:
	lock_id = 0
