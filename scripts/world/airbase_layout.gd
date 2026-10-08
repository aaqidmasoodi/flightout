extends RefCounted
## Airbase layout as pure data: dispersal lanes, hardened aircraft shelters (HAS) and the 16 parking slots.
## No rendering here, so the dedicated server uses exactly the same numbers as the client.
##
## Two dispersal lanes branch east off the parallel taxiway. Each lane has eight shelters, four on each side,
## staggered so no two doors face each other. Shelters are numbered 1..16, west to east, lane by lane.

const ELEVATION := 40.0
const MAX_SLOTS := 16
const TAXIWAY_EAST_X := 193.0       # east edge of the parallel taxiway, where the lanes start
const LANE_END_X := 700.0
const LANE_HALF_WIDTH := 11.0
const LANES := [5200.0, 6800.0]     # z of each lane centreline
const NORTH_X := [260.0, 370.0, 480.0, 590.0]   # shelters north of a lane, doors facing south
const SOUTH_X := [315.0, 425.0, 535.0, 645.0]   # shelters south of a lane, doors facing north

const LEAD_IN := 25.0               # paved pad from the lane edge to the door
const DEPTH := 36.0                 # inside length, door to back wall
const INNER_HALF_WIDTH := 11.0      # Su-27 span is 14.7 m, so a 22 m bay leaves room to walk round
const INNER_HEIGHT := 9.0
const JET_INSET := 19.0             # jet reference point, measured in from the door
const SPAWN_LIFT := 2.0             # same offset the runway spawn uses; the gear settles on the first steps

static var _cache: Array = []


## Every shelter: {"id": 1..16, "lane": z, "door": Vector3 on the ground, "out": unit vector a jet rolls out along}.
static func shelters() -> Array:
	if not _cache.is_empty():
		return _cache
	var list := []
	for lane: float in LANES:
		var row := []
		for x: float in NORTH_X:
			row.append({"lane": lane, "door": Vector3(x, ELEVATION, lane - LANE_HALF_WIDTH - LEAD_IN), "out": Vector3(0.0, 0.0, 1.0)})
		for x: float in SOUTH_X:
			row.append({"lane": lane, "door": Vector3(x, ELEVATION, lane + LANE_HALF_WIDTH + LEAD_IN), "out": Vector3(0.0, 0.0, -1.0)})
		row.sort_custom(func(a, b): return a.door.x < b.door.x)
		list.append_array(row)
	for i in list.size():
		list[i]["id"] = i + 1
	_cache = list
	return list


## Shelter frame: origin at the door on the ground, -Z points out of the door, +Z runs into the bay.
static func shelter_transform(index: int) -> Transform3D:
	var s: Dictionary = shelters()[index % MAX_SLOTS]
	return Transform3D(Basis.looking_at(s.out, Vector3.UP), s.door)


## Where a jet spawns in shelter `index` (0..15): parked inside, nose to the door.
static func parking_slot(index: int) -> Transform3D:
	var t := shelter_transform(index)
	return Transform3D(t.basis, t.origin + t.basis.z * JET_INSET + Vector3.UP * SPAWN_LIFT)
