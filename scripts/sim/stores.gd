extends RefCounted
## External stores: what hangs on each station of an aircraft, aircraft-agnostic and data driven.
##
## An aircraft with stores has two generated files (blender/build_stores.py):
##   res://data/aircraft/<id>_stations.json         stations (id, name, pylon kind, allowed stores, axis) and the
##                                                   store catalogue (kind, guidance, Fox number, mass, range)
##   res://assets/aircraft/<id>_stores/<id>_stores.glb   the pylons (STA_<n>_PYLON) and, per station, every store
##                                                   it can carry (STA_<n>_<STORE>); only the loaded one is shown
## Store kinds are open: "missile" today; "tank", "bomb", "pod" ... use the same path (a future aircraft that can
## carry drop tanks lists them in its catalogue and stations). Stores are presentation and loadout data for now:
## nothing is fired yet, and the loadout does not change the flight model's mass (both come later).

var aircraft_id := ""
var stations: Array = []          # [{id, name, pylon, allowed, axis}], sorted by id (left wingtip first)
var catalogue := {}               # store id -> {kind, guidance, fox, mass, range_km}
var loadout := {}                 # station id -> store id ("" = empty pylon)
var _nodes := {}                  # "STA_3_R-27ER" -> Node3D in the stores scene
var _root: Node3D


## Typical Su-27 air-to-air load: R-73s on the wings, R-27ERs and ETs under the wings and intakes.
const DEFAULTS := {"su27": {1: "R-73", 2: "R-73", 3: "R-27ER", 4: "R-27ET", 5: "R-27ER", 6: "R-27ER",
	7: "R-27ET", 8: "R-27ER", 9: "R-73", 10: "R-73"}}


static func data_path(id: String) -> String:
	return "res://data/aircraft/%s_stations.json" % id


static func scene_path(id: String) -> String:
	return "res://assets/aircraft/%s_stores/%s_stores.glb" % [id, id]


## Loads the station data for an aircraft id. Returns false if the aircraft has no stores.
func load_for(id: String) -> bool:
	aircraft_id = id
	var path := data_path(id)
	if not FileAccess.file_exists(path):
		return false
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		return false
	stations = d.get("stations", [])
	stations.sort_custom(func(a, b): return int(a.id) < int(b.id))
	catalogue = d.get("stores", {})
	var def: Dictionary = DEFAULTS.get(id, {})
	for s in stations:
		var sid := int(s.id)
		var want: String = def.get(sid, "")
		loadout[sid] = want if want in s.allowed else ""
	return true


## Puts the pylons and the loaded stores on the model (a child of `model`, in the airframe's coordinates).
func attach(model: Node3D) -> void:
	var path := scene_path(aircraft_id)
	if not ResourceLoader.exists(path):
		return
	_root = (load(path) as PackedScene).instantiate() as Node3D
	_root.name = "Stores"
	model.add_child(_root)
	for n in _root.find_children("STA_*", "", true, false):
		_nodes[String(n.name)] = n
	refresh()


## Shows exactly the loaded store on every station (pylons always).
func refresh() -> void:
	for key in _nodes:
		var parts := String(key).split("_")       # STA, <n>, <STORE or PYLON>
		if parts.size() < 3:
			continue
		var sid := parts[1].to_int()
		var what := String(key).substr(("STA_%d_" % sid).length())
		(_nodes[key] as Node3D).visible = what == "PYLON" or loadout.get(sid, "") == what


func station(sid: int) -> Dictionary:
	for s in stations:
		if int(s.id) == sid:
			return s
	return {}


## Steps the store on a station through what it can carry (and empty). Ground crew only: on the ground.
func cycle(sid: int, on_ground: bool) -> bool:
	if not on_ground:
		return false
	var s := station(sid)
	if s.is_empty():
		return false
	var opts: Array = s.allowed.duplicate()
	opts.append("")
	var i := opts.find(loadout.get(sid, ""))
	loadout[sid] = opts[(i + 1) % opts.size()]
	refresh()
	return true


func info(store: String) -> Dictionary:
	return catalogue.get(store, {})


## Short label for a store on the displays: "R-27ER" plus its type ("F1 SARH").
func describe(store: String) -> String:
	var i := info(store)
	if i.is_empty():
		return store
	return "F%d %s" % [int(i.get("fox", 0)), String(i.get("guidance", ""))] if i.get("kind", "") == "missile" else String(i.get("kind", "")).to_upper()


func count(store: String) -> int:
	var n := 0
	for sid in loadout:
		if loadout[sid] == store:
			n += 1
	return n


func total_mass() -> float:
	var m := 0.0
	for sid in loadout:
		m += float(info(loadout[sid]).get("mass", 0.0))
	return m
