extends RefCounted
## Where multiplayer jets start, as pure data (the dedicated server and every client use exactly the same numbers).
##
## The 16 slots are spread over several airfields on different sides of the map (GROUPS): slot 0..7 at Srinagar,
## 8..11 at Leh, 12..15 at Skardu. At each airfield the jets are lined up on the first runway at its threshold, in
## staggered pairs either side of the centreline (as a formation lines up for take-off), nose along the runway.
## Heights come from the runway's own straight profile, the surface the runway is drawn on.

const MAX_SLOTS := 16
## [airfield ICAO, jets]: change here to rebalance (the counts must add up to MAX_SLOTS)
const GROUPS := [["VISR", 8], ["VILH", 4], ["OPSD", 4]]
const FIRST := 120.0               # m from the threshold to the first pair
const ROW := 90.0                  # m between pairs (the Su-27 is 22 m long)
const STAGGER := 45.0              # the right-hand jet of a pair sits this much further down the runway
const RUNWAY_LIFT := 0.12          # the runway mesh above the levelled ground (scripts/world/airfields.gd)
const SPAWN_LIFT := 2.0            # same as the runway spawn: the gear settles on the first steps


## Airfield and place in its line-up of slot `index` (0..15): [icao, n].
static func group_of(index: int) -> Array:
	var i := index % MAX_SLOTS
	for g in GROUPS:
		if i < int(g[1]):
			return [String(g[0]), i]
		i -= int(g[1])
	return [String(GROUPS[0][0]), 0]


## World transform of slot `index`: on the runway, facing the take-off direction.
static func parking_slot(index: int) -> Transform3D:
	var g := group_of(index)
	var a: Dictionary = WorldData.airfield(g[0])
	if a.is_empty() or a.runways.is_empty():
		return WorldData.spawn_transform(0)
	var r: Dictionary = a.runways[0]
	var A := Vector3(r.a[0], r.a[1], r.a[2])
	var B := Vector3(r.b[0], r.b[1], r.b[2])
	var flat := Vector3(B.x - A.x, 0.0, B.z - A.z)
	var length := flat.length()
	var dir := flat / length
	var right := Vector3(-dir.z, 0.0, dir.x)        # right of the take-off direction
	var n: int = g[1]
	var s := 1.0 if n % 2 == 1 else -1.0           # left, right, left, right ...
	var along: float = minf(FIRST + int(n / 2) * ROW + (STAGGER if s > 0.0 else 0.0), length - 300.0)
	var across: float = s * float(r.width) * 0.25
	var p := A + dir * along + right * across
	p.y = lerpf(A.y, B.y, along / length) + RUNWAY_LIFT + SPAWN_LIFT
	return Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), p)
