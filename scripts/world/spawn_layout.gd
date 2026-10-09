extends RefCounted
## Where multiplayer jets start, as pure data (the dedicated server and every client use exactly the same numbers).
##
## The 16 slots are spread over several airfields on different sides of the map (GROUPS): slot 0..7 at Srinagar,
## 8..11 at Leh, 12..15 at Skardu. At each airfield the jets are parked in a row on the levelled shoulder beside the
## first runway (tools/build_kashmir.py flattens 45 m either side of every runway), nose along the take-off
## direction, so each one can taxi straight onto the runway. Real aprons and shelters come later.

const MAX_SLOTS := 16
## [airfield ICAO, jets]: change here to rebalance (the counts must add up to MAX_SLOTS)
const GROUPS := [["VISR", 8], ["VILH", 4], ["OPSD", 4]]
const FIRST := 250.0               # m from the threshold to the first jet
const SPACING := 70.0              # m between jets along the row (the Su-27 spans 14.7 m and is 22 m long)
const SIDE := 28.0                 # m from the runway edge to the jets' centreline
const SPAWN_LIFT := 2.0            # same as the runway spawn: the gear settles on the first steps


## Airfield and place in its row of slot `index` (0..15): [icao, n].
static func group_of(index: int) -> Array:
	var i := index % MAX_SLOTS
	for g in GROUPS:
		if i < int(g[1]):
			return [String(g[0]), i]
		i -= int(g[1])
	return [String(GROUPS[0][0]), 0]


## World transform of slot `index`: on the ground beside the runway, facing the take-off direction.
static func parking_slot(index: int) -> Transform3D:
	var g := group_of(index)
	var a: Dictionary = WorldData.airfield(g[0])
	if a.is_empty() or a.runways.is_empty():
		return WorldData.spawn_transform(0)
	var r: Dictionary = a.runways[0]
	var A := Vector3(r.a[0], 0.0, r.a[2])
	var B := Vector3(r.b[0], 0.0, r.b[2])
	var dir := (B - A).normalized()
	var right := Vector3(-dir.z, 0.0, dir.x)        # right of the take-off direction
	var along: float = minf(FIRST + int(g[1]) * SPACING, (B - A).length() - 300.0)
	var p := A + dir * along + right * (float(r.width) * 0.5 + SIDE)
	p.y = WorldData.ground_height(p.x, p.z) + SPAWN_LIFT
	return Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), p)
